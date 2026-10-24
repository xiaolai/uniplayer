//
//  MediaCatalogTests.swift
//  UniPlayerTests
//

import Foundation
import SQLite3
import XCTest
@testable import UniPlayer

final class MediaCatalogTests: XCTestCase {

  private func makeCatalog() throws -> MediaCatalog {
    try MediaCatalog.inMemory()
  }

  private func root(path: String = "", inclusion: SourceInclusion = .indexed,
                    namespace: String = "volume-1") -> MediaSourceRoot {
    MediaSourceRoot(
      id: UUID(),
      displayName: "Test Source",
      kind: .local,
      bookmark: nil,
      namespace: SourceNamespace(kind: .local, volumeIdentity: namespace,
                                 fileSystemType: "apfs", endpointLabel: "Test",
                                 accountContextLabel: nil),
      pathInNamespace: path,
      currentMountHint: "/Volumes/Test",
      comparison: .default,
      inclusion: inclusion,
      createdAt: Date(),
      lastSuccessfulUpdate: nil,
      detachedAt: nil)
  }

  private func media(_ catalog: MediaCatalog, root: MediaSourceRoot,
                     path: String, name: String? = nil) async throws -> UUID {
    let key = root.comparison.key(for: path)
    return try await catalog.upsertMedia(
      rootID: root.id, directoryID: nil, relativePath: path,
      comparisonKey: key, name: name ?? SourcePath.lastComponent(of: path),
      size: 100, modifiedAt: Date(timeIntervalSince1970: 100),
      duration: nil, presence: .present)
  }

  // MARK: - Roots

  func testRootRoundTripAndDetachRestore() async throws {
    let catalog = try makeCatalog()
    let source = root(path: "Videos")
    try await catalog.insertRoot(source)

    let loaded = try await catalog.roots()
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded.first?.namespace, source.namespace)
    XCTAssertEqual(loaded.first?.pathInNamespace, "Videos")

    try await catalog.detachRoot(id: source.id)
    let detached = try await catalog.roots()
    XCTAssertEqual(detached.first?.isDetached, true)
    let active = try await catalog.roots(includeDetached: false)
    XCTAssertTrue(active.isEmpty)

    try await catalog.restoreRoot(id: source.id)
    let restored = try await catalog.roots()
    XCTAssertEqual(restored.first?.isDetached, false)
  }

  func testRootOverlapUsesComparisonSemantics() {
    var parent = root(path: "Videos")
    var child = root(path: "Videos/Movies")
    child.id = UUID()
    XCTAssertTrue(parent.overlaps(with: child))
    XCTAssertTrue(child.overlaps(with: parent))

    parent.pathInNamespace = "Videos"
    child.pathInNamespace = "Videos-Other"
    XCTAssertFalse(parent.overlaps(with: child))
  }

  // MARK: - Media identity

  func testUpsertSameLocatorReturnsSameID() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)

    let first = try await media(catalog, root: source, path: "Movies/A.mkv")
    let second = try await media(catalog, root: source, path: "Movies/A.mkv")
    XCTAssertEqual(first, second)
  }

  func testCaseAndUnicodeFoldingsShareOneRow() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)

    // Case folding and canonical Unicode equivalence are locator identity.
    // Diacritics remain distinct names, so they are not stripped here.
    let first = try await media(catalog, root: source, path: "Movies/Cafe\u{301}.mkv")
    let second = try await media(catalog, root: source, path: "movies/Café.mkv")
    XCTAssertEqual(first, second)

    let items = try await catalog.libraryMedia()
    XCTAssertTrue(items.isEmpty)
  }

  func testAliasesResolveAndRetire() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let id = try await media(catalog, root: source, path: "A.mkv")

    let collision = try await catalog.addAlias(
      kind: "filePath", value: "/tmp/A.mkv", mediaID: id, namespace: "ns")
    XCTAssertNil(collision)
    let resolved = try await catalog.resolveAlias(kind: "filePath", value: "/tmp/A.mkv")
    XCTAssertEqual(resolved, id)

    try await catalog.retireAlias(kind: "filePath", value: "/tmp/A.mkv")
    let retired = try await catalog.resolveAlias(kind: "filePath", value: "/tmp/A.mkv")
    XCTAssertNil(retired)
  }

  // MARK: - Membership

  func testLibraryRequiresAMembershipReasonAndHonorsHidden() async throws {
    let catalog = try makeCatalog()
    let source = root(inclusion: .browseOnly)
    try await catalog.insertRoot(source)
    let id = try await media(catalog, root: source, path: "A.mkv")

    let emptyLibrary = try await catalog.libraryMedia()
    XCTAssertTrue(emptyLibrary.isEmpty)
    try await catalog.addReason(mediaID: id, reason: .explicit, originID: "explicit")
    let library = try await catalog.libraryMedia()
    XCTAssertEqual(library.count, 1)

    try await catalog.setHidden(mediaID: id, hidden: true)
    let hiddenLibrary = try await catalog.libraryMedia()
    XCTAssertTrue(hiddenLibrary.isEmpty)
    let all = try await catalog.libraryMedia(includeHidden: true)
    XCTAssertEqual(all.count, 1)
  }

  func testIncludeOffRemovesOnlyIndexedReasons() async throws {
    let catalog = try makeCatalog()
    let source = root(inclusion: .indexed)
    try await catalog.insertRoot(source)
    let id = try await media(catalog, root: source, path: "A.mkv")
    try await catalog.addReason(mediaID: id, reason: .indexed,
                                originID: source.id.uuidString)
    try await catalog.addReason(mediaID: id, reason: .history,
                                originID: "playbackHistory")

    try await catalog.removeReasons(originID: source.id.uuidString, reason: .indexed)
    let reasons = try await catalog.reasons(mediaID: id)
    XCTAssertEqual(reasons, [.history])
  }

  // MARK: - Play state

  func testStaleObservedStateDoesNotOverwriteNewerState() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let id = try await media(catalog, root: source, path: "A.mkv")

    let newer = MediaPlayState(mediaID: id, observedPosition: 80,
                               observedDuration: 100, completed: false,
                               manualWatchedOverride: nil,
                               lastManualActionAt: nil, lastManualActionKind: nil,
                               observedAt: Date(timeIntervalSince1970: 200), revision: 2)
    try await catalog.savePlayState(newer)

    var older = newer
    older.observedPosition = 10
    older.observedAt = Date(timeIntervalSince1970: 100)
    older.revision = 1
    try await catalog.savePlayState(older)

    let state = try await catalog.playState(mediaID: id)
    XCTAssertEqual(state?.observedPosition, 80)
  }

  func testMarkUnwatchedResetsPositionAndOverride() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let id = try await media(catalog, root: source, path: "A.mkv")
    try await catalog.replacePlayState(mediaID: id, state: MediaPlayState(
      mediaID: id, observedPosition: 100, observedDuration: 100,
      completed: true, manualWatchedOverride: nil,
      lastManualActionAt: nil, lastManualActionKind: nil,
      observedAt: Date(timeIntervalSince1970: 1000), revision: 1))

    try await catalog.markWatched(mediaID: id, watched: false)
    let state = try await catalog.playState(mediaID: id)
    XCTAssertEqual(state?.observedPosition, 0)
    XCTAssertNil(state?.manualWatchedOverride)
    XCTAssertEqual(state?.lastManualActionKind, .reset)
    let item = try await catalog.media(id: id)
    XCTAssertEqual(item?.isFinished, false)
  }

  func testManualWatchedAndReset() async throws {    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let id = try await media(catalog, root: source, path: "A.mkv")

    try await catalog.markWatched(mediaID: id, watched: true)
    let watched = try await catalog.playState(mediaID: id)
    XCTAssertEqual(watched?.manualWatchedOverride, true)

    try await catalog.resetUnwatched(mediaID: id)
    let state = try await catalog.playState(mediaID: id)
    XCTAssertNil(state?.manualWatchedOverride)
    XCTAssertEqual(state?.observedPosition, 0)
    XCTAssertEqual(state?.lastManualActionKind, .reset)
  }

  // MARK: - Collections and favorites

  func testCollectionLinkAndReasonStayInSync() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let id = try await media(catalog, root: source, path: "A.mkv")
    let collection = try await catalog.createCollection(name: "Weekend")

    try await catalog.addToCollection(collectionID: collection, mediaIDs: [id])
    let items = try await catalog.collectionMediaIDs(id: collection)
    XCTAssertEqual(items, [id])
    let reasons = try await catalog.reasons(mediaID: id)
    XCTAssertTrue(reasons.contains(.collection))

    try await catalog.removeFromCollection(collectionID: collection, mediaIDs: [id])
    let remaining = try await catalog.collectionMediaIDs(id: collection)
    XCTAssertTrue(remaining.isEmpty)
    let after = try await catalog.reasons(mediaID: id)
    XCTAssertFalse(after.contains(.collection))
    let library = try await catalog.libraryMedia()
    XCTAssertTrue(library.isEmpty)
  }

  func testRemovingOneCollectionKeepsAnotherReasonAndLink() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let id = try await media(catalog, root: source, path: "A.mkv")
    let first = try await catalog.createCollection(name: "First")
    let second = try await catalog.createCollection(name: "Second")

    try await catalog.addToCollection(collectionID: first, mediaIDs: [id])
    try await catalog.addToCollection(collectionID: second, mediaIDs: [id])
    try await catalog.removeFromCollection(collectionID: first, mediaIDs: [id])

    let reasons = try await catalog.reasons(mediaID: id)
    XCTAssertTrue(reasons.contains(.collection))
    let secondItems = try await catalog.collectionMediaIDs(id: second)
    XCTAssertEqual(secondItems, [id])
    let library = try await catalog.libraryMedia()
    XCTAssertEqual(library.count, 1)
  }

  func testDeleteCollectionRemovesOnlyItsReason() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let id = try await media(catalog, root: source, path: "A.mkv")
    let first = try await catalog.createCollection(name: "First")
    let second = try await catalog.createCollection(name: "Second")
    try await catalog.addToCollection(collectionID: first, mediaIDs: [id])
    try await catalog.addToCollection(collectionID: second, mediaIDs: [id])

    try await catalog.deleteCollection(id: first)
    let secondItems = try await catalog.collectionMediaIDs(id: second)
    XCTAssertEqual(secondItems, [id])
    let library = try await catalog.libraryMedia()
    XCTAssertEqual(library.count, 1)
  }

  func testFavoriteIsAMembershipReason() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let id = try await media(catalog, root: source, path: "A.mkv")

    try await catalog.setFavorite(mediaID: id, favorite: true)
    let reasons = try await catalog.reasons(mediaID: id)
    XCTAssertTrue(reasons.contains(.favorite))
    try await catalog.setFavorite(mediaID: id, favorite: false)
    let library = try await catalog.libraryMedia()
    XCTAssertTrue(library.isEmpty)
  }

  // MARK: - Merge and redirect

  func testMergePreservesReasonsAliasesAndNewestPlayState() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let older = try await media(catalog, root: source, path: "Old.mkv")
    let newer = try await media(catalog, root: source, path: "New.mkv")

    try await catalog.addReason(mediaID: older, reason: .explicit, originID: "explicit")
    try await catalog.addReason(mediaID: newer, reason: .favorite, originID: "favorite")
    let collection = try await catalog.createCollection(name: "C")
    try await catalog.addToCollection(collectionID: collection, mediaIDs: [newer])
    _ = try await catalog.addAlias(kind: "filePath", value: "/tmp/new.mkv",
                                   mediaID: newer, namespace: "ns")
    try await catalog.savePlayState(MediaPlayState(
      mediaID: newer, observedPosition: 70, observedDuration: 100, completed: false,
      manualWatchedOverride: nil, lastManualActionAt: nil, lastManualActionKind: nil,
      observedAt: Date(), revision: 0))

    let survivor = try await catalog.mergeMedia(retiredID: newer, survivingID: older,
                                                operationID: "test")
    XCTAssertEqual(survivor, older)
    let redirect = try await catalog.resolveRedirect(id: newer)
    XCTAssertEqual(redirect, older)
    let reasons = try await catalog.reasons(mediaID: older)
    XCTAssertEqual(reasons, [.explicit, .favorite, .collection, .indexed])
    let collectionItems = try await catalog.collectionMediaIDs(id: collection)
    XCTAssertEqual(collectionItems, [older])
    let alias = try await catalog.resolveAlias(kind: "filePath", value: "/tmp/new.mkv")
    XCTAssertEqual(alias, older)
    let state = try await catalog.playState(mediaID: older)
    XCTAssertEqual(state?.observedPosition, 70)
    let retired = try await catalog.media(id: newer)
    XCTAssertNil(retired)
  }

  // MARK: - Search

  func testSearchFoldsCaseAndEscapesWildcards() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let first = try await media(catalog, root: source, path: "Movies/Café 100%.mkv")
    let second = try await media(catalog, root: source, path: "Movies/Other.mkv")
    try await catalog.addReason(mediaID: first, reason: .explicit, originID: "explicit")
    try await catalog.addReason(mediaID: second, reason: .explicit, originID: "explicit")

    let folded = try await catalog.search(term: "cafe 100%", scope: .allLibrary)
    XCTAssertEqual(folded.map(\.id), [first])

    let wildcard = try await catalog.search(term: "%", scope: .allLibrary)
    XCTAssertEqual(wildcard.map(\.id), [first])

    let none = try await catalog.search(term: "_", scope: .allLibrary)
    XCTAssertTrue(none.isEmpty)
  }

  func testBrowseOnlyRowsAreExcludedFromLibrarySearch() async throws {
    let catalog = try makeCatalog()
    let source = root(inclusion: .browseOnly)
    try await catalog.insertRoot(source)
    _ = try await media(catalog, root: source, path: "A.mkv")

    let results = try await catalog.search(term: "A", scope: .allLibrary)
    XCTAssertTrue(results.isEmpty)
  }

  func testTerminationFlushReachesTheSerialWriter() throws {
    let catalog = try makeCatalog()
    XCTAssertTrue(catalog.flushForTermination(timeout: 1))
  }

  func testIntegrityAndForeignKeysAreClean() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    _ = try await media(catalog, root: source, path: "A.mkv")
    let result = try await catalog.integrityCheck()
    XCTAssertEqual(result.integrity, "ok")
    XCTAssertEqual(result.foreignKeyViolations, 0)
  }

  func testUnsupportedNewerSchemaIsRefused() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-schema-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("catalog.sqlite")

    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(handle, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
    sqlite3_close(handle)

    XCTAssertThrowsError(try MediaCatalog(databaseURL: url))
  }

  // MARK: - Eviction
  func testEvictionKeepsNewestVisitedRowsAndMarksSnapshotsIncomplete() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let oldDirectory = try await catalog.upsertDirectory(
      rootID: source.id, parentID: nil, relativePath: "Old",
      comparison: source.comparison)
    let newDirectory = try await catalog.upsertDirectory(
      rootID: source.id, parentID: nil, relativePath: "New",
      comparison: source.comparison)
    try await catalog.recordDirectorySnapshot(
      directoryID: oldDirectory.id, observedAt: Date(timeIntervalSince1970: 100),
      complete: true, generation: 1)
    try await catalog.recordDirectorySnapshot(
      directoryID: newDirectory.id, observedAt: Date(timeIntervalSince1970: 200),
      complete: true, generation: 2)

    for (directory, name) in [(oldDirectory, "Old1.mkv"), (oldDirectory, "Old2.mkv"),
                              (newDirectory, "New1.mkv"), (newDirectory, "New2.mkv")] {
      _ = try await catalog.upsertMedia(
        rootID: source.id, directoryID: directory.id, relativePath: name,
        comparisonKey: source.comparison.key(for: name), name: name,
        size: nil, modifiedAt: nil, duration: nil, presence: .present)
    }

    try await catalog.evictVisitedRows(rootID: source.id, limit: 2)
    let remaining = try await catalog.directorySnapshot(directoryID: newDirectory.id)
    XCTAssertEqual(remaining?.items.count, 2)
    let evicted = try await catalog.directorySnapshot(directoryID: oldDirectory.id)
    XCTAssertEqual(evicted?.items.count, 0)
    XCTAssertEqual(evicted?.complete, false)

    // A played row is never eligible, even without a membership reason.
    let played = try await catalog.upsertMedia(
      rootID: source.id, directoryID: oldDirectory.id, relativePath: "Played.mkv",
      comparisonKey: source.comparison.key(for: "Played.mkv"), name: "Played.mkv",
      size: nil, modifiedAt: nil, duration: 100, presence: .present)
    try await catalog.savePlayState(MediaPlayState(
      mediaID: played, observedPosition: 50, observedDuration: 100,
      completed: false, manualWatchedOverride: nil,
      lastManualActionAt: nil, lastManualActionKind: nil,
      observedAt: Date(), revision: 1))
    try await catalog.evictVisitedRows(rootID: source.id, limit: 1)
    let survived = try await catalog.media(id: played)
    XCTAssertNotNil(survived)
  }

  // MARK: - Absence
  func testAbsenceReviewAppliesOnlyWhileCurrent() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let id = try await media(catalog, root: source, path: "A.mkv")
    let directory = try await catalog.upsertDirectory(
      rootID: source.id, parentID: nil, relativePath: "",
      comparison: source.comparison)
    try await catalog.recordDirectorySnapshot(directoryID: directory.id, observedAt: Date(),
                                              complete: true, generation: 10)
    let review = AbsenceReview(token: UUID(), rootID: source.id, generation: 10,
                               directoryIDs: [directory.id], missingMediaIDs: [id],
                               reason: "massAbsence", missingCount: 1, knownCount: 1,
                               createdAt: Date())
    let current = try await catalog.absenceReviewIsCurrent(review)
    XCTAssertTrue(current)

    // A newer visit to the directory invalidates the review.
    try await catalog.recordDirectorySnapshot(directoryID: directory.id, observedAt: Date(),
                                              complete: true, generation: 11)
    let stillCurrent = try await catalog.absenceReviewIsCurrent(review)
    XCTAssertFalse(stillCurrent)
    do {
      try await catalog.applyAbsenceReview(review)
      XCTFail("A stale review must not apply")
    } catch {
      XCTAssertEqual(error as? MediaSourceError, .cancelled)
    }
    let media = try await catalog.media(id: id)
    XCTAssertEqual(media?.presence, .present)
  }

  // MARK: - Aliases, merge and absence
  func testReplaceRetiredAliasReassignsOnlyForTheNewOwner() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let first = try await media(catalog, root: source, path: "A.mkv")
    let second = try await media(catalog, root: source, path: "B.mkv")
    _ = try await catalog.addAlias(kind: "filePath", value: "/tmp/A.mkv",
                                   mediaID: first, namespace: "ns")
    try await catalog.retireAlias(kind: "filePath", value: "/tmp/A.mkv")

    // A retired locator is not a live collision: without replaceRetired the
    // alias stays with its former owner and stays retired.
    let collision = try await catalog.addAlias(
      kind: "filePath", value: "/tmp/A.mkv", mediaID: second, namespace: "ns")
    XCTAssertEqual(collision, first)
    let stillRetired = try await catalog.resolveAlias(kind: "filePath", value: "/tmp/A.mkv")
    XCTAssertNil(stillRetired)

    let replaced = try await catalog.addAlias(
      kind: "filePath", value: "/tmp/A.mkv", mediaID: second, namespace: "ns",
      replaceRetired: true)
    XCTAssertNil(replaced)
    let resolved = try await catalog.resolveAlias(kind: "filePath", value: "/tmp/A.mkv")
    XCTAssertEqual(resolved, second)
  }

  func testMergeCarriesTheHiddenState() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let visible = try await media(catalog, root: source, path: "A.mkv")
    let hidden = try await media(catalog, root: source, path: "B.mkv")
    try await catalog.setHidden(mediaID: hidden, hidden: true)

    _ = try await catalog.mergeMedia(retiredID: hidden, survivingID: visible,
                                     operationID: "test")
    let merged = try await catalog.media(id: visible)
    XCTAssertEqual(merged?.isHidden, true)
  }

  func testAbsenceIsSkippedWhenTheDirectoryWasObservedLater() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let directory = try await catalog.upsertDirectory(
      rootID: source.id, parentID: nil, relativePath: "",
      comparison: source.comparison)
    let id = try await catalog.upsertMedia(
      rootID: source.id, directoryID: directory.id, relativePath: "A.mkv",
      comparisonKey: "a.mkv", name: "A.mkv", size: 1, modifiedAt: nil,
      duration: nil, presence: .present)
    let observedAt = Date()
    try await catalog.recordDirectorySnapshot(directoryID: directory.id,
                                              observedAt: observedAt, complete: true,
                                              generation: 20)

    // Generation 10's listing is older than the directory's observation, so it
    // is not evidence that the file is gone.
    try await catalog.applyAbsence(mediaIDs: [id], generation: 10,
                                   observedAt: observedAt.addingTimeInterval(-60))
    let present = try await catalog.media(id: id)
    XCTAssertEqual(present?.presence, .present)

    // A partial visit advances only the listing time. A listing older than it
    // is still not evidence.
    try await catalog.recordDirectorySnapshot(
      directoryID: directory.id, observedAt: observedAt.addingTimeInterval(30),
      complete: false, generation: 25)
    try await catalog.applyAbsence(mediaIDs: [id], generation: 20,
                                   observedAt: observedAt.addingTimeInterval(10))
    let stillPresent = try await catalog.media(id: id)
    XCTAssertEqual(stillPresent?.presence, .present)

    try await catalog.applyAbsence(mediaIDs: [id], generation: 20,
                                   observedAt: observedAt.addingTimeInterval(60))
    let missing = try await catalog.media(id: id)
    XCTAssertEqual(missing?.presence, .missing)
  }

  func testIndexedMembershipReconciliationReadsTheStoredRoot() async throws {
    let catalog = try makeCatalog()
    let source = root(inclusion: .indexed)
    try await catalog.insertRoot(source)
    let id = try await media(catalog, root: source, path: "A.mkv")

    try await catalog.reconcileIndexedReasons(rootID: source.id)
    var reasons = try await catalog.reasons(mediaID: id)
    XCTAssertTrue(reasons.contains(.indexed))

    try await catalog.setRootInclusion(id: source.id, inclusion: .browseOnly)
    try await catalog.reconcileIndexedReasons(rootID: source.id)
    reasons = try await catalog.reasons(mediaID: id)
    XCTAssertFalse(reasons.contains(.indexed))

    try await catalog.setRootInclusion(id: source.id, inclusion: .indexed)
    try await catalog.detachRoot(id: source.id)
    try await catalog.reconcileIndexedReasons(rootID: source.id)
    reasons = try await catalog.reasons(mediaID: id)
    XCTAssertFalse(reasons.contains(.indexed))

    try await catalog.restoreRoot(id: source.id)
    try await catalog.reconcileIndexedReasons(rootID: source.id)
    reasons = try await catalog.reasons(mediaID: id)
    XCTAssertTrue(reasons.contains(.indexed))
  }

  func testIndexedReasonIsNotAddedToARowMovedToAnotherRoot() async throws {
    let catalog = try makeCatalog()
    let first = root(namespace: "volume-1")
    let second = root(namespace: "volume-1")
    try await catalog.insertRoot(first)
    try await catalog.insertRoot(second)
    let id = try await media(catalog, root: second, path: "A.mkv")

    try await catalog.addIndexedReasonIfCurrent(mediaID: id, rootID: first.id)
    let reasons = try await catalog.reasons(mediaID: id)
    XCTAssertFalse(reasons.contains(.indexed))
  }

  func testDirectoryBatchCommitIsOneTransaction() async throws {
    let catalog = try makeCatalog()
    let source = root(inclusion: .indexed)
    try await catalog.insertRoot(source)
    let directory = try await catalog.upsertDirectory(
      rootID: source.id, parentID: nil, relativePath: "",
      comparison: source.comparison)
    let rootURL = URL(fileURLWithPath: "/tmp/uniplayer-batch")
    let fileURL = rootURL.appendingPathComponent("A.mkv")
    let subURL = rootURL.appendingPathComponent("Sub", isDirectory: true)
    let entry = DirectoryEntry(
      url: fileURL, name: "A.mkv", isDirectory: false, isSymbolicLink: false,
      isPackage: false, size: 10, modified: Date())

    let counts = try await catalog.commitDirectoryObservation(
      root: source, directoryID: directory.id,
      files: [(fileURL, entry, "A.mkv")],
      directories: [(subURL, "Sub")])
    XCTAssertEqual(counts.discovered, 1)
    let rows = try await catalog.libraryMedia()
    XCTAssertEqual(rows.count, 1)
    XCTAssertTrue(rows[0].reasons.contains(.indexed))
    XCTAssertEqual(rows[0].relativePath, "A.mkv")
    let alias = try await catalog.resolveAlias(kind: "filePath", value: fileURL.path)
    XCTAssertEqual(alias, rows[0].id)
    let sub = try await catalog.directory(rootID: source.id, relativePath: "Sub",
                                          comparison: source.comparison)
    XCTAssertNotNil(sub)
  }

  func testPresenceBatchResolvesOnlyLiveAliases() async throws {
    let catalog = try makeCatalog()
    let source = root()
    try await catalog.insertRoot(source)
    let id = try await media(catalog, root: source, path: "A.mkv")
    _ = try await catalog.addAlias(kind: "filePath", value: "/tmp/A.mkv",
                                   mediaID: id, namespace: "ns")
    try await catalog.applyAbsence(mediaIDs: [id], generation: 1,
                                   observedAt: Date().addingTimeInterval(60))
    var presence = try await catalog.presence(
      forAliases: [("filePath", "/tmp/A.mkv")])
    XCTAssertEqual(presence["/tmp/A.mkv"], .missing)

    try await catalog.retireAlias(kind: "filePath", value: "/tmp/A.mkv")
    presence = try await catalog.presence(forAliases: [("filePath", "/tmp/A.mkv")])
    XCTAssertNil(presence["/tmp/A.mkv"])
  }

  // MARK: - Lifecycle
  func testClosedCatalogRejectsFurtherWork() async throws {
    let catalog = try makeCatalog()
    catalog.close()
    do {
      _ = try await catalog.roots()
      XCTFail("A closed catalog must reject work instead of writing quietly")
    } catch {
      guard case MediaSourceError.database = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }
}
