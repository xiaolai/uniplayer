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
  private var presenceTask: Task<Void, Never>?

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
    presenceTask?.cancel()
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  func open(_ item: LibraryItem) {
    guard !item.isMissing else { locate(item); return }
    openHandler(item.url)
  }

  func remove(_ item: LibraryItem) {
    if let catalog = MediaSourcesEnvironment.shared.catalog {
      // The catalog is authoritative while it runs; its organization store
      // mirrors the legacy defaults, so a separate write here would race it.
      let identifier = item.id
      Task {
        var resolved = try? await catalog.resolveAlias(kind: "filePath", value: identifier)
        if resolved == nil {
          resolved = try? await catalog.resolveAlias(kind: "url", value: identifier)
        }
        if let mediaID = resolved {
          try? await catalog.setHidden(mediaID: mediaID, hidden: true)
        }
      }
    } else {
      var hidden = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
      hidden.insert(item.id)
      defaults.set(Array(hidden), forKey: Self.hiddenKey)
    }
    NotificationCenter.default.post(name: .libraryShouldReload, object: nil)
  }

  func restoreHiddenItems() {
    defaults.removeObject(forKey: Self.hiddenKey)
    if let catalog = MediaSourcesEnvironment.shared.catalog {
      Task { try? await catalog.restoreAllHidden() }
    }
    NotificationCenter.default.post(name: .libraryShouldReload, object: nil)
  }

  func markWatched(_ item: LibraryItem) {
    if let catalog = MediaSourcesEnvironment.shared.catalog {
      // One owner for watched state while the catalog runs. The legacy path
      // wrote a persistent false override for Unwatched, which the catalog
      // represents by removing the override instead.
      let identifier = item.id
      let value = !item.isFinished
      Task {
        var resolved = try? await catalog.resolveAlias(kind: "filePath", value: identifier)
        if resolved == nil {
          resolved = try? await catalog.resolveAlias(kind: "url", value: identifier)
        }
        if let mediaID = resolved {
          try? await catalog.markWatched(mediaID: mediaID, watched: value)
        }
      }
    } else {
      var watched = defaults.dictionary(forKey: Self.watchedKey) as? [String: Bool] ?? [:]
      if item.isFinished {
        // Clearing a watched mark restores natural progress rather than
        // forcing a zero value.
        watched.removeValue(forKey: item.id)
      } else {
        watched[item.id] = true
      }
      defaults.set(watched, forKey: Self.watchedKey)
    }
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
    let history = HistoryController.shared.historySnapshot()
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
    history: [PlaybackHistorySnapshot],
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
      let duration = entry.duration
      let played = entry.progress ?? 0
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
        // Presence is unknown here. The legacy snapshot must not probe source
        // paths on a cooperative thread; the catalog resolves presence through
        // the bounded source workers when the feature is enabled.
        isMissing: false))
    }

    for url in recent {
      let metadata = LibraryMetadata.parse(fileName: url.lastPathComponent)
      let id = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
      let progress = watched[id].map { $0 ? 1.0 : 0.0 } ?? 0
      insert(LibraryItem(
        url: url,
        title: metadata.title,
        subtitle: subtitle(for: url),
        metadata: metadata,
        duration: 0,
        progress: progress,
        added: .distantPast,
        isNetwork: !url.isFileURL,
        isMissing: false))
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
    refreshPresence()
  }

  /// Missing detection is a separate, bounded pass: the legacy snapshot never
  /// probes a source path, but the library still needs to mark a file that is
  /// gone. With the catalog running its rows answer; without it, a bounded
  /// local observation lane probes only file URLs, with a short timeout.
  private func refreshPresence() {
    presenceTask?.cancel()
    let items = allItems
    guard !items.isEmpty else { return }
    presenceTask = Task { [weak self] in
      guard let self else { return }
      var missing: Set<String> = []
      if let catalog = MediaSourcesEnvironment.shared.catalog {
        let aliases: [(kind: String, value: String)] = items.flatMap { item in
          [("filePath", item.id), ("url", item.id)]
        }
        if let presence = try? await catalog.presence(forAliases: aliases) {
          for item in items where presence[item.id] == .missing {
            missing.insert(item.id)
          }
        }
      } else {
        missing = await Self.probeMissing(items)
      }
      guard !Task.isCancelled else { return }
      self.markMissing(missing)
    }
  }

  private func markMissing(_ missing: Set<String>) {
    guard !missing.isEmpty else { return }
    func update(_ item: LibraryItem) -> LibraryItem {
      var copy = item
      copy.isMissing = missing.contains(item.id)
      return copy
    }
    allItems = allItems.map(update)
    recentlyAdded = recentlyAdded.map(update)
    continueWatching = continueWatching.map(update)
    if let hero {
      self.hero = update(hero)
    }
  }

  private nonisolated static func probeMissing(_ items: [LibraryItem]) async -> Set<String> {
    let candidates = items.filter { $0.url.isFileURL }
    return await withTaskGroup(of: (String, Bool?).self) { group in
      for item in candidates {
        group.addTask {
          let path = item.url.standardizedFileURL.path
          do {
            let code: Int32? = try await SourceIOExecutor.shared.perform(
              lane: SourceIOLane.forPath(path),
              volumeKey: "presence:\(item.url.deletingLastPathComponent().path)",
              timeout: 1) {
                var info = stat()
                if stat(path, &info) == 0 { return nil }
                return errno
              }
            // Only a definitive "no such file" is absence; permission and I/O
            // errors are not evidence that the file is gone.
            switch code {
            case .some(ENOENT), .some(ENOTDIR): return (item.id, true)
            default: return (item.id, nil)
            }
          } catch {
            return (item.id, nil)
          }
        }
      }
      var missing: Set<String> = []
      for await (id, isMissing) in group {
        if isMissing == true { missing.insert(id) }
      }
      return missing
    }
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
/// Every attempt is bounded. Quick Look can hang on containers it does not
/// understand (an MKV was observed to exceed a minute), and an unbounded wait
/// would hold one of the four gate permits forever, starving every later card.
/// Formats AVFoundation cannot decode fall through to the bundled FFmpeg.
/// Resumes a poster continuation exactly once, whether the work finishes or
/// the deadline fires first.
private final class PosterResume: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false

  func resume(_ continuation: CheckedContinuation<NSImage?, Never>, with image: NSImage?) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    finished = true
    continuation.resume(returning: image)
  }
}

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

    let key = await Task.detached(priority: .utility) { () -> String? in
      // Eligibility comes first: `cacheKey` reads file metadata, which must
      // never be attempted on a network mount.
      guard MediaArtworkPolicy.allowsProbe(for: url) else { return nil }
      return Self.cacheKey(for: url)
    }.value
    guard let key else { return nil }
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

  private nonisolated static func cacheKey(for url: URL) -> String {
    // Runs off the main actor; the metadata read still belongs to a bounded
    // artwork probe, not a rendering pass.
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
    let size = values?.fileSize ?? 0
    return "\(url.standardizedFileURL.path)|\(date)|\(size)"
  }

  private static func cost(of image: NSImage) -> Int {
    Int(max(1, image.size.width * image.size.height * 4))
  }

  /// Resolves one poster with a hard deadline per stage. The caller's gate is
  /// therefore always released, even when a system service never answers.
  private static func load(_ url: URL) async -> NSImage? {
    if let artwork = await withTimeout(5, { await embeddedArtwork(url) }) {
      return artwork
    }
    let extensionName = url.pathExtension.lowercased()
    let avFoundationFirst: Set<String> = [
      "mp4", "m4v", "mov", "m4a", "mp3", "aac", "wav", "aif", "aiff", "caf",
    ]
    if avFoundationFirst.contains(extensionName) {
      if let image = await quickLook(url) { return image }
      if let image = await withTimeout(8, { await videoFrame(url) }) { return image }
    }
    if let image = await withTimeout(15, { await ffmpegFrame(url) }) { return image }
    if !avFoundationFirst.contains(extensionName) {
      if let image = await quickLook(url) { return image }
      if let image = await withTimeout(8, { await videoFrame(url) }) { return image }
    }
    return nil
  }

  /// Runs an operation with a deadline. The operation may keep running after
  /// the deadline; the point is that the caller and the poster gate do not.
  private static func withTimeout(_ seconds: Double,
                                  _ operation: @escaping @Sendable () async -> NSImage?) async -> NSImage? {
    await withCheckedContinuation { continuation in
      let gate = PosterResume()
      Task {
        let image = await operation()
        gate.resume(continuation, with: image)
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
        gate.resume(continuation, with: nil)
      }
    }
  }

  private static func ffmpegFrame(_ url: URL) async -> NSImage? {
    await Task.detached(priority: .utility) {
      FFmpegController.readFrame(from: url, at: 0, maxWidth: 640)
    }.value
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
      let gate = PosterResume()
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
        gate.resume(continuation, with: representation?.nsImage)
      }
      // Some containers make Quick Look hang instead of failing. Release the
      // caller after four seconds; the late answer is ignored.
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
        gate.resume(continuation, with: nil)
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
