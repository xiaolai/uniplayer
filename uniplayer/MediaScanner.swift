//
//  MediaScanner.swift
//  uniplayer
//
//  Explicit recursive scans and single-directory visits. Both use the same
//  identity checks and absence reconciliation: a partial, cancelled or
//  wrong-volume listing may add or refresh rows, but it may never declare a
//  file missing.
//

import Foundation

struct ScanLimits {
  var maxMissingChildren = 50
  var massAbsenceFraction = 0.25
  var commitBatchSize = 200
}

struct ScanResult {
  var generation: UInt64
  var discovered: Int
  var updated: Int
  var missingApplied: Int
  var partial: Bool
  var cancelled: Bool
  var review: AbsenceReview?
}

final class MediaScanner {
  private let catalog: MediaCatalog
  private let executor: SourceIOExecutor
  private let provider: MediaSourceProvider
  private let limits: ScanLimits
  private let volumeKey: String
  private let lane: SourceIOLane
  private let allowAbsence: Bool
  private let cancellationLock = NSLock()
  private var cancelled = false

  init(catalog: MediaCatalog, executor: SourceIOExecutor,
       provider: MediaSourceProvider, root: MediaSourceRoot,
       limits: ScanLimits = ScanLimits(), allowAbsence: Bool = true) {
    self.catalog = catalog
    self.executor = executor
    self.provider = provider
    self.limits = limits
    self.volumeKey = root.namespace.volumeIdentity
    self.lane = root.kind.isNetwork ? .network : .local
    self.allowAbsence = allowAbsence
  }

  func cancel() {
    cancellationLock.lock()
    cancelled = true
    cancellationLock.unlock()
  }

  /// `cancel()` arrives from another thread, so the flag is read under the
  /// same lock rather than as a bare Bool.
  private var isCancelled: Bool {
    cancellationLock.lock()
    defer { cancellationLock.unlock() }
    return cancelled
  }

  // MARK: - Recursive scan

  func scan(root: MediaSourceRoot) async throws -> ScanResult {
    let generation = Self.newGeneration()
    let scanRunID = try await catalog.beginScanRun(rootID: root.id, generation: generation)
    var result = ScanResult(generation: generation, discovered: 0, updated: 0,
                            missingApplied: 0, partial: false, cancelled: false,
                            review: nil)

    do {
      let identity = try await observeIdentity(root: root)
      let rootURL = identity.url
      // Directory paths in the catalog are relative to the saved root, so the
      // root itself is the empty path even when it sits below a mount point.
      var stack: [(url: URL, relativePath: String, parentID: UUID?)] =
        [(rootURL, "", nil)]

      while let current = stack.popLast() {
        if isCancelled || Task.isCancelled {
          result.cancelled = true
          break
        }
        let existing = try await catalog.directory(
          rootID: root.id, relativePath: current.relativePath,
          comparison: root.comparison)
        let existingSnapshot: DirectorySnapshot?
        if let existing {
          existingSnapshot = try? await catalog.directorySnapshot(directoryID: existing.id)
        } else {
          existingSnapshot = nil
        }
        let listing: DirectoryListing
        do {
          let bootVolume = identity.identity.mountPath == "/"
          listing = try await executor.perform(
            lane: lane, volumeKey: volumeKey,
            isBootVolume: bootVolume) {
              try self.provider.listDirectory(at: current.url, generation: generation)
            }
        } catch MediaSourceError.cancelled {
          result.cancelled = true
          break
        } catch MediaSourceError.timedOut, MediaSourceError.quarantined {
          // The source is circuit-broken. Do not wait out the timeout once per
          // remaining directory.
          result.partial = true
          break
        } catch {
          // One unreadable directory is a partial scan; it is never evidence
          // that its children disappeared.
          result.partial = true
          continue
        }
        if isCancelled || Task.isCancelled {
          result.cancelled = true
          break
        }
        if !listing.isComplete {
          // A capped or partial provider listing is not a complete scan.
          result.partial = true
        }

        let directory = try await catalog.upsertDirectory(
          rootID: root.id, parentID: current.parentID,
          relativePath: current.relativePath, comparison: root.comparison)

        var seenKeys: Set<String> = []
        var seenDirectoryKeys: Set<String> = []
        var batch: [(URL, DirectoryEntry, String)] = []
        for entry in listing.entries {
          guard let relative = self.relativePath(for: entry.url, under: rootURL) else {
            result.partial = true
            continue
          }
          batch.append((entry.url, entry, relative))
          if batch.count >= limits.commitBatchSize {
            try await commit(batch: batch, root: root, directory: directory,
                             seenKeys: &seenKeys, seenDirectoryKeys: &seenDirectoryKeys,
                             result: &result)
            batch.removeAll(keepingCapacity: true)
          }
        }
        try await commit(batch: batch, root: root, directory: directory,
                         seenKeys: &seenKeys, seenDirectoryKeys: &seenDirectoryKeys,
                         result: &result)

        for entry in listing.entries where entry.isDirectory {
          guard let relative = self.relativePath(for: entry.url, under: rootURL) else { continue }
          stack.append((entry.url, relative, directory.id))
        }

        let outcome = try await reconcileAbsence(
          root: root, relativePath: current.relativePath,
          listing: listing, directory: directory,
          existingSnapshot: existingSnapshot, identity: identity,
          seenKeys: seenKeys, seenDirectoryKeys: seenDirectoryKeys,
          review: result.review, generation: generation)
        result.missingApplied += outcome.missingApplied
        if outcome.cancelled {
          result.cancelled = true
          break
        }
        if let review = outcome.review {
          result.review = review
          try await catalog.setPendingAbsenceReview(review, scanRunID: scanRunID)
        }

        _ = try await catalog.recordDirectorySnapshot(
          directoryID: directory.id, observedAt: listing.observedAt,
          complete: listing.isComplete, generation: generation)
      }

      var updatedRoot = root
      if let observed = try? await observeIdentity(root: root) {
        updatedRoot.currentMountHint = observed.identity.mountPath
      }
      try await catalog.updateRootScanMetadata(
        id: root.id,
        mountHint: updatedRoot.currentMountHint,
        lastUpdate: result.partial || result.cancelled ? nil : Date())

      let state = result.cancelled ? "cancelled" : (result.partial ? "partial" : "complete")
      try await catalog.finishScanRun(
        id: scanRunID, state: state, discovered: result.discovered,
        updated: result.updated, errorCategory: result.partial ? "partial" : nil)
      return result
    } catch {
      try? await catalog.finishScanRun(
        id: scanRunID, state: "failed", discovered: result.discovered,
        updated: result.updated, errorCategory: String(describing: error))
      throw error
    }
  }

  // MARK: - Directory visit

  func visit(root: MediaSourceRoot, relativePath: String,
             parentID: UUID?) async throws -> DirectorySnapshot {
    let generation = Self.newGeneration()
    let identity = try await observeIdentity(root: root)
    let rootURL = identity.url
    let directoryURL = url(for: relativePath, under: rootURL)
    let existing = try await catalog.directory(
      rootID: root.id, relativePath: relativePath, comparison: root.comparison)
    let existingSnapshot: DirectorySnapshot?
    if let existing {
      existingSnapshot = try? await catalog.directorySnapshot(directoryID: existing.id)
    } else {
      existingSnapshot = nil
    }

    let bootVolume = identity.identity.mountPath == "/"
    let listing = try await executor.perform(
      lane: lane, volumeKey: volumeKey,
      isBootVolume: bootVolume) {
        try self.provider.listDirectory(at: directoryURL, generation: generation)
      }
    let directory = try await catalog.upsertDirectory(
      rootID: root.id, parentID: parentID,
      relativePath: relativePath, comparison: root.comparison)

    var seenKeys: Set<String> = []
    var seenDirectoryKeys: Set<String> = []
    var result = ScanResult(generation: generation, discovered: 0, updated: 0,
                            missingApplied: 0, partial: false, cancelled: false,
                            review: nil)
    var batch: [(URL, DirectoryEntry, String)] = []
    for entry in listing.entries {
      guard let path = self.relativePath(for: entry.url, under: rootURL) else {
        result.partial = true
        continue
      }
      batch.append((entry.url, entry, path))
      if batch.count >= limits.commitBatchSize {
        try await commit(batch: batch, root: root, directory: directory,
                         seenKeys: &seenKeys, seenDirectoryKeys: &seenDirectoryKeys,
                         result: &result)
        batch.removeAll(keepingCapacity: true)
      }
    }
    try await commit(batch: batch, root: root, directory: directory,
                     seenKeys: &seenKeys, seenDirectoryKeys: &seenDirectoryKeys,
                     result: &result)

    // Both review kinds of one visit belong in one pending review: accepting
    // either clears the root's pending reviews, so persisting two would lose
    // the other half. A visit is a fresh observation, so it does not merge a
    // pending review from an earlier scan.
    let outcome = try await reconcileAbsence(
      root: root, relativePath: relativePath,
      listing: listing, directory: directory,
      existingSnapshot: existingSnapshot, identity: identity,
      seenKeys: seenKeys, seenDirectoryKeys: seenDirectoryKeys,
      review: nil, generation: generation)
    if !outcome.cancelled, let review = outcome.review {
      let runID = try await catalog.beginScanRun(rootID: root.id,
                                                 generation: generation)
      try await catalog.setPendingAbsenceReview(review, scanRunID: runID)
      try await catalog.finishScanRun(id: runID, state: "visit",
                                      discovered: result.discovered,
                                      updated: result.updated,
                                      errorCategory: nil)
    }

    try await catalog.recordDirectorySnapshot(      directoryID: directory.id, observedAt: listing.observedAt,
      complete: listing.isComplete, generation: generation)

    return (try await catalog.directorySnapshot(directoryID: directory.id)) ?? DirectorySnapshot(
      directory: directory, subdirectories: [], items: [],
      complete: listing.isComplete, observedAt: listing.observedAt, generation: generation)
  }

  // MARK: - Absence reconciliation

  private struct AbsenceOutcome {
    var review: AbsenceReview?
    var missingApplied = 0
    var cancelled = false
  }

  /// One implementation of the absence rules for both traversal modes: a
  /// complete listing is required, already-missing rows are not re-reviewed,
  /// unverified identity never authorizes automatic absence, and every write is
  /// guarded by the observation it came from.
  private func reconcileAbsence(
    root: MediaSourceRoot, relativePath: String,
    listing: DirectoryListing, directory: MediaDirectory,
    existingSnapshot: DirectorySnapshot?, identity: ObservedRoot,
    seenKeys: Set<String>, seenDirectoryKeys: Set<String>,
    review existingReview: AbsenceReview?, generation: UInt64
  ) async throws -> AbsenceOutcome {
    var outcome = AbsenceOutcome()
    var newFindings: AbsenceReview?
    guard listing.isComplete, allowAbsence else { return outcome }
    if isCancelled || Task.isCancelled {
      outcome.cancelled = true
      return outcome
    }

    let existingItems = existingSnapshot?.items ?? []
    let missing = existingItems.filter {
      guard $0.presence != .missing, let path = $0.relativePath else { return false }
      return !seenKeys.contains(root.comparison.key(for: path))
    }
    if !missing.isEmpty {
      let known = existingItems.count
      let emptyDirectory = known > 0 && listing.entries.isEmpty
      let mass = emptyDirectory
        || (missing.count >= limits.maxMissingChildren
            && Double(missing.count) >= limits.massAbsenceFraction * Double(known))
      if mass || !identity.verified {
        let review = AbsenceReview(
          token: existingReview?.token ?? UUID(), rootID: root.id,
          generation: generation, directoryIDs: [directory.id],
          missingMediaIDs: missing.map(\.id),
          reason: mass ? (emptyDirectory ? "emptyRoot" : "massAbsence")
            : "unverifiedIdentity",
          missingCount: missing.count, knownCount: known,
          createdAt: Date())
        newFindings = Self.merge(review: newFindings, with: review)
      } else {
        // Revalidate the volume/share immediately before writing absence. A
        // remount or wrong volume between enumeration and reconciliation must
        // not be able to hide files.
        _ = try await observeIdentity(root: root)
        guard !isCancelled, !Task.isCancelled else {
          outcome.cancelled = true
          return outcome
        }
        try await catalog.applyAbsence(mediaIDs: missing.map(\.id),
                                       generation: generation,
                                       observedAt: listing.observedAt)
        outcome.missingApplied += missing.count
      }
    }

    let existingDirectories = existingSnapshot?.subdirectories ?? []
    let missingDirectories = existingDirectories.filter {
      !seenDirectoryKeys.contains($0.comparisonKey)
    }
    if !missingDirectories.isEmpty {
      var descendantIDs: [UUID] = []
      // The review must name every directory whose observation could disprove
      // it, not only the parent: a refreshed child is newer evidence.
      var affectedDirectoryIDs: [UUID] = [directory.id]
      for missingDirectory in missingDirectories {
        descendantIDs += (try? await catalog.descendantMediaIDs(
          directoryID: missingDirectory.id, presentOnly: true)) ?? []
        affectedDirectoryIDs += (try? await catalog.descendantDirectoryIDs(
          directoryID: missingDirectory.id)) ?? [missingDirectory.id]
      }
      let mass = descendantIDs.count >= limits.maxMissingChildren
        || (relativePath.isEmpty && listing.entries.isEmpty && !descendantIDs.isEmpty)
      if !descendantIDs.isEmpty, mass || !identity.verified || existingReview != nil {
        let review = AbsenceReview(
          token: existingReview?.token ?? UUID(), rootID: root.id,
          generation: generation,
          directoryIDs: Array(Set(affectedDirectoryIDs)),
          missingMediaIDs: descendantIDs,
          reason: identity.verified ? "deletedDirectory" : "unverifiedIdentity",
          missingCount: descendantIDs.count, knownCount: descendantIDs.count,
          createdAt: Date())
        newFindings = Self.merge(review: newFindings, with: review)
      } else if identity.verified {
        _ = try await observeIdentity(root: root)
        guard !isCancelled, !Task.isCancelled else {
          outcome.cancelled = true
          return outcome
        }
        for missingDirectory in missingDirectories {
          // Cancellation can arrive between writes; stop writing absence for a
          // scan the person has already stopped.
          if isCancelled || Task.isCancelled {
            outcome.cancelled = true
            break
          }
          try await catalog.markDirectoryAbsent(
            directoryID: missingDirectory.id, ancestorPath: relativePath,
            generation: generation, observedAt: listing.observedAt)
          outcome.missingApplied += 1
        }
      }
    }
    if let newFindings {
      // The caller's review carries findings from earlier directories; the
      // merged result must include them or they are lost.
      outcome.review = Self.merge(review: existingReview, with: newFindings)
    }
    return outcome
  }

  // MARK: - Commit and identity

  private func commit(batch: [(URL, DirectoryEntry, String)],
                      root: MediaSourceRoot, directory: MediaDirectory,
                      seenKeys: inout Set<String>,
                      seenDirectoryKeys: inout Set<String>,
                      result: inout ScanResult) async throws {
    var files: [(url: URL, entry: DirectoryEntry, relativePath: String)] = []
    var directories: [(url: URL, relativePath: String)] = []
    for (url, entry, relative) in batch {
      let key = root.comparison.key(for: relative)
      if entry.isDirectory {
        if !seenDirectoryKeys.insert(key).inserted { continue }
        directories.append((url, relative))
      } else {
        if !seenKeys.insert(key).inserted { continue }
        files.append((url, entry, relative))
      }
    }
    guard !files.isEmpty || !directories.isEmpty else { return }
    // One catalog transaction and one change notification per batch.
    let counts = try await catalog.commitDirectoryObservation(
      root: root, directoryID: directory.id,
      files: files, directories: directories)
    result.discovered += counts.discovered
    result.updated += counts.updated
  }

  private static let generationLock = NSLock()
  private static var generationCounter: UInt64 = 0

  private static func newGeneration() -> UInt64 {
    generationLock.lock()
    defer { generationLock.unlock() }
    let base = UInt64(Date().timeIntervalSince1970 * 1_000_000)
    generationCounter = max(generationCounter + 1, base)
    return generationCounter
  }

  private static func merge(review existing: AbsenceReview?,
                            with new: AbsenceReview) -> AbsenceReview {
    guard let existing else { return new }
    var merged = existing
    merged.directoryIDs = Array(Set(existing.directoryIDs + new.directoryIDs))
    merged.missingMediaIDs = Array(Set(existing.missingMediaIDs + new.missingMediaIDs))
    merged.missingCount = merged.missingMediaIDs.count
    merged.knownCount = existing.knownCount + new.knownCount
    // Currentness is judged against the newest evidence. Keeping an older
    // generation or timestamp makes the merged review stale as soon as its
    // newest directory observation is recorded.
    merged.generation = max(existing.generation, new.generation)
    merged.createdAt = max(existing.createdAt, new.createdAt)
    if existing.reason != new.reason { merged.reason = "mixedAbsence" }
    return merged
  }

  private struct ObservedRoot {
    var identity: SourceIdentity
    var url: URL
    var verified: Bool { identity.isVerified }
  }

  private func observeIdentity(root: MediaSourceRoot) async throws -> ObservedRoot {
    guard let hint = root.resolvedURL else { throw MediaSourceError.offline }
    let identity = try await executor.perform(
      lane: lane, volumeKey: "identity:\(root.id.uuidString)",
      isBootVolume: root.kind == .local && root.currentMountHint == "/") {
        try self.provider.observeIdentity(at: hint)
      }
    guard identity.namespace == root.namespace else {
      throw MediaSourceError.identityChanged
    }
    guard identity.comparison == root.comparison else {
      throw MediaSourceError.identityChanged
    }
    guard root.comparison.key(for: identity.pathInNamespace)
      == root.comparison.key(for: root.pathInNamespace) else {
      throw MediaSourceError.identityChanged
    }
    let url = Self.url(for: root.pathInNamespace, mountPath: identity.mountPath)
    return ObservedRoot(identity: identity, url: url)
  }

  private func relativePath(for url: URL, under rootURL: URL) -> String? {
    let rootPath = rootURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == rootPath { return "" }
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard path.hasPrefix(prefix) else { return nil }
    return SourcePath.normalized(String(path.dropFirst(prefix.count)))
  }

  private func url(for relativePath: String, under rootURL: URL) -> URL {
    Self.url(for: relativePath, mountPath: rootURL.path)
  }

  private static func url(for relativePath: String, mountPath: String) -> URL {
    var url = URL(fileURLWithPath: mountPath, isDirectory: true)
    for component in SourcePath.normalized(relativePath).split(separator: "/") {
      url.appendPathComponent(String(component))
    }
    return url
  }
}
