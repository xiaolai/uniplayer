//
//  HistoryController.swift
//  uniplayer
//
//  Created by lhc on 25/4/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

class HistoryController: NSObject {

  static let shared = HistoryController(plistFileURL: Utility.playbackHistoryURL)

#if DEBUG
  /// As logging of all history entries can produce a huge number of log messages this feature is only included in debug builds and
  /// must be enabled by setting this property to `true` when you need investigate history file contents.
  private static let logAllHistoryEntries = false
#endif

  /// Cached copy of the playback history stored in the history file.
  ///
  /// This is accessed by both the main thread and a background thread and must be referenced under a lock.
  @Atomic var history: [PlaybackHistory] = []

  /// Number of tasks currently in the queue.
  @Atomic var tasksOutstanding = 0

  private let plistURL: URL
  private let queue = DispatchQueue(label: "UniPlayerHistoryController", qos: .background)

  init(plistFileURL: URL) {
    self.plistURL = plistFileURL
    super.init()
    read()
  }

  private func read() {
    // Avoid logging a scary error if the file does not exist.
    guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
    do {
      MemoryUsage.shared.logUsage("before reading history")
      let data = try Data(contentsOf: plistURL)
      let object = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, PlaybackHistory.self],
                                                          from: data)
      guard let history = object as? [PlaybackHistory] else {
        // Secure coding should ensure that this never occurs.
        log("Unable to convert object read from playback history file to [PlaybackHistory]", level: .error)
        return
      }
      self.history = history
      log("Read \(history.count) playback history entries")
      MemoryUsage.shared.logUsage("after reading history")

      // As logging of all history entries can produce a huge number of log messages this feature is
      // only included in debug builds.
#if DEBUG
      // UniPlayer must be built with the property logAllHistoryEntries set to true when you want the
      // history file contents to be logged when it is read.
      guard HistoryController.logAllHistoryEntries, !history.isEmpty,
            Logger.isEmitting(.verbose) else { return }
      log("Playback history:", level: .verbose)
      var index = 0
      for entry in history {
        log("History[\(index)] \(String(describing: entry))", level: .verbose)
        index += 1
      }
#endif
    } catch {
      log("Failed to read playback history file \(plistURL.path): \(error)", level: .error)
    }
  }

  private func save() {
    do {
      try $history.withLock { history in
        log("Saving \(history.count) playback history entries")
        let data = try NSKeyedArchiver.archivedData(withRootObject: history, requiringSecureCoding: true)
        try data.write(to: plistURL, options: [.atomic])
        log("Saved \(history.count) playback history entries")
      }
      NotificationCenter.default.post(Notification(name: .iinaHistoryUpdated))
    } catch {
      log("Failed to save playback history to file \(plistURL.path): \(error)", level: .error)
    }
  }

  /// Add an entry to playback history.
  /// - Note: The entry is added asynchronously by a background thread.
  /// - Parameters:
  ///   - url: URL of the media being played.
  ///   - duration: Total duration of the media.
  ///   - title: Title of the media (if available).
  ///   - ignorePath: When `true`, only the URL's filename will be used for the sum if the URL does not contain a scheme.
  func add(_ url: URL, duration: Double, title: String?, _ ignorePath: Bool) {
    guard Preference.bool(for: .recordPlaybackHistory) else { return }
    $tasksOutstanding.withLock { $0 += 1 }
    queue.async { [self] in
      let mpvMd5 = Utility.mpvWatchLaterMd5(url, ignorePath)
      $history.withLock { history in
        if let existingItem = history.first(where: { $0.mpvMd5 == mpvMd5 }),
           let index = history.firstIndex(of: existingItem) {
          history.remove(at: index)
        }
        let entry = PlaybackHistory(url: url, duration: duration, title: title, mpvMd5: mpvMd5)
        history.insert(entry, at: 0)
        log("Adding to history: \(String(describing: entry))", level: .verbose)
      }
      save()
      $tasksOutstanding.withLock { tasksOutstanding in
        tasksOutstanding -= 1
        if tasksOutstanding != 0 {
          // The history controller must be able to finish saving playback history before UniPlayer
          // terminates or history will be lost. If termination times out before saving of playback
          // history has finished then history will be lost. If that happens then the qos of the
          // history batch queue will need to be raised to allow the history controller to keep up
          // with requests to save history.
          log("History tasks outstanding: \(tasksOutstanding)")
        }
      }
      NotificationCenter.default.post(Notification(name: .iinaHistoryTaskFinished))
    }
  }

  /// Updates the remembered location without deleting a file or losing its progress.
  /// An immutable copy for readers that leave the main thread. The stored
  /// entries are mutable and owned by the writer.
  func historySnapshot() -> [PlaybackHistorySnapshot] {
    $history.withLock { $0.map(\.snapshot) }
  }

  func relocate(from oldURL: URL, to newURL: URL) {
    var movedMd5: (String, String)?
    $history.withLock { history in
      let newMd5 = Utility.mpvWatchLaterMd5(newURL, false)
      if let entry = history.first(where: { $0.url == oldURL }) {
        let oldMd5 = entry.mpvMd5
        entry.url = newURL
        entry.name = newURL.lastPathComponent
        entry.mpvMd5 = newMd5
        if oldMd5 != newMd5 { movedMd5 = (oldMd5, newMd5) }
      } else {
        history.insert(PlaybackHistory(url: newURL, duration: 0, title: nil,
                                      mpvMd5: newMd5), at: 0)
      }
    }
    if let (oldMd5, newMd5) = movedMd5 {
      Self.moveWatchLater(from: oldMd5, to: newMd5)
    }
    save()
  }

  /// mpv names watch-later state by the URL's md5, so a relocated file needs
  /// its state moved; otherwise the next legacy open resumes nothing.
  private static func moveWatchLater(from oldMd5: String, to newMd5: String) {
    let directory = Utility.watchLaterURL
    let oldFile = directory.appendingPathComponent(oldMd5)
    let newFile = directory.appendingPathComponent(newMd5)
    guard FileManager.default.fileExists(atPath: oldFile.path) else { return }
    try? FileManager.default.removeItem(at: newFile)
    try? FileManager.default.moveItem(at: oldFile, to: newFile)
  }

  func remove(_ entries: [PlaybackHistory]) {
    $history.withLock { history in
      log("Removing \(entries.count) playback history entries")
      history = history.filter { !entries.contains($0) }
    }
    save()
  }

  func removeAll() {
    $tasksOutstanding.withLock { $0 += 1 }
    // Serialize the clear behind any queued additions so an older add cannot
    // resurrect history after the person cleared it.
    queue.async { [self] in
      $history.withLock { history in
        log("Removing all playback history entries")
        history = []
      }
      save()
      $tasksOutstanding.withLock { tasksOutstanding in
        tasksOutstanding -= 1
      }
      NotificationCenter.default.post(Notification(name: .iinaHistoryTaskFinished))
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .iinaPlaybackHistoryCleared, object: nil)
        NotificationCenter.default.post(name: .libraryShouldReload, object: nil)
      }
    }
  }

  /// Update the in-memory progress for the current session so Continue
  /// Watching does not have to wait for a restart.
  func updateProgress(for url: URL, progress: VideoTime, duration: VideoTime) {
    let mpvMd5 = Utility.mpvWatchLaterMd5(url, false)
    $history.withLock { history in
      guard let entry = history.first(where: { $0.url == url || $0.mpvMd5 == mpvMd5 }) else { return }
      entry.mpvProgress = progress
      if duration.second > 0 {
        entry.duration = duration
      }
    }
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .libraryShouldReload, object: nil)
    }
  }

  private func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: Logger.Sub.history)
  }
}

extension Logger.Sub {
  static let history = Logger.makeSubsystem("history", ["clock"])
}
