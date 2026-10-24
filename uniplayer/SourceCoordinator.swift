//
//  SourceCoordinator.swift
//  uniplayer
//
//  User intent for media sources: add, browse, scan, reconnect, relink and
//  remove. Providers do blocking work through SourceIOExecutor; the catalog
//  owns persistence. This type owns the small amount of user-visible state
//  (connectivity, activity, pending review) and never stores credentials.
//

import Foundation
import Combine

struct SourceState: Equatable, Sendable {
  var connectivity: SourceConnectivity = .unknown
  var activity: SourceActivity = .idle
  var lastError: MediaSourceError?
  var pendingReview: AbsenceReview?
  var lastListedPath: String?
  var activityStartedAt: Date?
}

enum AddSourceOutcome {
  case created(MediaSourceRoot)
  case existing(MediaSourceRoot)
  case restore(MediaSourceRoot)
  case overlap(MediaSourceRoot)
  case possibleAlias(MediaSourceRoot)
}

struct SourceProviderFactory {
  var make: (MediaSourceKind) -> MediaSourceProvider

  static let live = SourceProviderFactory { _ in LocalFolderProvider() }
}

@MainActor
final class SourceCoordinator: ObservableObject {
  @Published private(set) var roots: [MediaSourceRoot] = []
  @Published private(set) var collections: [MediaCollection] = []
  @Published private(set) var states: [UUID: SourceState] = [:]

  let catalog: MediaCatalog
  let executor: SourceIOExecutor
  let providerFactory: SourceProviderFactory
  let organization: MediaOrganizationStore
  private var scanners: [UUID: MediaScanner] = [:]
  /// A browse owns the displayed activity only while its token is current. A
  /// scan that starts mid-browse invalidates the token, so the browse cannot
  /// overwrite the scan's state when it finishes later.
  private var browseTokens: [UUID: UUID] = [:]
  private var scanTokens: [UUID: UUID] = [:]
  private var addingRoot = false

  init(catalog: MediaCatalog, executor: SourceIOExecutor = .shared,
       providerFactory: SourceProviderFactory = .live) {
    self.catalog = catalog
    self.executor = executor
    self.providerFactory = providerFactory
    self.organization = MediaOrganizationStore(catalog: catalog)
  }

  // MARK: - Loading

  func load() async {
    do {
      // Detached sources are not browsable; they surface only through the
      // Restore flow, which looks them up by identity in the catalog.
      roots = try await catalog.roots(includeDetached: false)
      collections = try await catalog.collections()
      for root in roots where states[root.id] == nil {
        states[root.id] = SourceState()
      }
    } catch {
      Logger.log("Media sources could not load: \(error)", level: .error,
                 subsystem: Logger.Sub.mediaSources)
    }
  }

  func state(for rootID: UUID) -> SourceState {
    states[rootID] ?? SourceState()
  }

  func root(id: UUID) -> MediaSourceRoot? {
    roots.first { $0.id == id }
  }

  // MARK: - Add and remove

  func addRoot(at url: URL, displayName: String? = nil,
               inclusion: SourceInclusion = .browseOnly,
               allowPossibleAliasDuplicate: Bool = false) async throws -> AddSourceOutcome {
    // Overlap is checked against the catalog, and the bookmark and insert that
    // follow are separate awaits. Serializing additions keeps two panels from
    // both passing the check and inserting the same folder.
    guard !addingRoot else { throw MediaSourceError.quarantined }
    addingRoot = true
    defer { addingRoot = false }
    let rawURL = url.standardizedFileURL
    let standardized = try await executor.perform(
      lane: SourceIOLane.forPath(rawURL.path), volumeKey: "resolve:\(rawURL.path)") {
        rawURL.resolvingSymlinksInPath().standardizedFileURL
      }
    let factory = providerFactory
    let provider = factory.make(.local)
    let identity: SourceIdentity
    do {
      identity = try await executor.perform(
        lane: SourceIOLane.forPath(standardized.path),
        volumeKey: "identity:\(standardized.path)",
        isBootVolume: standardized.path == "/") {
          try provider.observeIdentity(at: standardized)
        }
    } catch let error as MediaSourceError {
      throw error
    }

    let allRoots = try await catalog.roots()
    let canonical = identity.comparison.key(for: identity.pathInNamespace)
    for root in allRoots where root.namespace == identity.namespace
      && root.comparison == identity.comparison {
      let key = root.comparison.key(for: root.pathInNamespace)
      if key == canonical {
        return root.isDetached ? .restore(root) : .existing(root)
      }
    }
    for root in allRoots where root.namespace == identity.namespace
      && root.comparison == identity.comparison {
      if SourcePath.isAncestor(root.pathInNamespace, of: identity.pathInNamespace,
                               semantics: root.comparison)
        || SourcePath.isAncestor(identity.pathInNamespace, of: root.pathInNamespace,
                                 semantics: root.comparison) {
        return .overlap(root)
      }
    }
    if !allowPossibleAliasDuplicate,
       let possible = allRoots.first(where: {
      $0.namespace.endpointLabel != nil
        && $0.namespace.endpointLabel == identity.namespace.endpointLabel
        && $0.comparison.key(for: $0.pathInNamespace) == canonical
    }) {
      return .possibleAlias(possible)
    }

    let bookmark: Data? = try? await executor.perform(
      lane: Self.lane(for: standardized),
      volumeKey: "bookmark:\(standardized.path)") {
        try standardized.bookmarkData(options: .minimalBookmark,
                                       includingResourceValuesForKeys: nil,
                                       relativeTo: nil)
      }

    var root = MediaSourceRoot(
      id: UUID(),
      displayName: displayName?.isEmpty == false
        ? displayName!
        : Self.defaultDisplayName(url: standardized, identity: identity),
      kind: identity.namespace.kind,
      bookmark: bookmark,
      namespace: identity.namespace,
      pathInNamespace: identity.pathInNamespace,
      currentMountHint: identity.mountPath,
      comparison: identity.comparison,
      inclusion: inclusion,
      createdAt: Date(),
      lastSuccessfulUpdate: nil,
      detachedAt: nil)
    if root.displayName.isEmpty { root.displayName = standardized.lastPathComponent }
    try await catalog.insertRoot(root)
    roots.append(root)
    roots.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    states[root.id] = SourceState()
    return .created(root)
  }

  func restore(_ root: MediaSourceRoot) async throws -> MediaSourceRoot {
    try await catalog.restoreRoot(id: root.id)
    // The catalog decides from the restored row whether this root is indexed.
    try await catalog.addIndexedReasons(rootID: root.id)
    await load()
    return self.root(id: root.id) ?? root
  }

  func remove(_ root: MediaSourceRoot) async throws {
    scanners[root.id]?.cancel()
    scanners[root.id] = nil
    scanTokens[root.id] = nil
    browseTokens[root.id] = nil
    // Remove indexed membership only. Explicit, history, collection and
    // favorite reasons survive so the person keeps what they organized.
    try await catalog.removeReasons(originID: root.id.uuidString, reason: .indexed)
    try await catalog.detachRoot(id: root.id)
    // A scan that committed while the two calls above were in flight can have
    // re-added indexed reasons from the still-cached indexed root. Clear them
    // again now that the row is detached.
    try await catalog.removeReasons(originID: root.id.uuidString, reason: .indexed)
    await load()
  }

  func setInclusion(_ inclusion: SourceInclusion, for root: MediaSourceRoot) async throws {
    let wasIndexed = root.inclusion == .indexed
    try await catalog.setRootInclusion(id: root.id, inclusion: inclusion)
    if inclusion == .indexed {
      try await catalog.addIndexedReasons(rootID: root.id)
    } else {
      try await catalog.removeReasons(originID: root.id.uuidString, reason: .indexed)
    }
    await load()
    if inclusion == .indexed && !wasIndexed, scanners[root.id] == nil {
      _ = try? await scan(rootID: root.id)
    }
  }

  // MARK: - Browse and scan

  func browse(rootID: UUID, relativePath: String,
              parentID: UUID?) async throws -> DirectorySnapshot {
    guard let root = root(id: rootID) else { throw MediaSourceError.notFound }
    guard !root.isDetached else { throw MediaSourceError.offline }
    let token = UUID()
    // The registry, not the published state, decides whether a scan is
    // present: a scan registers before its first await, so this check cannot
    // race with one starting.
    let scanning = scanners[rootID] != nil
    if !scanning {
      browseTokens[rootID] = token
      updateState(rootID) {
        $0.connectivity = .connecting
        $0.activity = .listing
        $0.activityStartedAt = Date()
      }
    }
    do {
      let scanner = MediaScanner(catalog: catalog, executor: executor,
                                 provider: providerFactory.make(root.kind), root: root,
                                 allowAbsence: SourceLeaseRegistry.shared
                                   .activeLeaseCount(for: root.id) == 0)
      let snapshot = try await scanner.visit(root: root, relativePath: relativePath,
                                             parentID: parentID)
      if !scanning, browseTokens[rootID] == token {
        browseTokens[rootID] = nil
        updateState(rootID) {
          $0.connectivity = .online
          $0.activity = .idle
          $0.activityStartedAt = nil
          $0.lastError = nil
          $0.lastListedPath = relativePath
        }
      }
      // A visit commits rows with the inclusion snapshot it started with; an
      // inclusion switch made while it ran is reconciled here.
      await reconcileMembership(rootID: rootID)
      return snapshot
    } catch {
      let sourceError = error as? MediaSourceError ?? .unreadable
      if !scanning, browseTokens[rootID] == token {
        browseTokens[rootID] = nil
        updateState(rootID) {
          $0.connectivity = Self.connectivity(for: sourceError)
          $0.activity = .attention
          $0.activityStartedAt = nil
          $0.lastError = sourceError
        }
      }
      await reconcileMembership(rootID: rootID)
      throw sourceError
    }
  }

  @discardableResult
  func scan(rootID: UUID) async throws -> ScanResult {
    guard let root = root(id: rootID) else { throw MediaSourceError.notFound }
    guard !root.isDetached else { throw MediaSourceError.offline }
    // Check and register in one synchronous step; there is no await between
    // them, so two scans cannot both pass the guard.
    guard scanners[rootID] == nil else {
      throw MediaSourceError.quarantined
    }
    let scanner = MediaScanner(catalog: catalog, executor: executor,
                               provider: providerFactory.make(root.kind), root: root,
                               allowAbsence: SourceLeaseRegistry.shared
                                 .activeLeaseCount(for: root.id) == 0)
    let scanToken = UUID()
    scanners[rootID] = scanner
    scanTokens[rootID] = scanToken
    browseTokens[rootID] = nil
    updateState(rootID) {
      $0.connectivity = .connecting
      $0.activity = .scanning
      $0.activityStartedAt = Date()
    }
    func finishActivity() -> Bool {
      guard scanTokens[rootID] == scanToken else { return false }
      scanTokens[rootID] = nil
      if scanners[rootID] === scanner { scanners[rootID] = nil }
      return true
    }
    do {
      let result = try await scanner.scan(root: root)
      // An invalidated scan (the source was removed or restored) must not
      // publish a completion over whatever owns the state now.
      if finishActivity() {
        updateState(rootID) {
          $0.connectivity = .online
          $0.activity = result.review == nil ? .idle : .attention
          $0.activityStartedAt = nil
          $0.lastError = nil
          $0.pendingReview = result.review
        }
      }
      if SourceLeaseRegistry.shared.activeLeaseCount(for: rootID) == 0 {
        try? await catalog.evictVisitedRows(rootID: rootID)
      }
      // Reconcile membership with the inclusion that is current now, not the
      // one captured when the scan started.
      await reconcileMembership(rootID: rootID)
      await load()
      return result
    } catch {
      let sourceError = error as? MediaSourceError ?? .unreadable
      if finishActivity() {
        updateState(rootID) {
          $0.connectivity = Self.connectivity(for: sourceError)
          $0.activity = .attention
          $0.activityStartedAt = nil
          $0.lastError = sourceError
        }
      }
      // A scan that failed after committing rows must not leave membership
      // under an inclusion the person has since switched off.
      await reconcileMembership(rootID: rootID)
      throw sourceError
    }
  }

  /// Indexed membership follows the root's stored inclusion and attachment.
  /// The check runs in the catalog, so a cached coordinator root cannot keep a
  /// removed or Browse Only source in the library after a late scan or visit.
  private func reconcileMembership(rootID: UUID) async {
    try? await catalog.reconcileIndexedReasons(rootID: rootID)
  }

  func cancel(rootID: UUID) {
    scanners[rootID]?.cancel()
  }

  func pendingReview(rootID: UUID) async throws -> AbsenceReview? {
    try await catalog.pendingAbsenceReview(rootID: rootID)
  }

  func dismissReview(rootID: UUID) async {
    try? await catalog.clearPendingAbsenceReviews(rootID: rootID)
    updateState(rootID) { $0.pendingReview = nil; $0.activity = .idle }
  }

  func rename(_ root: MediaSourceRoot, to name: String) async throws {
    let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !displayName.isEmpty else { return }
    try await catalog.setRootDisplayName(id: root.id, displayName: displayName)
    await load()
  }

  func applyReview(_ review: AbsenceReview) async throws {
    guard let root = root(id: review.rootID), !root.isDetached else {
      throw MediaSourceError.offline
    }
    guard SourceLeaseRegistry.shared.activeLeaseCount(for: review.rootID) == 0 else {
      throw MediaSourceError.quarantined
    }
    guard try await catalog.absenceReviewIsCurrent(review) else {
      throw MediaSourceError.cancelled
    }
    _ = try await observeIdentity(root: root)
    try await catalog.applyAbsenceReview(review)
    updateState(review.rootID) { $0.pendingReview = nil; $0.activity = .idle }
  }

  // MARK: - Playback resolution

  func resolvePlaybackURL(mediaID: UUID) async throws -> (URL, SourceAccessLease) {
    guard let media = try await catalog.media(id: mediaID) else {
      throw MediaSourceError.notFound
    }
    if let rootID = media.rootID {
      // The row belongs to a saved source that is removed, detached or not
      // loaded. Its old alias may now name a different volume's file, so the
      // legacy fallback below is reserved for genuinely rootless rows.
      guard let root = root(id: rootID), !root.isDetached else {
        throw MediaSourceError.offline
      }
      let identity = try await observeIdentity(root: root)
      let relative = SourcePath.normalized(media.relativePath ?? "")
      let url = Self.url(for: relative, mountPath: identity.mountPath,
                         rootPath: identity.pathInNamespace)
      let factory = providerFactory
      let stat = try await executor.perform(
        lane: root.kind == .local ? .local : .network,
        volumeKey: root.namespace.volumeIdentity,
        isBootVolume: root.kind == .local && identity.mountPath == "/") {
          try factory.make(root.kind).stat(at: url)
        }
      guard stat.isReadable else { throw MediaSourceError.permissionDenied }
      try? await catalog.touchMedia(mediaID: media.id, presence: .present)
      try? await catalog.clearPendingAbsenceReviews(rootID: root.id)
      let lease = SourceLeaseRegistry.shared.makeLease(
        mediaID: media.id, rootID: root.id, url: url,
        generation: UInt64(DispatchTime.now().uptimeNanoseconds))
      return (url, lease)
    }
    // Legacy rows without a saved root keep their exact old locator.
    let aliases = try await catalog.aliases(for: media.id)
    if let alias = aliases.first(where: { $0.kind == "filePath" }) {
      let url = URL(fileURLWithPath: alias.value)
      let exists = try await executor.perform(
        lane: .local, volumeKey: "legacy:\(url.deletingLastPathComponent().path)") {
          FileManager.default.fileExists(atPath: url.path)
        }
      guard exists else { throw MediaSourceError.notFound }
      return (url, SourceLeaseRegistry.shared.makeLease(
        mediaID: media.id, rootID: nil, url: url, generation: 0))
    }
    if let alias = aliases.first(where: { $0.kind == "url" }),
       let url = URL(string: alias.value) {
      return (url, SourceLeaseRegistry.shared.makeLease(
        mediaID: media.id, rootID: nil, url: url, generation: 0))
    }
    throw MediaSourceError.invalidLocator
  }

  /// Relink one item to a newly chosen file. A no-collision relink keeps the
  /// same UUID; a proven collision requires explicit confirmation and then
  /// merges by the older first-discovered row.
  func relink(mediaID: UUID, to newURL: URL,
              confirmMerge: Bool = false) async throws -> UUID {
    guard let media = try await catalog.media(id: mediaID) else {
      throw MediaSourceError.notFound
    }
    if let activeRoot = media.rootID,
       SourceLeaseRegistry.shared.activeLeaseCount(for: activeRoot) > 0 {
      throw MediaSourceError.quarantined
    }
    let rawURL = newURL.standardizedFileURL
    let standardized = try await executor.perform(
      lane: Self.lane(for: rawURL), volumeKey: "resolve:\(rawURL.path)") {
        rawURL.resolvingSymlinksInPath().standardizedFileURL
      }
    let parent = standardized.deletingLastPathComponent()
    let factory = providerFactory
    let identity = try await executor.perform(
      lane: Self.lane(for: parent), volumeKey: "identity:\(parent.path)",
      isBootVolume: parent.path == "/") {
        try factory.make(.local).observeIdentity(at: parent)
      }
    let stat = try await executor.perform(
      lane: Self.lane(for: parent), volumeKey: "identity:\(parent.path)",
      isBootVolume: parent.path == "/") {
        try factory.make(.local).stat(at: standardized)
      }
    guard !stat.isDirectory, stat.isReadable else {
      throw MediaSourceError.permissionDenied
    }
    let matchingRoot = roots.first { root in
      root.namespace == identity.namespace
        && (SourcePath.isAncestor(root.pathInNamespace, of: identity.pathInNamespace,
                                  semantics: root.comparison))
    }
    // A collision can retire a row in the target root. Never do that while
    // that root has active playback, even if this item's own root does not.
    if let target = matchingRoot,
       SourceLeaseRegistry.shared.activeLeaseCount(for: target.id) > 0 {
      throw MediaSourceError.quarantined
    }
    let aliasKind = "filePath"
    let aliasValue = standardized.path
    // One live alias owns the chosen path. Claiming it silently would leave
    // the relinked item without a usable locator while some other row keeps
    // the path; a retired alias is reclaimed below.
    let aliasOwner = try await catalog.resolveAlias(kind: aliasKind, value: aliasValue)
    if let root = matchingRoot {
      let rootURL = Self.url(for: "", mountPath: identity.mountPath,
                             rootPath: root.pathInNamespace)
      let relative = relativePath(of: standardized, under: rootURL,
                                  comparison: root.comparison)
      guard let relative else { throw MediaSourceError.invalidLocator }
      let parentRelative = SourcePath.parent(of: relative) ?? root.pathInNamespace
      let key = root.comparison.key(for: relative)
      if let existing = try await catalog.media(rootID: root.id, comparisonKey: key),
         existing.id != media.id {
        guard confirmMerge else {
          throw MediaSourceError.possibleAlias(existing: existing.id)
        }
        // Every refusal happens before a directory row is written.
        guard aliasOwner == nil || aliasOwner == media.id || aliasOwner == existing.id else {
          throw MediaSourceError.possibleAlias(existing: aliasOwner!)
        }
        let directory = try await ensureDirectory(root: root, relativePath: parentRelative)
        let survivor = try await organization.mergeForRelink(mediaID: media.id,
                                                             with: existing.id)
        // The survivor may be the old row; move it to the file the person
        // actually chose before publishing the alias.
        try await catalog.updateMediaLocator(
          mediaID: survivor, rootID: root.id, directoryID: directory.id,
          relativePath: relative, comparisonKey: key,
          name: standardized.lastPathComponent, presence: .present)
        if let owner = try await catalog.addAlias(
          kind: aliasKind, value: aliasValue, mediaID: survivor,
          namespace: root.namespace.persistedValue, replaceRetired: true),
           owner != survivor {
          throw MediaSourceError.possibleAlias(existing: owner)
        }
        try await catalog.removeReason(mediaID: survivor, reason: .indexed)
        try await catalog.addIndexedReasonIfCurrent(mediaID: survivor,
                                                    rootID: root.id)
        try? await catalog.clearPendingAbsenceReviews(rootID: root.id)
        if let oldRoot = media.rootID, oldRoot != root.id {
          try? await catalog.clearPendingAbsenceReviews(rootID: oldRoot)
        }
        return survivor
      }
      guard aliasOwner == nil || aliasOwner == media.id else {
        throw MediaSourceError.possibleAlias(existing: aliasOwner!)
      }
      let directory = try await ensureDirectory(root: root, relativePath: parentRelative)
      // Claim the locator before changing the row, so a concurrent claim
      // cannot leave this item moved but aliasless.
      if let owner = try await catalog.addAlias(
        kind: aliasKind, value: aliasValue, mediaID: media.id,
        namespace: root.namespace.persistedValue, replaceRetired: true),
         owner != media.id {
        throw MediaSourceError.possibleAlias(existing: owner)
      }
      try await catalog.updateMediaLocator(
        mediaID: media.id, rootID: root.id, directoryID: directory.id,
        relativePath: relative, comparisonKey: key, name: standardized.lastPathComponent,
        presence: .present)
      try await catalog.removeReason(mediaID: media.id, reason: .indexed)
      try await catalog.addIndexedReasonIfCurrent(mediaID: media.id,
                                                  rootID: root.id)
      try? await catalog.clearPendingAbsenceReviews(rootID: root.id)
      if let oldRoot = media.rootID, oldRoot != root.id {
        try? await catalog.clearPendingAbsenceReviews(rootID: oldRoot)
      }
      return media.id
    }
    // Outside saved roots there is no directory tree to collide with, but a
    // live alias can still belong to another row. A confirmed merge combines
    // them first; otherwise the relink must not steal the locator.
    var targetID = media.id
    if let aliasOwner, aliasOwner != media.id {
      guard confirmMerge else {
        throw MediaSourceError.possibleAlias(existing: aliasOwner)
      }
      targetID = try await organization.mergeForRelink(mediaID: media.id,
                                                       with: aliasOwner)
    }
    // Claim the locator before retiring the old ones: if another relink won
    // the path in the meantime, this item keeps a usable old alias.
    if let owner = try await catalog.addAlias(
      kind: aliasKind, value: aliasValue, mediaID: targetID, namespace: "",
      replaceRetired: true), owner != targetID {
      throw MediaSourceError.possibleAlias(existing: owner)
    }
    let oldAliases = (try? await catalog.aliases(for: targetID)) ?? []
    for alias in oldAliases
      where alias.value != aliasValue && (alias.kind == "filePath" || alias.kind == "url") {
      try? await catalog.retireAlias(kind: alias.kind, value: alias.value)
    }
    try await catalog.updateMediaLocator(
      mediaID: targetID, rootID: nil, directoryID: nil,
      relativePath: nil, comparisonKey: nil, name: standardized.lastPathComponent,
      presence: .present)
    try await catalog.removeReason(mediaID: targetID, reason: .indexed)
    if let oldRoot = media.rootID {
      try? await catalog.clearPendingAbsenceReviews(rootID: oldRoot)
    }
    return targetID
  }

  // MARK: - Organization

  func createCollection(name: String) async throws -> UUID {
    let id = try await catalog.createCollection(name: name)
    collections = try await catalog.collections()
    return id
  }

  // MARK: - Helpers

  private func observeIdentity(root: MediaSourceRoot) async throws -> SourceIdentity {
    guard let hint = root.resolvedURL else { throw MediaSourceError.offline }
    let factory = providerFactory
    let identity = try await executor.perform(
      lane: root.kind == .local ? .local : .network,
      volumeKey: "identity:\(root.id.uuidString)",
      isBootVolume: root.kind == .local && hint.path == "/") {
        try factory.make(root.kind).observeIdentity(at: hint)
      }
    guard identity.namespace == root.namespace else {
      throw MediaSourceError.identityChanged
    }
    guard identity.comparison == root.comparison else {
      // A changed case/Unicode comparison rule needs a rekey or relink, not a
      // silent merge of two different locator namespaces.
      throw MediaSourceError.identityChanged
    }
    guard root.comparison.key(for: identity.pathInNamespace)
      == root.comparison.key(for: root.pathInNamespace) else {
      throw MediaSourceError.identityChanged
    }
    var updated = root
    if updated.currentMountHint != identity.mountPath {
      updated.currentMountHint = identity.mountPath
      // Only the hint moves here; a stale whole-root write could undo a
      // rename or an inclusion change made while the probe ran.
      try? await catalog.updateRootScanMetadata(id: root.id,
                                                mountHint: updated.currentMountHint,
                                                lastUpdate: nil)
    }
    return identity
  }

  private func relativePath(of url: URL, under rootURL: URL,
                            comparison: ComparisonSemantics) -> String? {
    let rootPath = rootURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == rootPath { return "" }
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    let keyPath = comparison.key(for: path)
    let keyPrefix = comparison.key(for: prefix)
    guard keyPath.hasPrefix(keyPrefix) else { return nil }
    return SourcePath.normalized(String(path.dropFirst(prefix.count)))
  }

  /// Create every ancestor directory so a relinked row keeps a valid parent
  /// chain for browsing. Existing rows are updated in place.
  private func ensureDirectory(root: MediaSourceRoot,
                               relativePath: String) async throws -> MediaDirectory {
    let normalized = SourcePath.normalized(relativePath)
    var parentID: UUID?
    var current = ""
    var directory = try await catalog.upsertDirectory(
      rootID: root.id, parentID: nil, relativePath: "", comparison: root.comparison)
    if normalized.isEmpty { return directory }
    parentID = directory.id
    for component in normalized.split(separator: "/") {
      current = SourcePath.appending(String(component), to: current)
      directory = try await catalog.upsertDirectory(
        rootID: root.id, parentID: parentID, relativePath: current,
        comparison: root.comparison)
      parentID = directory.id
    }
    return directory
  }

  private static func url(for relativePath: String, mountPath: String,
                          rootPath: String) -> URL {
    var url = URL(fileURLWithPath: mountPath, isDirectory: true)
    for component in SourcePath.normalized(rootPath).split(separator: "/") {
      url.appendPathComponent(String(component), isDirectory: true)
    }
    for component in SourcePath.normalized(relativePath).split(separator: "/") {
      url.appendPathComponent(String(component))
    }
    return url
  }

  private func updateState(_ rootID: UUID, _ update: (inout SourceState) -> Void) {
    var state = states[rootID] ?? SourceState()
    update(&state)
    states[rootID] = state
  }

  private static func connectivity(for error: MediaSourceError) -> SourceConnectivity {
    switch error {
    case .offline, .timedOut, .quarantined: return .offline
    case .authenticationRequired: return .authenticationRequired
    case .accessDenied, .permissionDenied: return .accessDenied
    case .identityChanged, .identityUnverified: return .unknown
    default: return .unknown
    }
  }

  /// Identity probes for a candidate root are classified conservatively:
  /// anything under the system mount directory may be a network share, so it
  /// uses the network lane instead of consuming the reserved local capacity.
  private static func lane(for url: URL) -> SourceIOLane {
    SourceIOLane.forPath(url.standardizedFileURL.path)
  }

  private static func defaultDisplayName(url: URL, identity: SourceIdentity) -> String {    if identity.namespace.kind == .mountedSMB,
       let endpoint = identity.namespace.endpointLabel, !endpoint.isEmpty {
      return endpoint
    }
    let component = url.lastPathComponent
    if component.isEmpty || component == "/" {
      return identity.namespace.endpointLabel ?? "Local Folder"
    }
    return component
  }
}

extension Logger.Sub {
  static let mediaSources = Logger.makeSubsystem("media.sources", ["externaldrive"])
  static let mediaCatalog = Logger.makeSubsystem("media.catalog", ["cylinder.split.1x2"])
  static let mediaScan = Logger.makeSubsystem("media.scan", ["magnifyingglass"])
  static let mediaPlayback = Logger.makeSubsystem("media.playback", ["play.circle"])
}
