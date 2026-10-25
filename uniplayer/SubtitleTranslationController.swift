//
//  SubtitleTranslationController.swift
//  uniplayer
//
//  Owns AI subtitle translation for one player. External text subtitle files
//  are translated ahead of the playhead; embedded subtitles are translated one
//  line at a time. The result is drawn by mpv's OSD overlay, so it follows the
//  video in every presentation without entering the subtitle track list.
//

import Cocoa

final class SubtitleTranslationController {
  private unowned let player: PlayerCore
  private let engine: SubtitleTranslationEngine
  private let preferences = Preference.Observer()

  private enum Mode {
    case idle
    case waiting
    case preparing
    case cues([SubtitleCue])
    case live

    var isRunning: Bool {
      switch self {
      case .preparing, .cues, .live: return true
      case .idle, .waiting: return false
      }
    }
  }

  private struct LiveLine {
    let id: Int
    let text: String
    let start: Double
    let end: Double
  }

  /// Seconds of subtitle text translated ahead of the playhead.
  private static let lookaheadSeconds: Double = 30
  private static let maximumCuesPerRequest = 12
  private static let maximumFailuresPerLine = 3

  private var mode: Mode = .idle
  private var sourceTrackID: Int?
  private var sourcePath: String?
  private var sourceEncoding: String?
  private var sourceModificationDate: Date?
  private var lastModificationCheck = Date.distantPast
  private var translationLanguage = ""
  private var pendingLanguage: String?
  private var lastLanguageChange = Date.distantPast
  private var loadGeneration = 0

  private var sourceLoadTask: Task<Void, Never>?
  private var requestTask: Task<Void, Never>?
  private var lineTask: Task<Void, Never>?
  private var lineGeneration = 0
  private var requestInFlight = false
  private var requestStartedAt: Date?

  private var translatedCues: [Int: String] = [:]
  private var failures: [String: Int] = [:]
  private var currentLine: LiveLine?
  private var liveText: String?
  private var liveUntil: Date?
  private var lastPosition: Double?

  private var timer: Timer?
  private var lastTopUp = Date.distantPast
  private var nextAttemptAt = Date.distantPast
  private var backoff: TimeInterval = 5
  private var hardBlocked = false
  private var lastErrorShownAt: Date?

  /// Unique within this player's OSD namespace; plugin overlays use their own.
  private lazy var overlay = CaptionOverlayController(
    player: player, overlayID: "1431198513")

  private var pendingUserInitiation = false
  private var shuttingDown = false

  init(player: PlayerCore, engine: SubtitleTranslationEngine = SubtitleTranslationEngine()) {
    self.player = player
    self.engine = engine
    observePreferences()
    observePlayer()
  }

  deinit {
    sourceLoadTask?.cancel()
    requestTask?.cancel()
    lineTask?.cancel()
    timer?.invalidate()
  }

  // MARK: - Public state

  var isEnabled: Bool {
    SubtitleTranslationSettings.isEnabled
  }

  /// Toggles the feature from the menu or the inline player.
  func userSetEnabled(_ enabled: Bool) {
    pendingUserInitiation = true
    if SubtitleTranslationSettings.isEnabled == enabled {
      let initiated = pendingUserInitiation
      pendingUserInitiation = false
      applyEnabledState(userInitiated: initiated)
    } else {
      Preference.set(enabled, for: .subtitleTranslationEnabled)
    }
  }

  /// Called by `PlayerCore` when mpv's `sub-text` property changes.
  func sourceTextChanged(_ text: String) {
    guard isEnabled, !shuttingDown, player.info.state.active, player.mpv != nil else { return }
    guard case .live = mode else { return }
    handleSourceLine(text)
  }

  // MARK: - Observation

  private func observePreferences() {
    preferences.addAll([
      .subtitleTranslationEnabled,
      .subtitleTranslationLanguage,
      .assistantProvider,
      .assistantProfile,
      .assistantEndpoint,
      .assistantModel,
      .translationSource,
      .translationCodexModel,
      .translationClaudeModel,
    ]) { [weak self] key in
      guard let self else { return }
      if Thread.isMainThread {
        self.preferenceChanged(key)
      } else {
        DispatchQueue.main.async { self.preferenceChanged(key) }
      }
    }
  }

  private func observePlayer() {
    player.observe(.iinaFileLoaded) { [weak self] _ in self?.fileLoaded() }
    player.observe(.iinaSIDChanged) { [weak self] _ in self?.trackChanged() }
    player.observe(.iinaTracklistChanged) { [weak self] _ in self?.trackListChanged() }
    player.observe(.iinaPlayerStopped) { [weak self] _ in self?.playerStopped() }
    player.observe(.iinaPlayerShutdown) { [weak self] _ in self?.playerShutdown() }
  }

  private func preferenceChanged(_ key: Preference.Key) {
    if key == .subtitleTranslationEnabled {
      let initiated = pendingUserInitiation
      pendingUserInitiation = false
      applyEnabledState(userInitiated: initiated)
    } else if key == .subtitleTranslationLanguage {
      pendingLanguage = SubtitleTranslationSettings.targetLanguage()
      lastLanguageChange = Date()
    } else if key == .assistantProvider || key == .assistantProfile
                || key == .assistantEndpoint || key == .assistantModel
                || key == .translationSource || key == .translationCodexModel
                || key == .translationClaudeModel {
      hardBlocked = false
      lastErrorShownAt = nil
      nextAttemptAt = .distantPast
      if isEnabled, !shuttingDown {
        if mode.isRunning {
          // The next top-up or line change uses the corrected settings.
        } else {
          startIfPossible(userInitiated: false)
        }
      }
    }
  }

  private func applyEnabledState(userInitiated: Bool) {
    player.postNotification(.iinaSubtitleTranslationChanged)
    if isEnabled {
      startIfPossible(userInitiated: userInitiated)
    } else {
      stopSession()
      mode = .idle
    }
  }

  // MARK: - Starting and stopping

  private func startIfPossible(userInitiated: Bool) {
    guard isEnabled, !shuttingDown, player.info.state.active, player.mpv != nil else { return }
    guard player.info.isAudio != .isAudio else {
      stopSession()
      mode = .waiting
      return
    }
    guard let track = player.info.currentTrack(.sub), track.id != 0 else {
      stopSession()
      mode = .waiting
      if userInitiated {
        showMessage(NSLocalizedString("Select a text subtitle track to translate.",
                                      comment: "Subtitle translation"))
      }
      return
    }
    guard !track.isImage else {
      stopSession()
      mode = .waiting
      if userInitiated {
        showMessage(NSLocalizedString("Image subtitles can’t be translated.",
                                      comment: "Subtitle translation"))
      }
      return
    }
    if track.id == sourceTrackID, mode.isRunning { return }

    stopSession()
    sourceTrackID = track.id
    translationLanguage = SubtitleTranslationSettings.targetLanguage()
    pendingLanguage = nil

    guard currentConfiguration(showError: userInitiated) != nil else {
      mode = .waiting
      return
    }
    backoff = 5
    nextAttemptAt = .distantPast
    lastErrorShownAt = nil
    lastTopUp = .distantPast

    let path = Self.localPath(from: track.externalFilename)
    sourcePath = path
    sourceEncoding = player.mpv.getString(MPVOption.Subtitles.subCodepage)
    sourceModificationDate = path.flatMap(Self.modificationDate)
    lastModificationCheck = Date()
    startTimer()

    player.log("Subtitle translation source: track \(track.id), "
               + (path == nil ? "embedded" : "external"))
    guard let path else {
      beginLive(userInitiated: userInitiated)
      return
    }
    loadCues(at: path, trackID: track.id, encoding: sourceEncoding,
             userInitiated: userInitiated)
  }

  private func loadCues(at path: String, trackID: Int, encoding: String?, userInitiated: Bool) {
    mode = .preparing
    loadGeneration += 1
    let generation = loadGeneration
    sourceLoadTask?.cancel()
    sourceLoadTask = Task { [weak self] in
      let cues: [SubtitleCue]? = await Task.detached(priority: .utility) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return SubtitleCueParser.cues(from: data, encodingName: encoding)
      }.value
      await MainActor.run {
        guard let self, generation == self.loadGeneration,
              self.sourceTrackID == trackID, self.isEnabled else { return }
        self.player.log("Subtitle translation parsed \(cues?.count ?? 0) cues")
        if let cues, !cues.isEmpty {
          self.begin(cues: cues, userInitiated: userInitiated)
        } else {
          self.beginLive(userInitiated: userInitiated)
        }
      }
    }
  }

  private func begin(cues: [SubtitleCue], userInitiated: Bool) {
    mode = .cues(cues)
    translatedCues.removeAll(keepingCapacity: true)
    failures.removeAll()
    let language = translationLanguage
    for (index, cue) in cues.enumerated() {
      if let translation = engine.cachedTranslation(for: cue.text, language: language) {
        translatedCues[index] = translation
      }
    }
    lastTopUp = .distantPast
    if userInitiated { announceTranslation() }
    topUpIfNeeded()
  }

  private func beginLive(userInitiated: Bool) {
    mode = .live
    translatedCues.removeAll()
    failures.removeAll()
    currentLine = nil
    liveText = nil
    liveUntil = nil
    if userInitiated { announceTranslation() }
    readCurrentSubtitle()
  }

  private func stopSession() {
    sourceLoadTask?.cancel()
    sourceLoadTask = nil
    requestTask?.cancel()
    requestTask = nil
    lineTask?.cancel()
    lineTask = nil
    loadGeneration += 1
    lineGeneration += 1
    requestInFlight = false
    requestStartedAt = nil
    timer?.invalidate()
    timer = nil
    translatedCues.removeAll()
    failures.removeAll()
    currentLine = nil
    liveText = nil
    liveUntil = nil
    lastPosition = nil
    pendingLanguage = nil
    overlay.clear()
    mode = .idle
  }

  private func fileLoaded() {
    guard isEnabled, !shuttingDown else { return }
    stopSession()
    sourceTrackID = nil
    startIfPossible(userInitiated: false)
  }

  private func trackChanged() {
    guard isEnabled, !shuttingDown else { return }
    let id = player.info.sid ?? 0
    if id == 0 {
      stopSession()
      mode = .waiting
      return
    }
    if id != sourceTrackID || !mode.isRunning {
      stopSession()
      startIfPossible(userInitiated: false)
    }
  }

  private func trackListChanged() {
    guard isEnabled, !shuttingDown else { return }
    if !mode.isRunning {
      startIfPossible(userInitiated: false)
    }
  }

  private func playerStopped() {
    stopSession()
    sourceTrackID = nil
    sourcePath = nil
    sourceEncoding = nil
    sourceModificationDate = nil
  }

  private func playerShutdown() {
    shuttingDown = true
    stopSession()
    sourceTrackID = nil
    sourcePath = nil
    sourceEncoding = nil
    sourceModificationDate = nil
  }

  // MARK: - Timer

  private func startTimer() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
      self?.tick()
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func tick() {
    guard isEnabled, !shuttingDown, player.info.state.active, player.mpv != nil else { return }
    if hardBlocked, Date() >= nextAttemptAt {
      // Re-read the provider settings periodically so a corrected Keychain
      // key recovers without the user toggling the feature.
      hardBlocked = false
    }
    if requestInFlight, let started = requestStartedAt,
       Date().timeIntervalSince(started) > 30 {
      requestTask?.cancel()
      requestTask = nil
      requestInFlight = false
      requestStartedAt = nil
      handle(AssistantError.timedOut)
    }
    let position = player.mpv.getDouble(MPVProperty.timePos)
    if case .live = mode,
       let last = lastPosition, abs(position - last) > 1.0 {
      // A seek invalidates the line currently being translated.
      currentLine = nil
      liveText = nil
      liveUntil = nil
      lineTask?.cancel()
      lineTask = nil
      readCurrentSubtitle()
    }
    lastPosition = position
    updateOverlay()
    if Date() >= nextAttemptAt, !hardBlocked {
      topUpIfNeeded()
    }
    if let pendingLanguage, Date().timeIntervalSince(lastLanguageChange) > 1.5,
       pendingLanguage != translationLanguage {
      self.pendingLanguage = nil
      translationLanguage = pendingLanguage
      stopSession()
      startIfPossible(userInitiated: false)
    }
  }

  // MARK: - Translation

  private func topUpIfNeeded() {
    guard !requestInFlight, !hardBlocked, Date() >= nextAttemptAt else { return }
    // Hidden subtitles are not translated ahead; showing them again resumes
    // this on the next tick and the cache keeps earlier work.
    guard player.info.isSubVisible else { return }
    guard Date().timeIntervalSince(lastTopUp) >= 1.5 else { return }
    lastTopUp = Date()
    guard case .cues = mode else { return }
    checkSourceFile()
    guard case .cues(let cues) = mode else { return }

    let position = player.mpv.getDouble(MPVProperty.timePos)
    let delay = player.mpv.getDouble(MPVOption.Subtitles.subDelay)
    let speed = max(player.mpv.getDouble(MPVOption.Subtitles.subSpeed), 0.1)
    let selected = SubtitleTranslationPlanner.cueIndices(
      cues: cues,
      position: position,
      delay: delay,
      speed: speed,
      translated: Set(translatedCues.keys),
      failures: failures,
      lookahead: Self.lookaheadSeconds,
      maximum: Self.maximumCuesPerRequest,
      maximumFailures: Self.maximumFailuresPerLine)
    guard !selected.isEmpty else { return }
    guard let configuration = currentConfiguration(showError: true) else { return }

    let generation = loadGeneration
    let language = translationLanguage
    let items = selected.map { (id: $0, text: cues[$0].text) }
    requestInFlight = true
    requestStartedAt = Date()
    requestTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await self.engine.translate(
          items: items, language: language, configuration: configuration)
        await MainActor.run {
          self.requestInFlight = false
          self.requestStartedAt = nil
          guard generation == self.loadGeneration, language == self.translationLanguage,
                case .cues = self.mode else { return }
          guard !result.isEmpty else {
            // The provider answered but translated nothing. Treat it like a
            // failed batch instead of hammering it every 1.5 seconds.
            self.handle(SubtitleTranslationError.invalidResponse)
            return
          }
          for (index, translation) in result {
            self.translatedCues[index] = translation
          }
          for index in selected where result[index] == nil {
            self.failures[cues[index].cacheText, default: 0] += 1
          }
          self.backoff = 5
          self.nextAttemptAt = .distantPast
          self.updateOverlay()
        }
      } catch {
        await MainActor.run {
          self.requestInFlight = false
          self.requestStartedAt = nil
          guard generation == self.loadGeneration else { return }
          self.handle(error)
        }
      }
    }
  }

  private func checkSourceFile() {
    guard let sourcePath, Date().timeIntervalSince(lastModificationCheck) >= 5 else { return }
    lastModificationCheck = Date()
    let current = Self.modificationDate(of: sourcePath)
    let encoding = player.mpv.getString(MPVOption.Subtitles.subCodepage)
    guard current != sourceModificationDate || encoding != sourceEncoding else { return }
    player.log("Subtitle file or encoding changed; reloading the translation source")
    sourceTrackID = nil
    stopSession()
    startIfPossible(userInitiated: false)
  }

  private func handleSourceLine(_ raw: String) {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      lineTask?.cancel()
      lineTask = nil
      currentLine = nil
      liveText = nil
      liveUntil = nil
      updateOverlay()
      return
    }
    guard Date() >= nextAttemptAt, !hardBlocked, player.info.isSubVisible else { return }

    let position = player.mpv.getDouble(MPVProperty.timePos)
    var start = player.mpv.getDouble(MPVProperty.subStart)
    var end = player.mpv.getDouble(MPVProperty.subEnd)
    if !start.isFinite || start < 0 || start > position + 1 { start = position }
    if !end.isFinite || end <= start { end = start + 4 }

    if let current = currentLine, current.text == text, abs(current.start - start) < 0.05 {
      return
    }

    lineGeneration += 1
    let generation = lineGeneration
    let line = LiveLine(id: generation, text: text, start: start, end: end)
    lineTask?.cancel()
    lineTask = nil
    currentLine = line
    liveText = nil
    liveUntil = nil

    if let cached = engine.cachedTranslation(for: text, language: translationLanguage) {
      displayLive(cached, for: line)
      return
    }
    updateOverlay()
    guard let configuration = currentConfiguration(showError: true) else { return }
    let language = translationLanguage
    lineTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await self.engine.translate(
          items: [(0, text)], language: language, configuration: configuration)
        await MainActor.run {
          guard generation == self.lineGeneration, self.currentLine?.id == generation,
                language == self.translationLanguage, case .live = self.mode else { return }
          if let translation = result[0] {
            self.displayLive(translation, for: line)
          }
        }
      } catch {
        await MainActor.run {
          guard generation == self.lineGeneration else { return }
          self.handle(error)
        }
      }
    }
  }

  private func displayLive(_ translation: String, for line: LiveLine) {
    liveText = translation
    let position = player.mpv.getDouble(MPVProperty.timePos)
    let remaining = max(0, line.end - position)
    liveUntil = Date().addingTimeInterval(max(1.5, remaining + 0.4))
    updateOverlay()
  }

  private func readCurrentSubtitle() {
    guard case .live = mode, player.mpv != nil else { return }
    guard let text = player.mpv.getString(MPVProperty.subText), !text.isEmpty else { return }
    handleSourceLine(text)
  }

  // MARK: - Overlay

  private func updateOverlay() {
    guard isEnabled, !shuttingDown, player.info.state.active, player.mpv != nil,
          mode.isRunning, player.info.isSubVisible else {
      overlay.clear()
      return
    }

    let position = player.mpv.getDouble(MPVProperty.timePos)
    var text: String?
    switch mode {
    case .cues(let cues):
      let delay = player.mpv.getDouble(MPVOption.Subtitles.subDelay)
      let speed = max(player.mpv.getDouble(MPVOption.Subtitles.subSpeed), 0.1)
      if let index = cues.activeCueIndex(at: position, delay: delay, speed: speed) {
        text = translatedCues[index]
      }
    case .live:
      if let value = liveText {
        if player.info.state == .paused {
          text = value
        } else if let deadline = liveUntil, Date() <= deadline {
          text = value
        }
      }
    case .idle, .waiting, .preparing:
      break
    }

    guard let text, !text.isEmpty else {
      overlay.clear()
      return
    }
    overlay.show(text: text)
  }

  // MARK: - Configuration and errors

  private func currentConfiguration(showError: Bool) -> AssistantConfiguration? {
    // Read on each request so a new Keychain key or a settings change applies
    // without restarting; the read is local and cheap.
    let configuration = AssistantConfiguration.load()
    let source = TranslationSettings.source
    guard TranslationSettings.isConfigured(for: source) else {
      hardBlocked = true
      nextAttemptAt = Date().addingTimeInterval(60)
      overlay.clear()
      if showError {
        showErrorOnce(configurationProblem(for: source), throttle: 300)
      }
      return nil
    }
    hardBlocked = false
    return configuration
  }

  private func configurationProblem(for source: TranslationSource) -> String {
    TranslationSettings.configurationProblem(for: source)
      ?? NSLocalizedString(
        "Set the AI provider in Settings › AI to translate subtitles.",
        comment: "Subtitle translation")
  }

  private func handle(_ error: Error) {
    if error is CancellationError { return }
    if let assistant = error as? AssistantError, assistant == .cancelled { return }
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    player.log("Subtitle translation failed: \(message)", level: .warning)

    if let assistant = error as? AssistantError, assistant.needsSettingsCorrection {
      hardBlocked = true
      nextAttemptAt = Date().addingTimeInterval(60)
      overlay.clear()
      showErrorOnce(message, throttle: 300)
      return
    }
    backoff = min(backoff * 2, 120)
    nextAttemptAt = Date().addingTimeInterval(backoff)
    showErrorOnce(String(format: NSLocalizedString(
      "Subtitle translation is unavailable: %@", comment: "Subtitle translation"), message))
  }

  private func showErrorOnce(_ message: String, throttle: TimeInterval = 30) {
    let now = Date()
    if let last = lastErrorShownAt, now.timeIntervalSince(last) < throttle { return }
    lastErrorShownAt = now
    showMessage(message)
  }

  private func announceTranslation() {
    showMessage(String(format: NSLocalizedString(
      "Translating subtitles into %@", comment: "Subtitle translation"),
      translationLanguage))
  }

  private func showMessage(_ message: String) {
    player.sendOSD(.custom(message))
  }

  // MARK: - Helpers

  private static func localPath(from externalFilename: String?) -> String? {
    guard let externalFilename, !externalFilename.isEmpty else { return nil }
    if externalFilename.hasPrefix("file://") {
      guard let url = URL(string: externalFilename), url.isFileURL else { return nil }
      return url.path
    }
    return externalFilename.hasPrefix("/") ? externalFilename : nil
  }

  private static func modificationDate(of path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }
}
