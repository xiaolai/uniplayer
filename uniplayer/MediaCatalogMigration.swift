//
//  MediaCatalogMigration.swift
//  uniplayer
//
//  One idempotent import of the stores the library used before the catalog:
//  playback history, recent documents and the hidden/watched defaults. The
//  legacy files are copied to a timestamped backup first and never rewritten.
//

import Foundation

struct LegacyLibraryData {
  var history: [PlaybackHistorySnapshot]
  var recentURLs: [URL]
  var hiddenIDs: Set<String>
  var watched: [String: Bool]
}

struct MigrationReport: Equatable {
  var historyImported: Int = 0
  var recentImported: Int = 0
  var hiddenApplied: Int = 0
  var watchedApplied: Int = 0
  var unresolvedAliases: [String] = []
  var backupURL: URL?
}

enum MediaCatalogMigration {
  static let stateKey = "legacy.import.v1"

  static func run(catalog: MediaCatalog, data: LegacyLibraryData,
                  historyFileURL: URL?, backupDirectory: URL,
                  executor: SourceIOExecutor = .shared) async throws -> MigrationReport {
    var report = MigrationReport()
    report.backupURL = try await executor.perform(
      lane: .local, volumeKey: "catalog-backup") {
        try backup(data: data, historyFileURL: historyFileURL,
                   directory: backupDirectory)
      }

    // History first: a history entry knows duration and progress, a recent
    // document does not. Importing in this order preserves the richer row.
    for entry in data.history {
      let aliasKind = entry.url.isFileURL ? "filePath" : "url"
      let aliasValue = entry.url.isFileURL
        ? entry.url.standardizedFileURL.path
        : entry.url.absoluteString
      let mediaID = try await mediaID(for: entry.url, aliasKind: aliasKind,
                                      aliasValue: aliasValue, name: entry.name,
                                      duration: entry.duration,
                                      added: entry.addedDate,
                                      catalog: catalog, executor: executor)
      try await catalog.addReason(mediaID: mediaID, reason: .history,
                                  originID: "playbackHistory")
      let duration = entry.duration
      let position = entry.progress ?? 0
      if duration > 0 || position > 0 {
        let observedAt = entry.addedDate
        let completed = duration > 0 && position / duration >= 0.97
        try await catalog.savePlayState(MediaPlayState(
          mediaID: mediaID,
          observedPosition: position,
          observedDuration: duration > 0 ? duration : nil,
          completed: completed,
          manualWatchedOverride: nil,
          lastManualActionAt: nil,
          lastManualActionKind: nil,
          observedAt: observedAt,
          revision: 0))
      }
      report.historyImported += 1
    }

    for url in data.recentURLs {
      let aliasKind = url.isFileURL ? "filePath" : "url"
      let aliasValue = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
      let mediaID = try await mediaID(for: url, aliasKind: aliasKind,
                                      aliasValue: aliasValue,
                                      name: url.lastPathComponent,
                                      duration: nil,
                                      added: .distantPast,
                                      catalog: catalog, executor: executor)
      try await catalog.addReason(mediaID: mediaID, reason: .history,
                                  originID: "legacyRecent")
      report.recentImported += 1
    }

    let defaultsDone = (try? await catalog.migrationCompleted(
      "legacy.defaults.v1")) == true
    if !defaultsDone {
      for identifier in data.hiddenIDs {
        var resolved = try await catalog.resolveAlias(kind: "filePath", value: identifier)
        if resolved == nil {
          resolved = try await catalog.resolveAlias(kind: "url", value: identifier)
        }
        guard let mediaID = resolved else {
          report.unresolvedAliases.append(identifier)
          continue
        }
        try await catalog.setHidden(mediaID: mediaID, hidden: true)
        report.hiddenApplied += 1
      }

      for (identifier, watched) in data.watched {
        var resolved = try await catalog.resolveAlias(kind: "filePath", value: identifier)
        if resolved == nil {
          resolved = try await catalog.resolveAlias(kind: "url", value: identifier)
        }
        guard let mediaID = resolved else {
          report.unresolvedAliases.append(identifier)
          continue
        }
        if watched {
          try await catalog.markWatched(mediaID: mediaID, watched: true)
        } else {
          try await catalog.resetUnwatched(mediaID: mediaID)
        }
        report.watchedApplied += 1
      }
      try await catalog.setMigrationCompleted("legacy.defaults.v1")
    }

    try await catalog.setMigrationCompleted(stateKey)
    return report
  }

  private static func mediaID(for url: URL, aliasKind: String, aliasValue: String,
                              name: String, duration: Double?, added: Date,
                              catalog: MediaCatalog,
                              executor: SourceIOExecutor) async throws -> UUID {
    let exists: Bool
    if url.isFileURL {
      let path = url.standardizedFileURL.path
      exists = try await executor.perform(
        lane: SourceIOLane.forPath(path),
        volumeKey: "legacy:\(url.deletingLastPathComponent().path)") {
          FileManager.default.fileExists(atPath: path)
        }
    } else {
      exists = true
    }
    return try await catalog.importLegacyMedia(
      aliasKind: aliasKind, aliasValue: aliasValue, name: name,
      duration: duration, added: added,
      presence: exists ? .present : .unknown)
  }

  // MARK: - Backup

  private static func backup(data: LegacyLibraryData, historyFileURL: URL?,
                             directory: URL) throws -> URL? {
    guard !data.history.isEmpty || !data.recentURLs.isEmpty
      || !data.hiddenIDs.isEmpty || !data.watched.isEmpty else {
      return nil
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    var folder = directory.appendingPathComponent("legacy-\(formatter.string(from: Date()))",
                                                  isDirectory: true)
    if FileManager.default.fileExists(atPath: folder.path) {
      folder = directory.appendingPathComponent("legacy-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))",
                                                isDirectory: true)
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let historyFileURL, FileManager.default.fileExists(atPath: historyFileURL.path) {
      try FileManager.default.copyItem(
        at: historyFileURL,
        to: folder.appendingPathComponent("playback-history.plist"))
    }
    let defaults: [String: Any] = [
      "hidden": Array(data.hiddenIDs).sorted(),
      "watched": data.watched,
    ]
    let data = try JSONSerialization.data(withJSONObject: defaults,
                                          options: [.prettyPrinted, .sortedKeys])
    try data.write(to: folder.appendingPathComponent("legacy-defaults.json"),
                   options: [.atomic])
    return folder
  }
}
