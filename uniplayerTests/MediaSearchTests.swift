//
//  MediaSearchTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

final class MediaSearchTests: XCTestCase {

  private func makeCatalog() async throws -> (MediaCatalog, MediaSourceRoot, [UUID]) {
    let catalog = try MediaCatalog.inMemory()
    let root = MediaSourceRoot(
      id: UUID(), displayName: "Root", kind: .local, bookmark: nil,
      namespace: SourceNamespace(kind: .local, volumeIdentity: "v",
                                 fileSystemType: "apfs", endpointLabel: nil,
                                 accountContextLabel: nil),
      pathInNamespace: "", currentMountHint: "/tmp", comparison: .default,
      inclusion: .indexed, createdAt: Date(), lastSuccessfulUpdate: nil,
      detachedAt: nil)
    try await catalog.insertRoot(root)
    let directory = try await catalog.upsertDirectory(
      rootID: root.id, parentID: nil, relativePath: "Movies",
      comparison: root.comparison)
    var ids: [UUID] = []
    for (index, name) in ["Alpha.mkv", "Beta.mkv", "Gamma.mkv"].enumerated() {
      let id = try await catalog.upsertMedia(
        rootID: root.id, directoryID: directory.id, relativePath: name,
        comparisonKey: root.comparison.key(for: name), name: name,
        size: Int64(index), modifiedAt: nil, duration: 100, presence: .present)
      try await catalog.addReason(mediaID: id, reason: .indexed,
                                  originID: root.id.uuidString)
      ids.append(id)
    }
    return (catalog, root, ids)
  }

  func testAllLibraryAndIndexedScope() async throws {
    let (catalog, root, _) = try await makeCatalog()
    let all = try await catalog.search(term: "a", scope: .allLibrary)
    XCTAssertEqual(all.count, 3)
    let indexed = try await catalog.search(term: "a", scope: .indexedRoot(root.id))
    XCTAssertEqual(indexed.count, 3)
  }

  func testFiltersComposeWithSearch() async throws {
    let (catalog, _, ids) = try await makeCatalog()
    try await catalog.setFavorite(mediaID: ids[0], favorite: true)
    try await catalog.markWatched(mediaID: ids[1], watched: true)
    try await catalog.setPresence(mediaIDs: [ids[2]], presence: .missing)

    let favorites = try await catalog.search(term: "", scope: .allLibrary,
                                             filter: .favorites)
    XCTAssertEqual(favorites.map(\.id), [ids[0]])

    let watched = try await catalog.search(term: "", scope: .allLibrary,
                                           filter: .watched)
    XCTAssertEqual(watched.map(\.id), [ids[1]])

    let missing = try await catalog.search(term: "", scope: .allLibrary,
                                           filter: .missing)
    XCTAssertEqual(missing.map(\.id), [ids[2]])

    let unfinished = try await catalog.search(term: "", scope: .allLibrary,
                                              filter: .unfinished)
    XCTAssertEqual(Set(unfinished.map(\.id)), Set([ids[0], ids[2]]))
  }

  func testThisFolderScopeDoesNotLeakOtherDirectories() async throws {
    let (catalog, root, ids) = try await makeCatalog()
    let other = try await catalog.upsertDirectory(
      rootID: root.id, parentID: nil, relativePath: "Other",
      comparison: root.comparison)
    let otherID = try await catalog.upsertMedia(
      rootID: root.id, directoryID: other.id, relativePath: "Delta.mkv",
      comparisonKey: root.comparison.key(for: "Delta.mkv"), name: "Delta.mkv",
      size: nil, modifiedAt: nil, duration: nil, presence: .present)
    let movies = try await catalog.directory(rootID: root.id, relativePath: "Movies",
                                             comparison: root.comparison)
    let movieDirectoryID = try XCTUnwrap(movies?.id)
    let local = try await catalog.search(term: "a",
                                         scope: .thisFolder(movieDirectoryID))
    XCTAssertEqual(Set(local.map(\.id)), Set(ids))
    XCTAssertFalse(local.map(\.id).contains(otherID))
  }
}
