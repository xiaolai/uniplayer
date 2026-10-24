//
//  LiveTranslationTranscriptionController.swift
//  uniplayer
//
//  Owns the audio source and the speech recognizer for one player. It starts
//  only when live translation is enabled, playback is running, no text
//  subtitle track is active, and the language is known and does not equal the
//  target. The target text pipeline is added by the next stage.
//
//  Debug logs include the recognized source text; they are local-only.
//

import AVFoundation
import Cocoa

final class LiveTranslationTranscriptionController {
  static let preferredFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000, channels: 1, interleaved: false)!

  private unowned let player: PlayerCore
  private let speechInventory = SystemSpeechModelInventory()
  private let preferences = Preference.Observer()
  private let sourceFactory: SourceFactory?
  private let recognizerFactory: (() -> SpeechRecognizing)?

  typealias SourceFactory = @MainActor
    (URL?, TimeInterval, Bool, Double) async throws
      -> (AudioCapturing, AsyncStream<AudioFrame>, String?)

  private var generation = 0
  private var runningLanguageID: String?
  private var audioSource: AudioCapturing?
  private var recognizer: SpeechRecognizing?
  private var startupTask: Task<Void, Never>?
  private var audioTask: Task<Void, Never>?
  private var updatesTask: Task<Void, Never>?
  private var tapRetryCount = 0
  private var didFallbackToTap = false

  private(set) var latestSourceText = ""
  private(set) var lastFailure: String?
  private(set) var fallbackNotice: String?
  private(set) var usesFileAudio = false
  private(set) var blockedByAnotherPlayer = false
  var onSourceText: ((String, Bool, Double?) -> Void)?

  init(player: PlayerCore,
       sourceFactory: SourceFactory? = nil,
       recognizerFactory: (() -> SpeechRecognizing)? = nil) {
    self.player = player
    self.sourceFactory = sourceFactory
    self.recognizerFactory = recognizerFactory
    observePreferences()
    observePlayer()
  }

  deinit {
    // No notification/player access here: the owning PlayerCore may already be
    // deallocating. Release the independent resources directly.
    generation += 1
    startupTask?.cancel()
    audioTask?.cancel()
    updatesTask?.cancel()
    recognizer?.cancel()
    audioSource?.stop()
  }

  var isRunning: Bool {
    recognizer != nil
  }

  // MARK: - Observation

  private func observePreferences() {
    preferences.addAll([
      .liveTranslationEnabled,
      .liveTranslationTarget,
      .liveTranslationWatchedLanguages,
      .liveTranslationAutoDownload,
    ]) { [weak self] _ in
      self?.refresh()
    }
  }

  private func observePlayer() {
    player.observe(.iinaFileLoaded) { [weak self] _ in self?.restart() }
    player.observe(.iinaPlaybackStarted) { [weak self] _ in self?.refresh() }
    player.observe(.iinaLiveTranslationLanguageChanged) { [weak self] _ in self?.refresh() }
    player.observe(.iinaPauseChanged) { [weak self] _ in self?.refresh() }
    player.observe(.iinaMuteChanged) { [weak self] _ in self?.restart() }
    player.observe(.iinaSpeedChanged) { [weak self] _ in
      guard let self, self.audioSource is FileAudioSource else { return }
      self.restart()
    }
    player.observe(.iinaPlaybackRestarted) { [weak self] _ in self?.restart() }
    player.observe(.iinaSeekStarted) { [weak self] _ in self?.stop() }
    player.observeGlobal(.iinaMainWindowChanged) { [weak self] _ in self?.refresh() }
    player.observeGlobal(.iinaLiveTranslationSpeechModelInstalled) { [weak self] _ in
      self?.refresh()
    }
    player.observeGlobal(.iinaAudiblePlayersChanged) { [weak self] _ in
      self?.refresh()
    }
    player.observe(.iinaTracklistChanged) { [weak self] _ in self?.refresh() }
    player.observe(.iinaAIDChanged) { [weak self] _ in
      guard let self else { return }
      if self.audioSource is FileAudioSource {
        self.restart()
      } else {
        self.refresh()
      }
    }
    player.observe(.iinaSIDChanged) { [weak self] _ in self?.refresh() }
    player.observe(.iinaSubVisibilityChanged) { [weak self] _ in self?.refresh() }
    player.observe(.iinaPlayerStopped) { [weak self] _ in self?.stop() }
    player.observe(.iinaPlayerShutdown) { [weak self] _ in self?.stop() }
  }

  // MARK: - Public control

  func stop() {
    runOnMain { [weak self] in
      self?.stopInternal()
    }
  }

  // MARK: - Lifecycle

  private func restart() {
    runOnMain { [weak self] in
      guard let self else { return }
      self.stopInternal()
      self.refresh()
    }
  }

  private func refresh() {
    runOnMain { [weak self] in
      guard let self else { return }
      let blocked = PlayerCore.hasOtherAudiblePlayer(than: self.player)
      if blocked != self.blockedByAnotherPlayer {
        self.blockedByAnotherPlayer = blocked
        self.player.postNotification(.iinaLiveTranslationSourceTextChanged)
      }
      guard !blocked else {
        if self.isRunning {
          self.stopInternal()
          // Clear any caption produced from audio that may now be mixed with
          // the other player's speech.
          self.player.postNotification(.iinaLiveTranslationSessionRestarted)
        }
        return
      }
      guard self.shouldRun else {
        self.stopInternal()
        return
      }
      guard let language = self.player.liveTranslationLanguage.resolvedLanguage,
            !self.player.liveTranslationLanguage.shouldSkip else {
        self.stopInternal()
        return
      }
      if self.isRunning, self.runningLanguageID == language.id {
        return
      }
      self.start(for: language)
    }
  }

  private var shouldRun: Bool {
    guard LiveTranslationPreferences.enabled,
          player.info.state == .playing,
          !player.info.isSeeking,
          player == PlayerCore.lastActive,
          player.info.currentURL != nil else {
      return false
    }
    return !LiveTranslationStatus.textSubtitleActive(for: player)
  }

  private func start(for language: LiveTranslationLanguage,
                     tapRetry: Int = 0) {
    stopInternal()
    setFailure(nil)
    setFallbackNotice(nil)
    generation += 1
    let generation = generation
    runningLanguageID = language.id
    tapRetryCount = tapRetry
    didFallbackToTap = false
    let url = player.info.currentURL
    player.postNotification(.iinaLiveTranslationSessionRestarted)

    // A muted player feeds the process tap digital silence, which would look
    // like a denied permission. Local files can still be decoded; other
    // sources have no captions while muted.
    let muted = player.info.isMuted
    if muted, url?.isFileURL != true {
      setFailure(NSLocalizedString(
        "Live translation cannot listen while playback is muted.",
        comment: "Live translation status"))
      runningLanguageID = nil
      return
    }

    startupTask = Task { @MainActor [weak self] in
      guard let self else { return }
      switch await self.speechModelReadiness(for: language) {
      case .ready:
        break
      case .downloading(let message):
        guard generation == self.generation, !Task.isCancelled else { return }
        self.setFailure(message)
        self.runningLanguageID = nil
        // The download may have been started by another app or Settings.
        // Re-check while this player is still the active one.
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(5))
          guard let self, generation == self.generation,
                self.player.info.state == .playing else { return }
          self.refresh()
        }
        return
      case .failure(let message):
        guard generation == self.generation, !Task.isCancelled else { return }
        self.setFailure(message)
        self.runningLanguageID = nil
        return
      }
      guard generation == self.generation, !Task.isCancelled else { return }

      let recognizer: SpeechRecognizing = self.recognizerFactory?()
        ?? SpeechAnalyzerSession()
      do {
        try await recognizer.start(
          language: language, audioFormat: Self.preferredFormat)
      } catch {
        guard generation == self.generation, !Task.isCancelled else { return }
        Logger.log("Live translation speech start failed: \(error.localizedDescription)",
                   level: .debug)
        self.setFailure(error.localizedDescription)
        self.runningLanguageID = nil
        return
      }
      guard generation == self.generation, !Task.isCancelled else {
        recognizer.cancel()
        return
      }
      self.recognizer = recognizer
      self.updatesTask = Task { [weak self] in
        for await update in recognizer.updates {
          guard !Task.isCancelled else { return }
          await MainActor.run {
            self?.handle(update)
          }
        }
        await MainActor.run {
          self?.speechUpdatesEnded(recognizer: recognizer,
                                   generation: generation)
        }
      }

      do {
        // The playhead must be sampled after model/recognizer startup: those
        // waits can take seconds while playback continues.
        let position = self.player.info.videoPosition?.second ?? 0
        let factory = self.sourceFactory ?? { url, position, muted, rate in
          try await self.makeSource(
            url: url, position: position, muted: muted, rate: rate)
        }
        let (source, frames, notice) = try await factory(
          url, position, muted, self.player.info.playSpeed)
        guard generation == self.generation else {
          source.stop()
          recognizer.cancel()
          return
        }
        self.audioSource = source
        self.usesFileAudio = source is FileAudioSource
        self.setFallbackNotice(notice)
        self.startFeeding(
          frames: frames, source: source, recognizer: recognizer,
          generation: generation)
        Logger.log("Live translation audio started", level: .debug)
      } catch {
        guard generation == self.generation, !Task.isCancelled else { return }
        Logger.log("Live translation audio failed: \(error.localizedDescription)",
                   level: .debug)
        self.setFailure(String(format: NSLocalizedString(
          "Audio capture failed: %@", comment: "Live translation status"),
          error.localizedDescription))
        recognizer.cancel()
        self.stopInternal()
      }
    }
  }

  private func speechUpdatesEnded(recognizer: SpeechRecognizing,
                                  generation: Int) {
    guard generation == self.generation else { return }
    switch recognizer.state {
    case .failed(let message):
      setFailure(message)
      stopInternal()
    case .running, .preparing:
      setFailure(NSLocalizedString(
        "Speech recognition stopped.", comment: "Live translation status"))
      stopInternal()
    case .idle, .finished:
      break
    }
  }

  private var selectedAudioTrackIndex: Int {
    guard let aid = player.info.aid,
          let index = player.info.audioTracks.firstIndex(where: { $0.id == aid }) else {
      return 0
    }
    return index
  }

  private var selectedTrackLanguage: String? {
    player.info.currentTrack(.audio)?.lang
  }

  /// The file that actually carries the selected audio. An external audio
  /// track has its own URL; the main file's ordinal means nothing there.
  private var selectedFile: (url: URL, trackIndex: Int)? {
    guard let track = player.info.currentTrack(.audio) else {
      guard let url = player.info.currentURL else { return nil }
      return (url, selectedAudioTrackIndex)
    }
    if let external = track.externalFilename, !external.isEmpty {
      guard FileManager.default.fileExists(atPath: external) else { return nil }
      return (URL(fileURLWithPath: external), 0)
    }
    guard let url = player.info.currentURL else { return nil }
    return (url, selectedAudioTrackIndex)
  }

  private var externalAudioMissing: Bool {
    guard let track = player.info.currentTrack(.audio),
          let external = track.externalFilename, !external.isEmpty else {
      return false
    }
    return !FileManager.default.fileExists(atPath: external)
  }

  @MainActor
  private func makeSource(
    url: URL?, position: TimeInterval, muted: Bool, rate: Double
  ) async throws -> (AudioCapturing, AsyncStream<AudioFrame>, String?) {
    #if DEBUG
    // The tap needs an attended TCC grant. Debug builds can force the file
    // path so the ASR pipeline can be tested without a system prompt.
    if ProcessInfo.processInfo.environment["UNIPLAYER_LIVE_TRANSLATION_FILE_AUDIO"] == "1",
       let url, url.isFileURL {
      let file = FileAudioSource(
        url: url, targetFormat: Self.preferredFormat,
        trackIndex: selectedAudioTrackIndex,
        languageHint: selectedTrackLanguage)
      let frames = try await file.start(at: position, rate: rate)
      return (file, frames, nil)
    }
    #endif

    // Local files are decoded directly: it follows the selected track (even an
    // external one) and cannot mix in another player window's audio. Formats
    // AVFoundation cannot decode fall back to the process tap below.
    if let url, url.isFileURL {
      if externalAudioMissing {
        throw AudioCaptureError.readerFailed(NSLocalizedString(
          "The selected external audio track could not be found.",
          comment: "Live translation audio error"))
      }
      if let file = selectedFile {
        do {
          let source = FileAudioSource(
            url: file.url, targetFormat: Self.preferredFormat,
            trackIndex: file.trackIndex,
            languageHint: selectedTrackLanguage)
          let frames = try await source.start(at: position, rate: rate)
          return (source, frames, muted ? NSLocalizedString(
            "Playback is muted; translating from the file audio track.",
            comment: "Live translation status") : nil)
        } catch {
          guard !muted else { throw error }
          Logger.log(
            "Live translation file decode failed; falling back to the process tap: \(error.localizedDescription)",
            level: .debug)
        }
      }
    }

    let tap = AudioTapSource()
    let frames = try await tap.start()
    return (tap, frames, nil)
  }

  private func startFeeding(frames: AsyncStream<AudioFrame>,
                            source: AudioCapturing,
                            recognizer: SpeechRecognizing,
                            generation: Int) {
    audioTask?.cancel()
    audioTask = Task.detached(priority: .userInitiated) { [weak self] in
      var delivered = 0
      var feedFailure: String?
      for await frame in frames {
        guard !Task.isCancelled else { break }
        if delivered == 0 {
          Logger.log("Live translation first audio frame: \(frame.buffer.format)",
                     level: .debug)
        }
        delivered += 1
        do {
          try recognizer.feed(frame.buffer, at: frame.time)
        } catch {
          feedFailure = error.localizedDescription
          Logger.log("Live translation feed failed: \(error.localizedDescription)",
                     level: .debug)
          break
        }
      }
      guard !Task.isCancelled else { return }
      Logger.log("Live translation audio stream ended after \(delivered) frames",
                 level: .debug)
      await MainActor.run {
        self?.audioEnded(
          source: source, generation: generation, feedFailure: feedFailure)
      }
    }
  }

  private func audioEnded(source: AudioCapturing, generation: Int,
                          feedFailure: String? = nil) {
    guard generation == self.generation else { return }
    if let feedFailure {
      setFailure(String(format: NSLocalizedString(
        "Speech recognition failed: %@", comment: "Live translation status"),
        feedFailure))
      stopInternal()
      return
    }
    Logger.log("Live translation audio ended with state \(source.state)",
               level: .debug)

    // A decoder failure after start is different from a start failure: the
    // file played, but AVFoundation could not decode it. Try the process tap
    // once, as the startup path does.
    if source is FileAudioSource, case .failed = source.state,
       player.info.currentURL?.isFileURL == true, !player.info.isMuted,
       !didFallbackToTap, let recognizer {
      didFallbackToTap = true
      Task { @MainActor [weak self] in
        guard let self, generation == self.generation else { return }
        do {
          let tap = AudioTapSource()
          let frames = try await tap.start()
          guard generation == self.generation else {
            tap.stop()
            return
          }
          self.audioSource = tap
          self.usesFileAudio = false
          self.startFeeding(
            frames: frames, source: tap, recognizer: recognizer,
            generation: generation)
          Logger.log("Live translation switched to the process tap after a decode failure",
                     level: .debug)
        } catch {
          guard generation == self.generation else { return }
          self.setFailure(String(format: NSLocalizedString(
            "Audio capture failed: %@", comment: "Live translation status"),
            error.localizedDescription))
          self.stopInternal()
        }
      }
      return
    }
    if source.state == .permissionDenied, let recognizer {
      if let file = selectedFile, file.url.isFileURL {
        let position = player.info.videoPosition?.second ?? 0
        Task { @MainActor [weak self] in
          guard let self, generation == self.generation else { return }
          do {
            let source = FileAudioSource(
              url: file.url, targetFormat: Self.preferredFormat,
              trackIndex: file.trackIndex,
              languageHint: self.selectedTrackLanguage)
            let frames = try await source.start(
              at: position, rate: self.player.info.playSpeed)
            guard generation == self.generation else {
              source.stop()
              return
            }
            self.audioSource = source
            self.usesFileAudio = true
            self.startFeeding(
              frames: frames, source: source, recognizer: recognizer,
              generation: generation)
            self.setFallbackNotice(NSLocalizedString(
              "System audio was unavailable; translating from the file audio track.",
              comment: "Live translation status"))
            Logger.log("Live translation fell back to the file audio source",
                       level: .debug)
          } catch {
            guard generation == self.generation else { return }
            self.setFailure(String(format: NSLocalizedString(
              "Audio capture failed: %@", comment: "Live translation status"),
              error.localizedDescription))
            Logger.log("Live translation file fallback failed: \(error.localizedDescription)",
                       level: .debug)
            self.stopInternal()
          }
        }
        return
      }

      // A silent opening is not proof of a denied grant. Re-probe while the
      // player is still active: quickly at first for a real denial, then every
      // 30 s so a long silent intro can still reach its speech.
      if let language = player.liveTranslationLanguage.resolvedLanguage,
         !player.liveTranslationLanguage.shouldSkip {
        tapRetryCount += 1
        let retry = tapRetryCount
        let delay = retry <= 3 ? 5 : 30
        Logger.log(
          "Live translation re-probing system audio (attempt \(retry))",
          level: .debug)
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(delay))
          guard let self, generation == self.generation else { return }
          self.start(for: language, tapRetry: retry)
        }
        return
      }
    }

    // A file source reaches EOF as soon as AVFoundation has decoded it. Flush
    // the analyzer so it can publish the final results instead of tearing the
    // session down mid-analysis.
    if source is FileAudioSource, source.state == .idle, let recognizer {
      Task { @MainActor in
        do {
          try await recognizer.flush()
        } catch {
          Logger.log("Live translation ASR flush failed: \(error.localizedDescription)",
                     level: .debug)
        }
      }
      return
    }
    switch source.state {
    case .failed(let message):
      setFailure(String(format: NSLocalizedString(
        "Audio capture failed: %@", comment: "Live translation status"), message))
    case .idle:
      setFailure(NSLocalizedString(
        "Audio capture stopped.", comment: "Live translation status"))
    case .starting, .running, .permissionDenied:
      break
    }
    stopInternal()
  }

  private func handle(_ update: SpeechRecognitionUpdate) {
    latestSourceText = update.text
    let confidence = update.confidence.map { String(format: "%.2f", $0) } ?? "n/a"
    Logger.log(
      "Live translation ASR \(update.isFinal ? "final" : "volatile") "
        + "(\(confidence)): \(update.text)",
      level: .debug)
    onSourceText?(update.text, update.isFinal, update.confidence)
    player.postNotification(.iinaLiveTranslationSourceTextChanged)
    if update.isFinal {
      player.liveTranslationLanguage.considerFinalText(update.text)
    }
  }

  private func stopInternal() {
    generation += 1
    startupTask?.cancel()
    startupTask = nil
    audioTask?.cancel()
    audioTask = nil
    updatesTask?.cancel()
    updatesTask = nil
    recognizer?.cancel()
    recognizer = nil
    audioSource?.stop()
    audioSource = nil
    usesFileAudio = false
    runningLanguageID = nil
    if !latestSourceText.isEmpty {
      latestSourceText = ""
      player.postNotification(.iinaLiveTranslationSourceTextChanged)
    }
  }

  private enum SpeechModelReadiness {
    case ready
    case downloading(String)
    case failure(String)
  }

  /// Returns the readiness of the speech model. The caller owns the generation
  /// check and the status update, so a superseded startup cannot overwrite a
  /// newer session's state.
  private func speechModelReadiness(
    for language: LiveTranslationLanguage
  ) async -> SpeechModelReadiness {
    switch await speechInventory.status(for: language) {
    case .installed:
      return .ready
    case .available:
      guard LiveTranslationPreferences.autoDownload else {
        Logger.log("Live translation speech model missing for \(language.id); auto-download is off",
                   level: .debug)
        return .failure(String(format: NSLocalizedString(
          "The %@ speech model is not installed. Download it in Live Translation settings.",
          comment: "Live translation status"), language.displayName))
      }
      do {
        try await speechInventory.install(language)
        return .ready
      } catch {
        Logger.log("Live translation speech model install failed: \(error.localizedDescription)",
                   level: .debug)
        return .failure(String(format: NSLocalizedString(
          "The %@ speech model could not be installed.",
          comment: "Live translation status"), language.displayName))
      }
    case .downloading:
      return .downloading(String(format: NSLocalizedString(
        "The %@ speech model is still downloading.",
        comment: "Live translation status"), language.displayName))
    case .unsupported:
      return .failure(String(format: NSLocalizedString(
        "Speech recognition does not support %@.",
        comment: "Live translation status"), language.displayName))
    case .failed, .checking:
      return .failure(String(format: NSLocalizedString(
        "The %@ speech model is unavailable.",
        comment: "Live translation status"), language.displayName))
    }
  }

  private func setFailure(_ message: String?) {
    let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
    guard lastFailure != value else { return }
    lastFailure = value
    player.postNotification(.iinaLiveTranslationSourceTextChanged)
  }

  private func setFallbackNotice(_ message: String?) {
    let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
    guard fallbackNotice != value else { return }
    fallbackNotice = value
    player.postNotification(.iinaLiveTranslationSourceTextChanged)
  }

  private func runOnMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }
}
