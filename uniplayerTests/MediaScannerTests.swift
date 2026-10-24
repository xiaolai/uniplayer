//
//  MediaScannerTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

@MainActor
final class MediaScannerTests: XCTestCase {

  private func makeScanner() async throws -> (MediaScanner, MediaCatalog,
                                              ScriptedProvider, MediaSourceRoot, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-scanner-\(UUID().uuidString)", isDirectory: true)
    let sub = directory.appendingPathComponent("Sub", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("Sub", true), ("Root.mkv", false)]
    provider.directories[sub.path] = [("Nested.mkv", false)]
    let catalog = try MediaCatalog.inMemory()
    let root = MediaSourceRoot(
      id: UUID(), displayName: "Root", kind: .local, bookmark: nil,
      namespace: provider.namespace,
      pathInNamespace: String(directory.path.dropFirst()),
      currentMountHint: "/", comparison: .default, inclusion: .indexed,
      createdAt: Date(), lastSuccessfulUpdate: nil, detachedAt: nil)
    try await catalog.insertRoot(root)
    let scanner = MediaScanner(catalog: catalog, executor: SourceIOExecutor(
      limits: SourceIOLimits(defaultTimeout: 1)), provider: provider, root: root)
    return (scanner, catalog, provider, root, directory)
  }

  func testInitialScanDiscoversAndBrowseDoesNotLoseTheTree() async throws {
    let (scanner, catalog, _, root, _) = try await makeScanner()
    let first = try await scanner.scan(root: root)
    XCTAssertEqual(first.discovered, 2)
    let library = try await catalog.libraryMedia()
    XCTAssertEqual(library.count, 2)
    let rootDirectory = try await catalog.directory(
      rootID: root.id, relativePath: "", comparison: root.comparison)
    XCTAssertNotNil(rootDirectory)
    let snapshot = try await catalog.directorySnapshot(
      directoryID: try XCTUnwrap(rootDirectory?.id))
    XCTAssertEqual(snapshot?.items.count, 1)
    XCTAssertEqual(snapshot?.subdirectories.count, 1)
  }

  func testPartialScanKeepsExistingPresence() async throws {
    let (scanner, catalog, provider, root, directory) = try await makeScanner()
    _ = try await scanner.scan(root: root)
    provider.errors[directory.appendingPathComponent("Sub").path] = .permissionDenied
    let result = try await scanner.scan(root: root)
    XCTAssertTrue(result.partial)
    let nested = try await catalog.libraryMedia().first { $0.name == "Nested.mkv" }
    XCTAssertEqual(nested?.presence, .present)
  }

  func testCancelledScanDoesNotApplyAbsence() async throws {
    let (scanner, _, _, root, _) = try await makeScanner()
    scanner.cancel()
    let result = try await scanner.scan(root: root)
    XCTAssertTrue(result.cancelled)
    XCTAssertNil(result.review)
  }

  func testDeletedDirectoryDerivesDescendantAbsence() async throws {
    let (scanner, catalog, provider, root, directory) = try await makeScanner()
    _ = try await scanner.scan(root: root)
    provider.directories[directory.path] = [("Root.mkv", false)]
    _ = try await scanner.scan(root: root)

    let sub = try await catalog.directory(rootID: root.id, relativePath: "Sub",
                                          comparison: root.comparison)
    let subDirectory = try XCTUnwrap(sub)
    XCTAssertFalse(subDirectory.snapshotComplete)
    XCTAssertEqual(subDirectory.ancestorAbsence, "")
    let nested = try await catalog.libraryMedia().first { $0.name == "Nested.mkv" }
    XCTAssertEqual(nested?.presence, .missing)
  }

  func testUnverifiedIdentityRequiresReviewForMissingItems() async throws {
    let (scanner, _, provider, root, directory) = try await makeScanner()
    _ = try await scanner.scan(root: root)
    provider.forceUnverified = true
    provider.directories[directory.path] = []
    let result = try await scanner.scan(root: root)
    XCTAssertNotNil(result.review)
    // The empty directory review and the deleted-directory review are merged.
    // The second one is new: an unverified source must ask about descendants
    // too, instead of silently ignoring a missing subdirectory.
    XCTAssertEqual(result.review?.reason, "mixedAbsence")
    let reviewed = Set(result.review?.missingMediaIDs ?? [])
    XCTAssertEqual(reviewed.count, 2)
  }

  func testScanMergesALegacyRowThatOwnsTheSameLocator() async throws {
    let (scanner, catalog, _, root, directory) = try await makeScanner()
    let legacyPath = directory.appendingPathComponent("Root.mkv").path
    let legacyID = try await catalog.importLegacyMedia(
      aliasKind: "filePath", aliasValue: legacyPath, name: "Root.mkv",
      duration: 120, added: Date(timeIntervalSince1970: 1000), presence: .unknown)
    try await catalog.addReason(mediaID: legacyID, reason: .history,
                                originID: "playbackHistory")

    _ = try await scanner.scan(root: root)

    let matches = try await catalog.libraryMedia().filter { $0.name == "Root.mkv" }
    XCTAssertEqual(matches.count, 1)
    let row = try XCTUnwrap(matches.first)
    XCTAssertNotEqual(row.id, legacyID)
    let legacyRow = try await catalog.media(id: legacyID)
    XCTAssertNil(legacyRow)
    let reasons = try await catalog.reasons(mediaID: row.id)
    XCTAssertTrue(reasons.contains(.history))
    XCTAssertTrue(reasons.contains(.indexed))
    let alias = try await catalog.resolveAlias(kind: "filePath", value: legacyPath)
    XCTAssertEqual(alias, row.id)
  }
}
