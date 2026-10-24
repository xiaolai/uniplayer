//
//  MediaOrganizationTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

@MainActor
final class MediaOrganizationTests: XCTestCase {

  private func makeCatalogAndMedia() async throws -> (MediaCatalog, MediaSourceRoot, UUID) {
    let catalog = try MediaCatalog.inMemory()
    let root = MediaSourceRoot(
      id: UUID(), displayName: "Root", kind: .local, bookmark: nil,
      namespace: SourceNamespace(kind: .local, volumeIdentity: "vol",
                                 fileSystemType: "apfs", endpointLabel: nil,
                                 accountContextLabel: nil),
      pathInNamespace: "", currentMountHint: "/tmp", comparison: .default,
      inclusion: .indexed, createdAt: Date(), lastSuccessfulUpdate: nil,
      detachedAt: nil)
    try await catalog.insertRoot(root)
    let id = try await catalog.upsertMedia(
      rootID: root.id, directoryID: nil, relativePath: "A.mkv",
      comparisonKey: "a.mkv", name: "A.mkv", size: 10, modifiedAt: nil,
      duration: 100, presence: .present)
    return (catalog, root, id)
  }

  func testAddToCollectionUndoRestoresNoCollectionReason() async throws {
    let (catalog, _, id) = try await makeCatalogAndMedia()
    let collection = try await catalog.createCollection(name: "C")
    let store = MediaOrganizationStore(catalog: catalog, mirrorLegacyDefaults: false)

    try await store.addToCollection([id], to: collection)
    var reasons = try await catalog.reasons(mediaID: id)
    XCTAssertTrue(reasons.contains(.collection))

    try await store.undo()
    reasons = try await catalog.reasons(mediaID: id)
    XCTAssertFalse(reasons.contains(.collection))
    let links = try await catalog.collectionMediaIDs(id: collection)
    XCTAssertTrue(links.isEmpty)

    try await store.redo()
    reasons = try await catalog.reasons(mediaID: id)
    XCTAssertTrue(reasons.contains(.collection))
  }

  func testRemoveFromCollectionUndoRestoresExactLink() async throws {
    let (catalog, _, id) = try await makeCatalogAndMedia()
    let collection = try await catalog.createCollection(name: "C")
    try await catalog.addToCollection(collectionID: collection, mediaIDs: [id])
    let store = MediaOrganizationStore(catalog: catalog, mirrorLegacyDefaults: false)

    try await store.removeFromCollection([id], from: collection)
    let emptyLinks = try await catalog.collectionMediaIDs(id: collection)
    XCTAssertTrue(emptyLinks.isEmpty)

    try await store.undo()
    let links = try await catalog.collectionMediaIDs(id: collection)
    XCTAssertEqual(links, [id])
    let reasons = try await catalog.reasons(mediaID: id)
    XCTAssertTrue(reasons.contains(.collection))
  }

  func testFavoriteUndoRestoresPriorState() async throws {
    let (catalog, _, id) = try await makeCatalogAndMedia()
    let store = MediaOrganizationStore(catalog: catalog, mirrorLegacyDefaults: false)

    try await store.setFavorite(true, mediaIDs: [id])
    var reasons = try await catalog.reasons(mediaID: id)
    XCTAssertTrue(reasons.contains(.favorite))

    try await store.undo()
    reasons = try await catalog.reasons(mediaID: id)
    XCTAssertFalse(reasons.contains(.favorite))

    try await store.redo()
    reasons = try await catalog.reasons(mediaID: id)
    XCTAssertTrue(reasons.contains(.favorite))
  }

  func testWatchedUndoRestoresPriorPlayStateExactly() async throws {
    let (catalog, _, id) = try await makeCatalogAndMedia()
    let prior = MediaPlayState(mediaID: id, observedPosition: 33,
                               observedDuration: 100, completed: false,
                               manualWatchedOverride: nil,
                               lastManualActionAt: nil, lastManualActionKind: nil,
                               observedAt: Date(timeIntervalSince1970: 1000), revision: 4)
    try await catalog.replacePlayState(mediaID: id, state: prior)
    let store = MediaOrganizationStore(catalog: catalog, mirrorLegacyDefaults: false)

    try await store.markWatched(true, mediaIDs: [id])
    let watched = try await catalog.playState(mediaID: id)
    XCTAssertEqual(watched?.manualWatchedOverride, true)

    try await store.undo()
    let restored = try await catalog.playState(mediaID: id)
    XCTAssertEqual(restored, prior)
  }

  func testMergeUndoRestoresBothRowsAndRedirects() async throws {
    let (catalog, root, first) = try await makeCatalogAndMedia()
    let second = try await catalog.upsertMedia(
      rootID: root.id, directoryID: nil, relativePath: "B.mkv",
      comparisonKey: "b.mkv", name: "B.mkv", size: 10, modifiedAt: nil,
      duration: 100, presence: .present)
    try await catalog.addReason(mediaID: first, reason: .explicit, originID: "explicit")
    try await catalog.addReason(mediaID: second, reason: .favorite, originID: "favorite")
    let store = MediaOrganizationStore(catalog: catalog, mirrorLegacyDefaults: false)

    let survivor = try await store.merge(mediaID: first, with: second)
    XCTAssertTrue(survivor == first || survivor == second)
    let retired = survivor == first ? second : first
    let retiredRow = try await catalog.media(id: retired)
    XCTAssertNil(retiredRow)
    let redirect = try await catalog.resolveRedirect(id: retired)
    XCTAssertEqual(redirect, survivor)

    try await store.undo()
    let firstRow = try await catalog.media(id: first)
    let secondRow = try await catalog.media(id: second)
    XCTAssertNotNil(firstRow)
    XCTAssertNotNil(secondRow)
    let restoredRedirect = try await catalog.resolveRedirect(id: retired)
    XCTAssertNil(restoredRedirect)
  }

  func testMergeUndoRepointsOlderRedirectsBackToTheRestoredRow() async throws {
    let (catalog, root, first) = try await makeCatalogAndMedia()
    let second = try await catalog.upsertMedia(
      rootID: root.id, directoryID: nil, relativePath: "B.mkv",
      comparisonKey: "b.mkv", name: "B.mkv", size: 10, modifiedAt: nil,
      duration: 100, presence: .present)
    let third = try await catalog.upsertMedia(
      rootID: root.id, directoryID: nil, relativePath: "C.mkv",
      comparisonKey: "c.mkv", name: "C.mkv", size: 10, modifiedAt: nil,
      duration: 100, presence: .present)
    // Third was merged into second before the merge under test, so its
    // redirect is re-pointed at first by that merge.
    _ = try await catalog.mergeMedia(retiredID: third, survivingID: second,
                                     operationID: "test:first")
    guard let firstSnapshot = try await catalog.snapshot(mediaID: first),
          let secondSnapshot = try await catalog.snapshot(mediaID: second) else {
      return XCTFail("missing snapshots")
    }
    _ = try await catalog.mergeMedia(retiredID: second, survivingID: first,
                                     operationID: "test:second")
    let mergedRedirect = try await catalog.resolveRedirect(id: third)
    XCTAssertEqual(mergedRedirect, first)

    try await catalog.restore([firstSnapshot, secondSnapshot])
    let restoredRedirect = try await catalog.resolveRedirect(id: third)
    XCTAssertEqual(restoredRedirect, second)
  }

  func testBatchRestoreIsAtomicWhenOneLocatorIsOccupied() async throws {
    let (catalog, root, first) = try await makeCatalogAndMedia()
    let second = try await catalog.upsertMedia(
      rootID: root.id, directoryID: nil, relativePath: "B.mkv",
      comparisonKey: "b.mkv", name: "B.mkv", size: 10, modifiedAt: nil,
      duration: 100, presence: .present)
    guard let firstSnapshot = try await catalog.snapshot(mediaID: first),
          let secondSnapshot = try await catalog.snapshot(mediaID: second) else {
      return XCTFail("missing snapshots")
    }
    _ = try await catalog.mergeMedia(retiredID: second, survivingID: first,
                                     operationID: "test:merge")
    let replacement = try await catalog.upsertMedia(
      rootID: root.id, directoryID: nil, relativePath: "B.mkv",
      comparisonKey: "b.mkv", name: "B.mkv", size: 10, modifiedAt: nil,
      duration: 100, presence: .present)

    do {
      try await catalog.restore([firstSnapshot, secondSnapshot])
      XCTFail("expected the occupied locator to refuse the batch")
    } catch {
      guard case MediaSourceError.possibleAlias = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }

    // The first restore ran before the refusal; the transaction must have
    // rolled it back, redirect included.
    let redirect = try await catalog.resolveRedirect(id: second)
    XCTAssertEqual(redirect, first)
    let survivorRow = try await catalog.media(id: first)
    XCTAssertNotNil(survivorRow)
    let replacementRow = try await catalog.media(id: replacement)
    XCTAssertNotNil(replacementRow)
  }

  func testBatchWatchedUndoRefusesAtomicallyWhenOneRowMoved() async throws {
    let (catalog, root, first) = try await makeCatalogAndMedia()
    let second = try await catalog.upsertMedia(
      rootID: root.id, directoryID: nil, relativePath: "B.mkv",
      comparisonKey: "b.mkv", name: "B.mkv", size: 10, modifiedAt: nil,
      duration: 100, presence: .present)
    let store = MediaOrganizationStore(catalog: catalog, mirrorLegacyDefaults: false)
    try await store.markWatched(true, mediaIDs: [first, second])

    // Playback advances one row; the whole batch must refuse, not just it.
    try await catalog.savePlayState(MediaPlayState(
      mediaID: second, observedPosition: 90, observedDuration: 100,
      completed: false, manualWatchedOverride: nil,
      lastManualActionAt: nil, lastManualActionKind: nil,
      observedAt: Date(), revision: 99))
    let firstState = try await catalog.playState(mediaID: first)
    do {
      try await store.undo()
      XCTFail("expected a moved revision to refuse the batch undo")
    } catch {
      guard case MediaSourceError.conflict = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    let firstAfter = try await catalog.playState(mediaID: first)
    XCTAssertEqual(firstAfter, firstState)
  }

  func testMergeUndoRefusesAfterPlaybackRevisionMoves() async throws {
    let (catalog, _, first) = try await makeCatalogAndMedia()
    let second = try await catalog.upsertMedia(
      rootID: nil, directoryID: nil, relativePath: nil, comparisonKey: nil,
      name: "B.mkv", size: nil, modifiedAt: nil, duration: 100,
      presence: .present)
    let store = MediaOrganizationStore(catalog: catalog, mirrorLegacyDefaults: false)

    let survivor = try await store.merge(mediaID: first, with: second)
    try await catalog.savePlayState(MediaPlayState(
      mediaID: survivor, observedPosition: 80, observedDuration: 100,
      completed: false, manualWatchedOverride: nil,
      lastManualActionAt: nil, lastManualActionKind: nil,
      observedAt: Date(), revision: 9))

    do {
      try await store.undo()
      XCTFail("expected guarded undo to refuse")
    } catch {
      guard let organization = error as? OrganizationError,
            case .cannotUndo = organization else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }
}
