//
//  MediaSourcesEnvironment.swift
//  uniplayer
//
//  App-wide ownership of the media catalog and source coordinator. The feature
//  is inert until `media.sources.enabled.v1` is set. Starting it imports the
//  legacy library once, configures the playback bridge and never contacts a
//  saved source: a launch is not a reconnect sweep.
//

import Foundation
import Combine

@MainActor
final class MediaSourcesEnvironment: ObservableObject {
  static let shared = MediaSourcesEnvironment()

  @Published private(set) var coordinator: SourceCoordinator?
  @Published private(set) var catalog: MediaCatalog?
  @Published private(set) var startupError: String?
  @Published private(set) var pendingAddRequest = false

  private var started = false
  private var observers: [NSObjectProtocol] = []
  private var startupTask: Task<Void, Never>?
  /// Identifies the current startup attempt. A superseded attempt may finish
  /// its import after a retry and must not publish its result.
  private var startupGeneration = 0
  private var cancellables: Set<AnyCancellable> = []

  private init() {}

  var isRunning: Bool { catalog != nil }

  func startIfEnabled() {
    guard MediaSourcesFeature.isEnabled else { return }
    start()
  }

  func start() {
    guard !started else { return }
    started = true
    do {
      let catalog = try MediaCatalog(databaseURL: MediaCatalog.defaultDatabaseURL)
      self.catalog = catalog
      let coordinator = SourceCoordinator(catalog: catalog)
      self.coordinator = coordinator
      // Forward coordinator changes so the sidebar, which observes only this
      // environment, sees asynchronous root and collection updates.
      coordinator.objectWillChange
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &cancellables)
      MediaPlaybackService.shared.configure(catalog: catalog)
      observeHistoryCleared(catalog: catalog)
      startupGeneration += 1
      let generation = startupGeneration
      startupTask = Task { @MainActor in
        await coordinator.load()
        let importError = await self.importLegacyLibraryIfNeeded(catalog: catalog)
        guard !Task.isCancelled, generation == self.startupGeneration else { return }
        await coordinator.load()
        // `load` is another suspension; a stop or retry during it must not let
        // this superseded attempt publish.
        guard !Task.isCancelled, generation == self.startupGeneration else { return }
        // The import reports its own failure; do not erase it on the way out.
        self.startupError = importError
      }
    } catch {
      startupError = (error as? MediaSourceError)?.userMessage
        ?? "The media library could not be opened."
      Logger.log("Media sources failed to start: \(error)", level: .error,
                 subsystem: Logger.Sub.mediaSources)
    }
  }

  func enable() {
    MediaSourcesFeature.setEnabled(true)
    start()
  }

  func disable() {
    MediaSourcesFeature.setEnabled(false)
    stop()
  }

  func stop() {
    guard started || catalog != nil else { return }
    startupTask?.cancel()
    startupTask = nil
    coordinator?.roots.forEach { coordinator?.cancel(rootID: $0.id) }
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    cancellables.removeAll()
    catalog?.close()
    catalog = nil
    coordinator = nil
    MediaPlaybackService.shared.disable()
    started = false
    pendingAddRequest = false
  }

  func retryStartup() {
    // Retry is a restart, not a second environment: the failed attempt may
    // have installed observers, a playback bridge or a startup task that would
    // otherwise outlive it.
    stop()
    startupError = nil
    start()
  }

  func dismissStartupError() {
    startupError = nil
  }

  /// Queue an Add Source request until a library view can present the panel.
  /// A menu action can run before the window's SwiftUI hierarchy exists.
  func requestAddSource() {
    pendingAddRequest = true
    NotificationCenter.default.post(name: .mediaSourcesAddRequested, object: nil)
  }

  func consumeAddRequest() -> Bool {
    defer { pendingAddRequest = false }
    return pendingAddRequest
  }

  /// Returns nil when nothing is left to import, or the message to publish
  /// when the attempt failed. The caller decides whether the attempt is still
  /// current before publishing it.
  private func importLegacyLibraryIfNeeded(catalog: MediaCatalog) async -> String? {
    if (try? await catalog.migrationCompleted(MediaCatalogMigration.stateKey)) == true {
      return nil
    }
    let defaults = UserDefaults.standard
    let data = LegacyLibraryData(
      history: HistoryController.shared.historySnapshot(),
      recentURLs: NSDocumentController.shared.recentDocumentURLs,
      hiddenIDs: Set(defaults.stringArray(forKey: "library.hidden.v1") ?? []),
      watched: defaults.dictionary(forKey: "library.watched.v1") as? [String: Bool] ?? [:])
    let backup = catalog.databaseURL
      .deletingLastPathComponent()
      .appendingPathComponent("Backups", isDirectory: true)
    do {
      let report = try await MediaCatalogMigration.run(
        catalog: catalog, data: data,
        historyFileURL: Utility.playbackHistoryURL,
        backupDirectory: backup)
      Logger.log("Imported \(report.historyImported) history and \(report.recentImported) recent items",
                 subsystem: Logger.Sub.mediaCatalog)
      return nil
    } catch {
      Logger.log("Legacy library import failed: \(error)", level: .error,
                 subsystem: Logger.Sub.mediaCatalog)
      return "The saved library could not be imported. Existing data and files were kept."
    }
  }

  private func observeHistoryCleared(catalog: MediaCatalog) {
    let observer = NotificationCenter.default.addObserver(
      forName: .iinaPlaybackHistoryCleared, object: nil, queue: .main) { _ in
        Task {
          try? await catalog.removeReasons(originID: "playbackHistory")
          try? await catalog.clearObservedHistory()
        }
      }
    observers.append(observer)
  }
}
