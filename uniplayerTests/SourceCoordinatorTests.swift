//
//  SourceCoordinatorTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

final class ScriptedProvider: MediaSourceProvider {
  var kind: MediaSourceKind = .local
  var namespace: SourceNamespace
  var directories: [String: [(name: String, directory: Bool)]] = [:]
  var errors: [String: MediaSourceError] = [:]
  var blockedPaths: Set<String> = []
  var forceUnverified = false
  var listCalls = 0
  var block: DispatchSemaphore?

  init(namespace: SourceNamespace = SourceNamespace(
    kind: .local, volumeIdentity: "scripted", fileSystemType: "apfs",
    endpointLabel: "Scripted", accountContextLabel: nil)) {
    self.namespace = namespace
  }

  func observeIdentity(at url: URL) throws -> SourceIdentity {
    let path = url.standardizedFileURL.path
    let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
    return SourceIdentity(
      namespace: namespace,
      pathInNamespace: relative,
      comparison: .default,
      mountPath: "/",
      isVerified: !forceUnverified)
  }

  func listDirectory(at url: URL, generation: UInt64) throws -> DirectoryListing {
    listCalls += 1
    if let error = errors[url.path] { throw error }
    if blockedPaths.contains(url.path) { block?.wait() }
    let names = directories[url.path] ?? []
    let entries = names.map { item -> DirectoryEntry in
      let child = url.appendingPathComponent(item.name, isDirectory: item.directory)
      return DirectoryEntry(url: child, name: item.name, isDirectory: item.directory,
                            isSymbolicLink: false, isPackage: false,
                            size: item.directory ? nil : 10, modified: Date())
    }
    return DirectoryListing(url: url, entries: entries, isComplete: true,
                            observedAt: Date(), generation: generation)
  }

  func stat(at url: URL) throws -> FileStat {
    FileStat(url: url, isDirectory: false, isSymbolicLink: false,
             isPackage: false, size: 10, modified: Date(), isReadable: true)
  }
}

@MainActor
final class SourceCoordinatorTests: XCTestCase {

  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-coordinator-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func makeCoordinator(provider: ScriptedProvider,
                               executor: SourceIOExecutor = SourceIOExecutor(
                                limits: SourceIOLimits(defaultTimeout: 1)))
    throws -> SourceCoordinator {
    let catalog = try MediaCatalog.inMemory()
    return SourceCoordinator(
      catalog: catalog, executor: executor,
      providerFactory: SourceProviderFactory { _ in provider })
  }

  func testAddRootIsIdempotentAndDetachedRootRestores() async throws {
    let directory = try makeTempDirectory()
    let provider = ScriptedProvider()
    let coordinator = try makeCoordinator(provider: provider)

    let first = try await coordinator.addRoot(at: directory)
    guard case .created(let root) = first else {
      return XCTFail("expected created")
    }
    guard case .existing = try await coordinator.addRoot(at: directory) else {
      return XCTFail("expected existing")
    }
    try await coordinator.remove(root)
    guard case .restore(let detached) = try await coordinator.addRoot(at: directory) else {
      return XCTFail("expected restore")
    }
    let restored = try await coordinator.restore(detached)
    XCTAssertFalse(restored.isDetached)
  }

  func testOverlappingRootIsRejected() async throws {
    let directory = try makeTempDirectory()
    let child = directory.appendingPathComponent("Sub", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let provider = ScriptedProvider()
    let coordinator = try makeCoordinator(provider: provider)

    _ = try await coordinator.addRoot(at: directory)
    guard case .overlap = try await coordinator.addRoot(at: child) else {
      return XCTFail("expected overlap")
    }
  }

  func testBrowsePersistsBrowseOnlyRowsWithoutMembership() async throws {
    let directory = try makeTempDirectory()
    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("A.mkv", false), ("B.mkv", false)]
    let coordinator = try makeCoordinator(provider: provider)
    let outcome = try await coordinator.addRoot(at: directory)
    guard case .created(let root) = outcome else { return XCTFail("expected created") }

    let snapshot = try await coordinator.browse(rootID: root.id, relativePath: "",
                                                parentID: nil)
    XCTAssertEqual(snapshot.items.count, 2)
    let library = try await coordinator.catalog.libraryMedia()
    XCTAssertTrue(library.isEmpty)
    let cached = try await coordinator.catalog.directorySnapshot(
      directoryID: snapshot.directory.id)
    XCTAssertEqual(cached?.items.count, 2)
  }

  func testIncludeIndexesBrowsedRows() async throws {
    let directory = try makeTempDirectory()
    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("A.mkv", false), ("B.mkv", false)]
    let coordinator = try makeCoordinator(provider: provider)
    guard case .created(let root) = try await coordinator.addRoot(at: directory) else {
      return XCTFail("expected created")
    }
    _ = try await coordinator.browse(rootID: root.id, relativePath: "", parentID: nil)
    try await coordinator.setInclusion(.indexed, for: root)
    let library = try await coordinator.catalog.libraryMedia()
    XCTAssertEqual(library.count, 2)
  }

  func testScanMassAbsenceNeedsReview() async throws {
    let directory = try makeTempDirectory()
    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("A.mkv", false), ("B.mkv", false)]
    let coordinator = try makeCoordinator(provider: provider)
    guard case .created(let root) = try await coordinator.addRoot(
      at: directory, inclusion: .indexed) else {
      return XCTFail("expected created")
    }
    _ = try await coordinator.scan(rootID: root.id)
    let initial = try await coordinator.catalog.libraryMedia()
    XCTAssertEqual(initial.count, 2)

    provider.directories[directory.path] = []
    let result = try await coordinator.scan(rootID: root.id)
    let review = try XCTUnwrap(result.review)
    XCTAssertEqual(review.reason, "emptyRoot")
    let beforeReview = try await coordinator.catalog.libraryMedia()
    XCTAssertEqual(beforeReview.filter(\.isMissing).count, 0)

    try await coordinator.applyReview(review)
    let afterReview = try await coordinator.catalog.libraryMedia()
    XCTAssertEqual(afterReview.filter(\.isMissing).count, 2)
  }

  func testPartialScanDoesNotMarkExistingChildrenMissing() async throws {
    let directory = try makeTempDirectory()
    let sub = directory.appendingPathComponent("Sub", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("Sub", true), ("Root.mkv", false)]
    provider.directories[sub.path] = [("Nested.mkv", false)]
    let coordinator = try makeCoordinator(provider: provider)
    guard case .created(let root) = try await coordinator.addRoot(
      at: directory, inclusion: .indexed) else {
      return XCTFail("expected created")
    }
    _ = try await coordinator.scan(rootID: root.id)
    let initial = try await coordinator.catalog.libraryMedia()
    XCTAssertEqual(initial.count, 2)

    provider.errors[sub.path] = .permissionDenied
    let result = try await coordinator.scan(rootID: root.id)
    XCTAssertTrue(result.partial)
    XCTAssertNil(result.review)
    let nested = try await coordinator.catalog.libraryMedia()
      .first { $0.name == "Nested.mkv" }
    XCTAssertEqual(nested?.presence, .present)
  }

  func testIdentityChangeRejectsScan() async throws {
    let directory = try makeTempDirectory()
    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("A.mkv", false)]
    let coordinator = try makeCoordinator(provider: provider)
    guard case .created(let root) = try await coordinator.addRoot(
      at: directory, inclusion: .indexed) else {
      return XCTFail("expected created")
    }
    provider.namespace = SourceNamespace(
      kind: .local, volumeIdentity: "different", fileSystemType: "apfs",
      endpointLabel: "Other", accountContextLabel: nil)
    do {
      _ = try await coordinator.scan(rootID: root.id)
      XCTFail("expected identity change")
    } catch {
      XCTAssertEqual(error as? MediaSourceError, .identityChanged)
    }
  }

  func testRelinkWithoutCollisionKeepsUUID() async throws {
    let directory = try makeTempDirectory()
    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("A.mkv", false)]
    let coordinator = try makeCoordinator(provider: provider)
    guard case .created(let root) = try await coordinator.addRoot(
      at: directory, inclusion: .indexed) else {
      return XCTFail("expected created")
    }
    _ = try await coordinator.scan(rootID: root.id)
    let library = try await coordinator.catalog.libraryMedia()
    let media = try XCTUnwrap(library.first)

    let newURL = directory.appendingPathComponent("B.mkv")
    let id = try await coordinator.relink(mediaID: media.id, to: newURL)
    XCTAssertEqual(id, media.id)
    let updated = try await coordinator.catalog.media(id: media.id)
    XCTAssertEqual(updated?.relativePath, "B.mkv")
    XCTAssertEqual(updated?.name, "B.mkv")
  }

  func testRelinkCollisionRequiresConfirmation() async throws {
    let directory = try makeTempDirectory()
    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("A.mkv", false), ("B.mkv", false)]
    let coordinator = try makeCoordinator(provider: provider)
    guard case .created(let root) = try await coordinator.addRoot(
      at: directory, inclusion: .indexed) else {
      return XCTFail("expected created")
    }
    _ = try await coordinator.scan(rootID: root.id)
    let items = try await coordinator.catalog.libraryMedia()
    let a = try XCTUnwrap(items.first { $0.name == "A.mkv" })
    let b = try XCTUnwrap(items.first { $0.name == "B.mkv" })

    do {
      _ = try await coordinator.relink(
        mediaID: a.id, to: directory.appendingPathComponent("B.mkv"))
      XCTFail("expected confirmation requirement")
    } catch {
      guard case .possibleAlias(let existing) = (error as? MediaSourceError) else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(existing, b.id)
    }
    let stillA = try await coordinator.catalog.media(id: a.id)
    let stillB = try await coordinator.catalog.media(id: b.id)
    XCTAssertNotNil(stillA)
    XCTAssertNotNil(stillB)
  }

  func testRelinkRefusesAPathOwnedByAnotherRow() async throws {
    let directory = try makeTempDirectory()
    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("A.mkv", false)]
    let coordinator = try makeCoordinator(provider: provider)
    guard case .created(let root) = try await coordinator.addRoot(
      at: directory, inclusion: .indexed) else {
      return XCTFail("expected created")
    }
    _ = try await coordinator.scan(rootID: root.id)
    let library = try await coordinator.catalog.libraryMedia()
    let a = try XCTUnwrap(library.first { $0.name == "A.mkv" })

    let target = directory.appendingPathComponent("B.mkv")
    let otherID = try await coordinator.catalog.upsertMedia(
      rootID: nil, directoryID: nil, relativePath: nil, comparisonKey: nil,
      name: "B.mkv", size: nil, modifiedAt: nil, duration: nil,
      presence: .present)
    _ = try await coordinator.catalog.addAlias(
      kind: "filePath", value: target.path, mediaID: otherID, namespace: "")

    do {
      _ = try await coordinator.relink(mediaID: a.id, to: target)
      XCTFail("expected the live alias owner to block the relink")
    } catch {
      guard case .possibleAlias(let existing) = (error as? MediaSourceError) else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(existing, otherID)
    }
    let unchanged = try await coordinator.catalog.media(id: a.id)
    XCTAssertEqual(unchanged?.relativePath, "A.mkv")
  }

  func testRelinkOutsideRootsMergesAConfirmedAliasCollision() async throws {
    let directory = try makeTempDirectory()
    let provider = ScriptedProvider()
    let coordinator = try makeCoordinator(provider: provider)
    let target = directory.appendingPathComponent("B.mkv")

    let first = try await coordinator.catalog.importLegacyMedia(
      aliasKind: "filePath",
      aliasValue: directory.appendingPathComponent("A.mkv").path,
      name: "A.mkv", duration: 10, added: Date(timeIntervalSince1970: 1000),
      presence: .unknown)
    let second = try await coordinator.catalog.importLegacyMedia(
      aliasKind: "filePath", aliasValue: target.path,
      name: "B.mkv", duration: 10, added: Date(timeIntervalSince1970: 2000),
      presence: .present)

    let survivor = try await coordinator.relink(mediaID: first, to: target,
                                                confirmMerge: true)
    XCTAssertEqual(survivor, first)
    let merged = try await coordinator.catalog.media(id: first)
    XCTAssertNotNil(merged)
    let retired = try await coordinator.catalog.media(id: second)
    XCTAssertNil(retired)
    let aliasOwner = try await coordinator.catalog.resolveAlias(
      kind: "filePath", value: target.path)
    XCTAssertEqual(aliasOwner, first)
  }

  func testRelinkCollisionMergesIntoOlderRow() async throws {
    let directory = try makeTempDirectory()
    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("A.mkv", false), ("B.mkv", false)]
    let coordinator = try makeCoordinator(provider: provider)
    guard case .created(let root) = try await coordinator.addRoot(
      at: directory, inclusion: .indexed) else {
      return XCTFail("expected created")
    }
    _ = try await coordinator.scan(rootID: root.id)
    let items = try await coordinator.catalog.libraryMedia()
    let a = try XCTUnwrap(items.first { $0.name == "A.mkv" })
    let b = try XCTUnwrap(items.first { $0.name == "B.mkv" })
    let expected = a.firstDiscoveredAt <= b.firstDiscoveredAt ? a : b
    let other = expected.id == a.id ? b : a

    let id = try await coordinator.relink(
      mediaID: other.id, to: directory.appendingPathComponent(expected.name),
      confirmMerge: true)
    XCTAssertEqual(id, expected.id)
    let retired = try await coordinator.catalog.media(id: other.id)
    XCTAssertNil(retired)
    let redirect = try await coordinator.catalog.resolveRedirect(id: other.id)
    XCTAssertEqual(redirect, expected.id)
    let remaining = try await coordinator.catalog.libraryMedia()
    XCTAssertEqual(remaining.count, 1)
  }
}
