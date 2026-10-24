//
//  MediaMigrationTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

final class MediaMigrationTests: XCTestCase {

  private var root: URL!
  private var backup: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-migration-\(UUID().uuidString)", isDirectory: true)
    backup = root.appendingPathComponent("Backups", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testImportsHistoryRecentHiddenAndWatched() async throws {
    let catalog = try MediaCatalog.inMemory()
    let fileURL = root.appendingPathComponent("Movie.mkv")
    try Data("video".utf8).write(to: fileURL)
    let networkURL = URL(string: "https://example.com/live.m3u8")!
    let recentURL = root.appendingPathComponent("Recent.mkv")

    let history = PlaybackHistorySnapshot(
      url: fileURL, name: fileURL.lastPathComponent, played: true,
      addedDate: Date(), duration: 100, progress: 50, title: "Movie")
    let network = PlaybackHistorySnapshot(
      url: networkURL, name: networkURL.lastPathComponent, played: true,
      addedDate: Date(), duration: 0, progress: nil, title: "Live")
    let historyFile = root.appendingPathComponent("history.plist")
    try Data("legacy".utf8).write(to: historyFile)

    let data = LegacyLibraryData(
      history: [history, network],
      recentURLs: [recentURL],
      hiddenIDs: [fileURL.path, "/missing/path.mkv"],
      watched: [recentURL.path: true])

    let report = try await MediaCatalogMigration.run(
      catalog: catalog, data: data, historyFileURL: historyFile,
      backupDirectory: backup)

    XCTAssertEqual(report.historyImported, 2)
    XCTAssertEqual(report.recentImported, 1)
    XCTAssertEqual(report.hiddenApplied, 1)
    XCTAssertEqual(report.watchedApplied, 1)
    XCTAssertEqual(report.unresolvedAliases, ["/missing/path.mkv"])
    XCTAssertNotNil(report.backupURL)
    if let backupURL = report.backupURL {
      XCTAssertTrue(FileManager.default.fileExists(
        atPath: backupURL.appendingPathComponent("legacy-defaults.json").path))
    }

    let library = try await catalog.libraryMedia(includeHidden: true)
    XCTAssertEqual(library.count, 3)
    let movie = try XCTUnwrap(library.first { $0.name == "Movie.mkv" })
    XCTAssertTrue(movie.reasons.contains(.history))
    XCTAssertTrue(movie.isHidden)
    XCTAssertEqual(movie.playState?.observedPosition, 50)
    XCTAssertEqual(movie.playState?.observedDuration, 100)

    let recent = try XCTUnwrap(library.first { $0.name == "Recent.mkv" })
    XCTAssertEqual(recent.playState?.manualWatchedOverride, true)

    let networkItem = try XCTUnwrap(library.first { $0.name == "live.m3u8" })
    XCTAssertEqual(networkItem.rootID, nil)
    XCTAssertEqual(networkItem.url?.absoluteString, networkURL.absoluteString)
    XCTAssertTrue(networkItem.reasons.contains(.history))

    let completed = try await catalog.migrationCompleted(MediaCatalogMigration.stateKey)
    XCTAssertTrue(completed)
  }

  func testImportIsIdempotentAndKeepsIDs() async throws {
    let catalog = try MediaCatalog.inMemory()
    let fileURL = root.appendingPathComponent("Movie.mkv")
    try Data("video".utf8).write(to: fileURL)
    let history = PlaybackHistorySnapshot(
      url: fileURL, name: fileURL.lastPathComponent, played: true,
      addedDate: Date(), duration: 100, progress: nil, title: "Movie")
    let data = LegacyLibraryData(history: [history], recentURLs: [fileURL],
                                 hiddenIDs: [], watched: [:])

    _ = try await MediaCatalogMigration.run(
      catalog: catalog, data: data, historyFileURL: nil, backupDirectory: backup)
    let first = try await catalog.libraryMedia(includeHidden: true).map(\.id)

    _ = try await MediaCatalogMigration.run(
      catalog: catalog, data: data, historyFileURL: nil, backupDirectory: backup)
    let second = try await catalog.libraryMedia(includeHidden: true).map(\.id)

    XCTAssertEqual(first, second)
    XCTAssertEqual(second.count, 1)
  }

  func testLegacyUnwatchedFlagsBecomeOneTimeResets() async throws {
    let catalog = try MediaCatalog.inMemory()
    let fileURL = root.appendingPathComponent("Finished.mkv")
    try Data("video".utf8).write(to: fileURL)
    let history = PlaybackHistorySnapshot(
      url: fileURL, name: fileURL.lastPathComponent, played: true,
      addedDate: Date(), duration: 100, progress: 100, title: "Finished")
    _ = try await MediaCatalogMigration.run(
      catalog: catalog,
      data: LegacyLibraryData(history: [history], recentURLs: [],
                              hiddenIDs: [], watched: [fileURL.path: false]),
      historyFileURL: nil, backupDirectory: backup)

    let library = try await catalog.libraryMedia()
    let item = try XCTUnwrap(library.first)
    XCTAssertEqual(item.playState?.observedPosition, 0)
    XCTAssertNil(item.playState?.manualWatchedOverride)
    XCTAssertEqual(item.playState?.lastManualActionKind, .reset)
    XCTAssertFalse(item.isFinished)
  }

  func testClearingHistoryOriginKeepsRecentOrigin() async throws {
    let catalog = try MediaCatalog.inMemory()
    let fileURL = root.appendingPathComponent("Movie.mkv")
    try Data("video".utf8).write(to: fileURL)
    let history = PlaybackHistorySnapshot(
      url: fileURL, name: fileURL.lastPathComponent, played: true,
      addedDate: Date(), duration: 100, progress: nil, title: "Movie")
    _ = try await MediaCatalogMigration.run(
      catalog: catalog,
      data: LegacyLibraryData(history: [history], recentURLs: [fileURL],
                              hiddenIDs: [], watched: [:]),
      historyFileURL: nil, backupDirectory: backup)

    let library = try await catalog.libraryMedia()
    let id = try XCTUnwrap(library.first?.id)
    try await catalog.removeReasons(originID: "playbackHistory")
    let afterHistory = try await catalog.reasons(mediaID: id)
    XCTAssertTrue(afterHistory.contains(.history))

    try await catalog.removeReasons(originID: "legacyRecent")
    let remaining = try await catalog.libraryMedia()
    XCTAssertTrue(remaining.isEmpty)
  }
}
