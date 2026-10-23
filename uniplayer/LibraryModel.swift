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
  var isMissing = false

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

/// Pure layout rules shared by window policy, views and regression tests.
enum LibraryLayout {
  static func videoHeight(width: CGFloat, viewportHeight: CGFloat) -> CGFloat {
    min(width / Tokens.Aspect.video,
        max(Tokens.Library.playerMinimumHeight, viewportHeight - Tokens.Library.playerReservedHeight))
  }

  /// Nil means the requested pane must overlay: never steal central width.
  static func paneFrame(frame: NSRect, screen: NSRect, delta: CGFloat, left: Bool) -> NSRect? {
    var result = frame
    result.size.width += delta
    if left { result.origin.x -= delta }
    guard result.width <= screen.width else { return nil }
    result.origin.x = min(max(result.minX, screen.minX), screen.maxX - result.width)
    return result
  }

  static func minimumWidth(left: CGFloat, right: CGFloat) -> CGFloat {
    Tokens.Library.contentMinimumWidth + left + right
  }

  static func boundedPaneWidth(_ width: CGFloat, left: Bool) -> CGFloat {
    min(max(width, left ? Tokens.Library.outwardSidebarMinimum : Tokens.Inspector.minimumWidth),
        left ? Tokens.Library.outwardSidebarMaximum : Tokens.Inspector.maximumWidth)
  }
}

enum LibrarySort: String, CaseIterable {
  case title, recent, progress
}

enum LibraryFilter: String, CaseIterable {
  case all, unfinished, watched, missing
}

enum LibraryQuery {
  static func apply(_ items: [LibraryItem], query: String, sort: LibrarySort,
                    filter: LibraryFilter) -> [LibraryItem] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = items.filter { item in
      let matches = term.isEmpty || item.title.localizedCaseInsensitiveContains(term)
        || item.subtitle.localizedCaseInsensitiveContains(term)
      switch filter {
      case .all: return matches
      case .unfinished: return matches && !item.isFinished
      case .watched: return matches && item.isFinished
      case .missing: return matches && item.isMissing
      }
    }
    return filtered.sorted {
      switch sort {
      case .title: return $0.title.localizedStandardCompare($1.title) == .orderedAscending
      case .recent: return $0.added > $1.added
      case .progress: return $0.progress > $1.progress
      }
    }
  }
}

// MARK: - Model

struct LibrarySnapshot {
  let continueWatching: [LibraryItem]
  let recentlyAdded: [LibraryItem]
  let allItems: [LibraryItem]
  let hero: LibraryItem?
}

@MainActor
final class LibraryModel: ObservableObject {

  @Published private(set) var continueWatching: [LibraryItem] = []
  @Published private(set) var recentlyAdded: [LibraryItem] = []
  @Published private(set) var allItems: [LibraryItem] = []
  @Published private(set) var hero: LibraryItem?
  @Published private(set) var hasLoaded = false
  @Published var query = ""
  @Published private(set) var hiddenCount = 0

  private let openHandler: (URL) -> Void
  private let defaults = UserDefaults.standard
  private static let hiddenKey = "library.hidden.v1"
  private static let watchedKey = "library.watched.v1"

  private var observers: [NSObjectProtocol] = []
  private var reloadTask: Task<Void, Never>?

  init(open: @escaping (URL) -> Void) {
    self.openHandler = open
    reload()

    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .iinaHistoryUpdated, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    })
    observers.append(center.addObserver(forName: .libraryShouldReload, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    })
    observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    })
  }

  deinit {
    reloadTask?.cancel()
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  func open(_ item: LibraryItem) {
    guard !item.isMissing else { locate(item); return }
    openHandler(item.url)
  }

  func remove(_ item: LibraryItem) {
    var hidden = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
    hidden.insert(item.id)
    defaults.set(Array(hidden), forKey: Self.hiddenKey)
    NotificationCenter.default.post(name: .libraryShouldReload, object: nil)
  }

  func restoreHiddenItems() {
    defaults.removeObject(forKey: Self.hiddenKey)
    NotificationCenter.default.post(name: .libraryShouldReload, object: nil)
  }

  func markWatched(_ item: LibraryItem) {
    var watched = defaults.dictionary(forKey: Self.watchedKey) as? [String: Bool] ?? [:]
    watched[item.id] = !item.isFinished
    defaults.set(watched, forKey: Self.watchedKey)
    NotificationCenter.default.post(name: .libraryShouldReload, object: nil)
  }

  func locate(_ item: LibraryItem) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = NSLocalizedString("Locate the missing video. The original file will not be deleted.", comment: "Locate")
    let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      HistoryController.shared.relocate(from: item.url, to: url)
      self?.reload()
    }
    if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
    else { panel.begin(completionHandler: finish) }
  }

  func openFilePanel() {
    AppDelegate.shared.openFile(NSApp)
  }

  var searchResults: [LibraryItem] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return [] }
    return LibraryQuery.apply(allItems, query: term, sort: .title, filter: .all)
  }

  func reload() {
    // Capture AppKit and defaults state on the main actor, then do the
    // filesystem and parsing work off it.
    let history = HistoryController.shared.history
    let recent = NSDocumentController.shared.recentDocumentURLs
    let lastPlayed = Preference.url(for: .iinaLastPlayedFilePath)
    let hidden = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
    let watched = defaults.dictionary(forKey: Self.watchedKey) as? [String: Bool] ?? [:]
    hiddenCount = hidden.count

    reloadTask?.cancel()
    reloadTask = Task.detached(priority: .utility) { [weak self] in
      let snapshot = Self.snapshot(history: history, recent: recent, lastPlayed: lastPlayed, hidden: hidden, watched: watched)
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        self?.apply(snapshot)
      }
    }
  }

  nonisolated static func snapshot(
    history: [PlaybackHistory],
    recent: [URL],
    lastPlayed: URL?, hidden: Set<String>, watched: [String: Bool]
  ) -> LibrarySnapshot {
    var items: [String: LibraryItem] = [:]

    func insert(_ item: LibraryItem) {
      guard !hidden.contains(item.id) else { return }
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
      let duration = entry.duration.second
      let played = entry.mpvProgress?.second ?? 0
      let id = entry.url.isFileURL ? entry.url.standardizedFileURL.path : entry.url.absoluteString
      let progress = watched[id].map { $0 ? 1.0 : 0.0 }
        ?? (duration > 0 ? min(max(played / duration, 0), 1) : 0)
      let metadata = LibraryMetadata.parse(fileName: entry.name)
      insert(LibraryItem(
        url: entry.url,
        title: entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? metadata.title,
        subtitle: subtitle(for: entry.url),
        metadata: metadata,
        duration: duration,
        progress: progress,
        added: entry.addedDate,
        isNetwork: !entry.url.isFileURL,
        isMissing: entry.url.isFileURL && !FileManager.default.fileExists(atPath: entry.url.path)))
    }

    for url in recent {
      if url.isFileURL {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true { continue }
      }
      let metadata = LibraryMetadata.parse(fileName: url.lastPathComponent)
      insert(LibraryItem(
        url: url,
        title: metadata.title,
        subtitle: subtitle(for: url),
        metadata: metadata,
        duration: 0,
        progress: 0,
        added: .distantPast,
        isNetwork: !url.isFileURL,
        isMissing: url.isFileURL && !FileManager.default.fileExists(atPath: url.path)))
    }

    let byDate = items.values.sorted { $0.added > $1.added }
    let continueWatching = byDate.filter { $0.progress >= 0.02 && $0.progress <= 0.97 }
    let allItems = byDate.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

    // Recompute the hero on every reload so a removed item cannot linger.
    var hero: LibraryItem? = nil
    if let lastPlayed {
      let id = lastPlayed.isFileURL ? lastPlayed.standardizedFileURL.path : lastPlayed.absoluteString
      hero = items[id]
    }
    hero = [hero, continueWatching.first, byDate.first].compactMap { $0 }.first { !$0.isMissing }

    return LibrarySnapshot(
      continueWatching: continueWatching,
      recentlyAdded: byDate,
      allItems: allItems,
      hero: hero)
  }

  private func apply(_ snapshot: LibrarySnapshot) {
    continueWatching = snapshot.continueWatching
    recentlyAdded = snapshot.recentlyAdded
    allItems = snapshot.allItems
    hero = snapshot.hero
    hasLoaded = true
  }

  // MARK: - Names

  private nonisolated static func subtitle(for url: URL) -> String {
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
private actor AsyncGate {
  private var available: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    available = limit
  }

  func wait() async {
    if available > 0 {
      available -= 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func signal() {
    if waiters.isEmpty {
      available += 1
    } else {
      waiters.removeFirst().resume()
    }
  }
}

@MainActor
final class PosterStore {

  static let shared = PosterStore()

  private let cache = NSCache<NSString, NSImage>()
  private let limiter = AsyncGate(limit: 4)
  private var tasks: [String: Task<NSImage?, Never>] = [:]

  private init() {
    cache.totalCostLimit = 128 * 1024 * 1024
    cache.countLimit = 200
  }

  func image(for url: URL) async -> NSImage? {
    guard url.isFileURL else { return nil }

    let key = Self.cacheKey(for: url)
    if let cached = cache.object(forKey: key as NSString) {
      return cached
    }
    if let running = tasks[key] {
      return await running.value
    }

    let task = Task<NSImage?, Never> { [limiter] in
      await limiter.wait()
      let loaded = await PosterStore.load(url)
      await limiter.signal()
      return loaded
    }
    tasks[key] = task
    let image = await task.value
    tasks[key] = nil
    guard !Task.isCancelled else { return nil }
    if let image {
      cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
    }
    return image
  }

  private static func cacheKey(for url: URL) -> String {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
    let size = values?.fileSize ?? 0
    return "\(url.standardizedFileURL.path)|\(date)|\(size)"
  }

  private static func cost(of image: NSImage) -> Int {
    Int(max(1, image.size.width * image.size.height * 4))
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
    let artwork = await Task.detached(priority: .utility) {
      FFmpegController.readArtwork(from: url)
    }.value
    guard let artwork else { return nil }
    return downsampled(artwork, maxSize: CGSize(width: Tokens.Size.n640, height: Tokens.Size.n360))
  }

  private static func downsampled(_ image: NSImage, maxSize: CGSize) -> NSImage {
    guard image.size.width > 0, image.size.height > 0 else { return image }
    let scale = min(1, min(maxSize.width / image.size.width, maxSize.height / image.size.height))
    guard scale < 1,
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return image
    }
    let target = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let width = Int(target.width)
    let height = Int(target.height)
    guard width > 0, height > 0,
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      return image
    }
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = context.makeImage() else { return image }
    return NSImage(cgImage: scaled, size: target)
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
