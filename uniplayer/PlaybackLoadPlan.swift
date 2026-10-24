//
//  PlaybackLoadPlan.swift
//  uniplayer
//
//  The catalog's playback authority. A plan is resolved once at load time from
//  the stored play state and the existing resume preference. It carries the
//  requested intent, the media UUID and the exact start position so the engine
//  never has to guess between its own watch-later state and the catalog.
//

import Foundation

enum PlaybackIntent: String, Sendable {
  case ordinaryOpen
  case resume
  case fromBeginning
}

struct PlaybackLoadPlan: Equatable, Sendable {
  var entryID: UUID
  var mediaID: UUID?
  var url: URL
  var intent: PlaybackIntent
  var startPosition: Double
  var suppressWatchLater: Bool
  var knownDuration: Double?

  init(entryID: UUID = UUID(), mediaID: UUID?, url: URL,
       intent: PlaybackIntent, startPosition: Double,
       suppressWatchLater: Bool, knownDuration: Double? = nil) {
    self.entryID = entryID
    self.mediaID = mediaID
    self.url = url
    self.intent = intent
    self.startPosition = max(0, startPosition)
    self.suppressWatchLater = suppressWatchLater
    self.knownDuration = knownDuration
  }
}

/// The exact mpv `loadfile` arguments for a plan. File-local options are the
/// single authority: `resume-playback=no` suppresses watch-later for this file
/// and `start=<position>` applies the catalog position on load. A spike against
/// mpv 0.41 confirmed both options win over an existing watch-later `start`.
enum PlaybackEngineOptions {
  static func loadfileOptions(for plan: PlaybackLoadPlan?) -> String? {
    guard let plan, plan.suppressWatchLater else { return nil }
    let start = String(plan.startPosition.isFinite ? max(0, plan.startPosition) : 0)
    return "resume-playback=no,start=\(start)"
  }

  static func loadfileArguments(path: String, plan: PlaybackLoadPlan?) -> [String] {
    guard let options = loadfileOptions(for: plan) else { return [path] }
    return [path, "replace", "0", options]
  }
}

enum MediaPlaybackResolver {  /// Resolve exactly once, at actual load time. The rules are deliberately
  /// separate from mpv's watch-later behavior:
  /// - ordinary Open starts at zero for a completed or manually watched item;
  /// - otherwise it uses the catalog position only when the existing resume
  ///   preference is on;
  /// - Resume always uses the known position;
  /// - Play from Beginning always starts at zero.
  static func plan(for media: CatalogMedia, url: URL, intent: PlaybackIntent,
                   resumePreference: Bool) -> PlaybackLoadPlan {
    let state = media.playState
    let duration = state?.observedDuration ?? media.duration
    let start: Double
    switch intent {
    case .fromBeginning:
      start = 0
    case .resume:
      start = state?.observedPosition ?? 0
    case .ordinaryOpen:
      if media.isFinished {
        start = 0
      } else if resumePreference {
        start = state?.observedPosition ?? 0
      } else {
        start = 0
      }
    }
    return PlaybackLoadPlan(
      mediaID: media.id,
      url: url,
      intent: intent,
      startPosition: start,
      suppressWatchLater: true,
      knownDuration: duration)
  }

  /// A legacy URL has no catalog row. Its behavior stays exactly as before:
  /// mpv's global resume preference and watch-later files remain in charge.
  static func legacyPlan(url: URL, intent: PlaybackIntent,
                         resumePreference: Bool) -> PlaybackLoadPlan {
    PlaybackLoadPlan(
      mediaID: nil,
      url: url,
      intent: intent,
      startPosition: 0,
      suppressWatchLater: false,
      knownDuration: nil)
  }
}

/// Tracks one player's catalog-linked playback. It saves observed position and
/// completion, accumulates only real playing time for the adaptive watched
/// reset, and never edits mpv's global preferences permanently.
@MainActor
final class PlaybackStateBridge {
  private weak var player: PlayerCore?
  private let catalog: MediaCatalog
  private var mediaID: UUID?
  private var activePlan: PlaybackLoadPlan?
  private var timer: Timer?
  private var ticks = 0
  private var playingSeconds: Double = 0
  private var lastTick: Date?
  /// Bumped whenever the player's identity changes. Async alias resolution
  /// captures it so a late result cannot attach an identity to a later file.
  private var sessionGeneration = 0

  init(player: PlayerCore, catalog: MediaCatalog) {
    self.player = player
    self.catalog = catalog
  }

  deinit { timer?.invalidate() }

  /// Flush the previous item and detach it before a new load replaces the
  /// player's current URL/duration. A late end-file for the old item then has
  /// no media identity to write against.
  func beginLoad() {
    finishSession()
    stopTimer()
    sessionGeneration += 1
    mediaID = nil
    activePlan = nil
    player?.activePlaybackPlan = nil
    playingSeconds = 0
    ticks = 0
  }

  func saveNow() {
    save(force: true)
  }

  func fileLoaded() {
    guard let player else { return }
    sessionGeneration += 1
    playingSeconds = 0
    ticks = 0
    let plan = player.pendingPlaybackPlan
    if let plan, player.info.currentURL == plan.url {
      player.pendingPlaybackPlan = nil
      player.activePlaybackPlan = plan
      mediaID = plan.mediaID
      activePlan = plan
      if let id = plan.mediaID, Preference.bool(for: .recordPlaybackHistory) {
        // Play implies history membership, including for a Browse Only root.
        // Clear Playback History removes this exact origin later. The history
        // preference governs whether playback is recorded at all.
        Task { [catalog] in
          try? await catalog.addReason(mediaID: id, reason: .history,
                                       originID: "playbackHistory")
        }
      }
      if plan.intent != .ordinaryOpen, let id = plan.mediaID {
        // Explicit Resume or Play from Beginning clears a manual Watched
        // override only after the file loaded successfully.
        Task { [catalog] in
          try? await catalog.clearManualOverride(mediaID: id)
        }
      }
    } else {
      // A plan must never attach to a different file than the one it was
      // resolved for (deferred stop, network replacement or playlist move).
      player.pendingPlaybackPlan = nil
      mediaID = nil
      activePlan = nil
      player.activePlaybackPlan = nil
      // A playlist auto-advance has no pending plan. Resolve the legacy alias
      // asynchronously so observed progress is still saved for an item that
      // was imported from history. The start position remains mpv's.
      if let url = player.info.currentURL {
        let kind = url.isFileURL ? "filePath" : "url"
        let value = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
        let generation = sessionGeneration
        Task { @MainActor [weak self] in
          guard let self else { return }
          let resolved: UUID?
          if let existing = try? await self.catalog.resolveAlias(kind: kind, value: value) {
            resolved = existing
          } else {
            // A URL opened outside the browser still joins the catalog, so
            // progress and history have a stable identity.
            resolved = try? await self.catalog.importLegacyMedia(
              aliasKind: kind, aliasValue: value,
              name: url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent,
              duration: nil, added: Date(), presence: .present)
          }
          guard let resolved else { return }
          // The session, not just the URL, must still be the one this task was
          // started for: a stop or replacement keeps the URL briefly.
          guard self.sessionGeneration == generation,
                self.player?.info.currentURL == url else { return }
          self.mediaID = resolved
          guard Preference.bool(for: .recordPlaybackHistory) else { return }
          try? await self.catalog.addReason(mediaID: resolved, reason: .history,
                                            originID: "playbackHistory")
        }
      }
    }
    startTimer()
  }

  func fileEnded() {
    finishSession()
    stopTimer()
    sessionGeneration += 1
    mediaID = nil
    activePlan = nil
    player?.activePlaybackPlan = nil
    playingSeconds = 0
    ticks = 0
  }

  /// Final save and the ordinary-Open watched reset. It runs both at end-file
  /// and before a replacement load clears the old identity.
  private func finishSession() {
    guard let player, mediaID != nil else { return }
    let duration = player.info.videoDuration?.second
      ?? activePlan?.knownDuration ?? 0
    let position = player.info.videoPosition?.second ?? 0
    let completed = duration > 0 && position / duration >= 0.97
    let intent = activePlan?.intent
    let endingMediaID = mediaID
    save(force: true)
    if intent == .ordinaryOpen, let endingMediaID,
       completed || meaningfulPlayback(duration: duration) {
      Task { [catalog] in
        try? await catalog.clearManualOverride(mediaID: endingMediaID)
      }
    }
  }

  func stopped() {
    fileEnded()
  }

  private func startTimer() {
    stopTimer()
    lastTick = Date()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
    lastTick = nil
  }

  private func tick() {
    guard let player else { return }
    let now = Date()
    let delta = lastTick.map { now.timeIntervalSince($0) } ?? 0
    lastTick = now
    if player.info.state == .playing, !player.info.pausedForCache {
      playingSeconds += min(delta, 2)
    }
    ticks += 1
    if ticks % 5 == 0 { save(force: false) }
  }

  private func save(force: Bool) {
    guard let player, let mediaID,
          player.info.currentURL != nil,
          player.info.state != .shuttingDown,
          player.info.state != .shutDown else { return }
    let (position, duration) = observation()
    let completed = duration > 0 && position / duration >= 0.97
    let state = MediaPlayState(
      mediaID: mediaID,
      observedPosition: position,
      observedDuration: duration > 0 ? duration : nil,
      completed: completed,
      manualWatchedOverride: nil,
      lastManualActionAt: nil,
      lastManualActionKind: nil,
      observedAt: Date(),
      revision: 0)
    catalog.enqueuePlayState(state)
    if force { lastTick = Date() }
  }

  /// Prefer live mpv properties over cached UI values: the player's sync timer
  /// can be off while the window is hidden, which would otherwise freeze the
  /// catalog's progress.
  private func observation() -> (position: Double, duration: Double) {
    guard let player else { return (0, 0) }
    if player.info.state.active {
      let position = player.mpv.getDouble(MPVProperty.timePos)
      let duration = player.mpv.getDouble(MPVProperty.duration)
      if position.isFinite, position >= 0, duration.isFinite, duration > 0 {
        return (position, duration)
      }
    }
    return (player.info.videoPosition?.second ?? 0,
            player.info.videoDuration?.second ?? activePlan?.knownDuration ?? 0)
  }

  private func meaningfulPlayback(duration: Double) -> Bool {
    let threshold = duration > 0 ? min(60, duration * 0.1) : 60
    return playingSeconds >= threshold
  }
}

/// Owns the catalog and one bridge per player. It is configured only when the
/// media-sources feature is enabled; with no catalog every call is a no-op and
/// legacy playback is untouched.
@MainActor
final class MediaPlaybackService {
  static let shared = MediaPlaybackService()

  private(set) var catalog: MediaCatalog?
  private var bridges: [ObjectIdentifier: PlaybackStateBridge] = [:]

  func configure(catalog: MediaCatalog) {
    self.catalog = catalog
  }

  func disable() {
    catalog = nil
    bridges.removeAll()
  }

  func fileLoaded(player: PlayerCore) {
    guard let catalog else { return }
    bridge(for: player, catalog: catalog).fileLoaded()
  }

  func beginLoad(player: PlayerCore) {
    guard catalog != nil else { return }
    bridges[ObjectIdentifier(player)]?.beginLoad()
  }

  func saveCurrent(player: PlayerCore) {
    guard catalog != nil else { return }
    bridges[ObjectIdentifier(player)]?.saveNow()
  }

  func fileEnded(player: PlayerCore) {
    guard catalog != nil else { return }
    bridges[ObjectIdentifier(player)]?.fileEnded()
  }

  func playerStopped(player: PlayerCore) {
    guard catalog != nil else { return }
    bridges[ObjectIdentifier(player)]?.stopped()
  }

  private func bridge(for player: PlayerCore, catalog: MediaCatalog) -> PlaybackStateBridge {
    let key = ObjectIdentifier(player)
    if let bridge = bridges[key] { return bridge }
    let bridge = PlaybackStateBridge(player: player, catalog: catalog)
    bridges[key] = bridge
    return bridge
  }
}
