//
//  MediaSourcesIntegrationTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

@MainActor
final class MediaSourcesIntegrationTests: XCTestCase {

  func testBrowseScanSearchPlayAndRemoveKeepsOrganizedItems() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-integration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("video".utf8).write(to: directory.appendingPathComponent("A.mkv"))
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("A.mkv", false), ("B.mkv", false)]
    let catalog = try MediaCatalog.inMemory()
    let coordinator = SourceCoordinator(
      catalog: catalog,
      executor: SourceIOExecutor(limits: SourceIOLimits(defaultTimeout: 1)),
      providerFactory: SourceProviderFactory { _ in provider })

    guard case .created(let root) = try await coordinator.addRoot(
      at: directory, inclusion: .indexed) else {
      return XCTFail("expected created")
    }
    let snapshot = try await coordinator.browse(rootID: root.id, relativePath: "",
                                                parentID: nil)
    XCTAssertEqual(snapshot.items.count, 2)

    let scan = try await coordinator.scan(rootID: root.id)
    XCTAssertEqual(scan.discovered, 0)
    XCTAssertEqual(scan.updated, 2)

    let library = try await catalog.libraryMedia()
    XCTAssertEqual(library.count, 2)
    let item = try XCTUnwrap(library.first { $0.name == "A.mkv" })

    let (url, lease) = try await coordinator.resolvePlaybackURL(mediaID: item.id)
    XCTAssertTrue(url.lastPathComponent == "A.mkv")
    let plan = MediaPlaybackResolver.plan(
      for: item, url: url, intent: .ordinaryOpen, resumePreference: true)
    XCTAssertEqual(plan.mediaID, item.id)
    XCTAssertTrue(plan.suppressWatchLater)
    XCTAssertEqual(plan.startPosition, 0)
    lease.release()

    let collection = try await coordinator.createCollection(name: "Keep")
    let store = MediaOrganizationStore(catalog: catalog)
    try await store.addToCollection([item.id], to: collection)
    try await store.setFavorite(true, mediaIDs: [item.id])

    try await coordinator.remove(root)
    let retained = try await catalog.libraryMedia()
    XCTAssertEqual(retained.count, 1)
    XCTAssertEqual(retained.first?.id, item.id)
    XCTAssertTrue(retained.first?.reasons.contains(.collection) ?? false)
    XCTAssertTrue(retained.first?.reasons.contains(.favorite) ?? false)
    XCTAssertFalse(retained.first?.reasons.contains(.indexed) ?? true)

    // The file itself was never touched.
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("A.mkv").path))
  }

  func testSearchResultsAreMembershipScoped() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-integration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("A.mkv", false)]
    let catalog = try MediaCatalog.inMemory()
    let coordinator = SourceCoordinator(
      catalog: catalog,
      executor: SourceIOExecutor(limits: SourceIOLimits(defaultTimeout: 1)),
      providerFactory: SourceProviderFactory { _ in provider })
    guard case .created(let root) = try await coordinator.addRoot(at: directory) else {
      return XCTFail("expected created")
    }
    _ = try await coordinator.browse(rootID: root.id, relativePath: "", parentID: nil)
    let browseOnly = try await catalog.search(term: "A", scope: .allLibrary)
    XCTAssertTrue(browseOnly.isEmpty)

    try await coordinator.setInclusion(.indexed, for: root)
    let indexed = try await catalog.search(term: "A", scope: .allLibrary)
    XCTAssertEqual(indexed.count, 1)
  }
}
