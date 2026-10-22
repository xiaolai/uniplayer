//
//  LibraryModel.swift
//  uniplayer
//
//  The library's data: what has been played, what is remembered, and what the
//  player can legitimately show without scraping anything. Read-only against the
//  existing history and recent-documents stores; opening a file goes straight
//  back to PlayerCore.
//

import AppKit
import AVFoundation
import Combine
import QuickLookThumbnailing

// MARK: - Item

struct LibraryItem: Identifiable, Hashable {
  let url: URL
  let title: String
  let subtitle: String
  let metadata: LibraryMetadata
  let duration: Double
  let progress: Double
  let added: Date
  let isNetwork: Bool

  var id: String {
    url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
  }

  var playedSeconds: Double {
    guard duration > 0 else { return 0 }
    return min(max(progress, 0), 1) * duration
  }

  var isFinished: Bool {
    progress >= 0.97
  }

  var isResumable: Bool {
    progress > 0 && !isFinished
  }

  var durationText: String {
    VideoTime(duration).stringRepresentation
  }

  var progressText: String {
    guard duration > 0 else { return "" }
    return "\(VideoTime(playedSeconds).stringRepresentation) / \(durationText)"
  }
}

// MARK: - Model

@MainActor
final class LibraryModel: ObservableObject {

  @Published private(set) var continueWatching: [LibraryItem] = []
  @Published private(set) var recentlyAdded: [LibraryItem] = []
  @Published private(set) var allItems: [LibraryItem] = []
  @Published private(set) var hero: LibraryItem?
  @Published private(set) var hasLoaded = false
  @Published var query = ""

  private let openHandler: (URL) -> Void
  private var observers: [NSObjectProtocol] = []

  init(open: @escaping (URL) -> Void) {
    self.openHandler = open
    reload()

    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .iinaHistoryUpdated, object: nil, queue: .main) { [weak self] _ in
      self?.reload()
    })
    observers.append(center.addObserver(forName: .libraryShouldReload, object: nil, queue: .main) { [weak self] _ in
      self?.reload()
    })
    observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.reload()
    })
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  func open(_ item: LibraryItem) {
    openHandler(item.url)
  }

  func openFilePanel() {
    AppDelegate.shared.openFile(NSApp)
  }

  var searchResults: [LibraryItem] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return [] }
    return allItems.filter {
      $0.title.localizedCaseInsensitiveContains(term) ||
      $0.subtitle.localizedCaseInsensitiveContains(term)
    }
  }

  func reload() {
    let history = HistoryController.shared.history
    var items: [String: LibraryItem] = [:]

    func insert(_ item: LibraryItem) {
      if let existing = items[item.id] {
        // A history entry knows the progress a recent-document entry does not.
        if existing.progress == 0 && item.progress > 0 {
          items[item.id] = item
        }
      } else {
        items[item.id] = item
      }
    }

    for entry in history {
      guard entry.url.isFileURL == false || FileManager.default.fileExists(atPath: entry.url.path) else {
        continue
      }
      let duration = entry.duration.second
      let played = entry.mpvProgress?.second ?? 0
      let progress = duration > 0 ? min(max(played / duration, 0), 1) : 0
      let metadata = LibraryMetadata.parse(fileName: entry.name)
      insert(LibraryItem(
        url: entry.url,
        title: entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? metadata.title,
        subtitle: Self.subtitle(for: entry.url),
        metadata: metadata,
        duration: duration,
        progress: progress,
        added: entry.addedDate,
        isNetwork: !entry.url.isFileURL))
    }

    for url in NSDocumentController.shared.recentDocumentURLs {
      if url.isFileURL {
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true { continue }
      }
      let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      let metadata = LibraryMetadata.parse(fileName: url.lastPathComponent)
      insert(LibraryItem(
        url: url,
        title: metadata.title,
        subtitle: Self.subtitle(for: url),
        metadata: metadata,
        duration: 0,
        progress: 0,
        added: date ?? .distantPast,
        isNetwork: !url.isFileURL))
    }

    let byDate = items.values.sorted { $0.added > $1.added }
    recentlyAdded = Array(byDate.prefix(12))
    allItems = byDate.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    continueWatching = byDate.filter { $0.progress >= 0.02 && $0.progress <= 0.97 }

    if let last = Preference.url(for: .iinaLastPlayedFilePath) {
      let id = last.isFileURL ? last.standardizedFileURL.path : last.absoluteString
      hero = items[id]
    }
    if hero == nil {
      hero = continueWatching.first ?? byDate.first
    }
    hasLoaded = true
  }

  // MARK: - Names

  private static func subtitle(for url: URL) -> String {
    if !url.isFileURL {
      return url.host ?? url.absoluteString
    }
    let parent = url.deletingLastPathComponent()
    let name = parent.lastPathComponent
    return name.isEmpty ? parent.path : name
  }
}

// MARK: - Frames

/// Loads one still per file, so a card shows the video rather than a file icon.
///
/// The order is deliberate: Quick Look is fast and uses the system's own cache,
/// AVFoundation covers the formats it knows, and a drawn placeholder covers
/// everything else. A failure is not surfaced — a poster is decoration, and the
/// card remains usable without one.
@MainActor
final class PosterStore {

  static let shared = PosterStore()

  private let cache = NSCache<NSString, NSImage>()
  private var tasks: [String: Task<NSImage?, Never>] = [:]

  func image(for url: URL) async -> NSImage? {
    guard url.isFileURL else { return nil }

    let key = url.standardizedFileURL.path
    if let cached = cache.object(forKey: key as NSString) {
      return cached
    }
    if let running = tasks[key] {
      return await running.value
    }

    let task = Task<NSImage?, Never> { await PosterStore.load(url) }
    tasks[key] = task
    let image = await task.value
    tasks[key] = nil
    if let image {
      cache.setObject(image, forKey: key as NSString)
    }
    return image
  }

  private static func load(_ url: URL) async -> NSImage? {
    if let artwork = await embeddedArtwork(url) {
      return artwork
    }
    if let image = await quickLook(url) {
      return image
    }
    return await videoFrame(url)
  }

  private static func embeddedArtwork(_ url: URL) async -> NSImage? {
    await Task.detached(priority: .utility) {
      FFmpegController.readArtwork(from: url)
    }.value
  }

  private static func quickLook(_ url: URL) async -> NSImage? {
    let request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: CGSize(width: Tokens.Size.n640, height: Tokens.Size.n360),
      scale: 1,
      representationTypes: .thumbnail)

    return await withCheckedContinuation { continuation in
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
        continuation.resume(returning: representation?.nsImage)
      }
    }
  }

  private static func videoFrame(_ url: URL) async -> NSImage? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: Tokens.Size.n640, height: Tokens.Size.n360)
    do {
      let duration = try await asset.load(.duration)
      let seconds = max(1, min(duration.seconds * 0.1, 60))
      let (image, _) = try await generator.image(
        at: CMTime(seconds: seconds, preferredTimescale: 600))
      return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    } catch {
      return nil
    }
  }
}

extension Notification.Name {
  static let libraryShouldReload = Notification.Name("UniPlayerLibraryShouldReload")
}
