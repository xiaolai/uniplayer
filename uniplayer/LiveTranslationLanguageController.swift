//
//  LiveTranslationLanguageController.swift
//  uniplayer
//
//  Resolves the spoken language once per show and remembers the answer.
//  It owns no audio pipeline yet; later stages read `resolvedLanguage` to
//  choose the speech locale and translation pair.
//

import Cocoa

final class LiveTranslationLanguageController {
  private unowned let player: PlayerCore
  private let session: LiveTranslationLanguageSession
  private let prompt: LiveTranslationLanguagePrompting
  private let preferences = Preference.Observer()

  private var task: Task<Void, Never>?
  private var generation = 0
  private var lidPhrases: [String] = []
  private var lidAttempted = false
  private var lidConcluded = false
  private var lidShowKey: String?
  private var activationObserver: NSObjectProtocol?

  init(player: PlayerCore,
       store: ShowLanguageStoring = LiveTranslationShowLanguageStore.shared,
       speechSupport: SpeechLocaleSupporting = SystemSpeechModelInventory()) {
    self.player = player
    self.session = LiveTranslationLanguageSession(
      resolver: LiveTranslationLanguageResolver(speechSupport: speechSupport),
      store: store)
    self.prompt = LiveTranslationLanguagePrompt(player: player)
    observePreferences()
    observePlayer()
    // A prompt that could not be shown while the app was inactive is retried
    // as soon as the app becomes active again.
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil, queue: .main) { [weak self] _ in
        self?.refresh()
      }
  }

  deinit {
    task?.cancel()
    if let activationObserver {
      NotificationCenter.default.removeObserver(activationObserver)
    }
  }

  // MARK: - Public state

  var resolution: LiveTranslationLanguageResolution? {
    session.resolution
  }

  var resolvedLanguage: LiveTranslationLanguage? {
    session.resolvedLanguage
  }

  var shouldSkip: Bool {
    session.shouldSkip
  }

  var isTentative: Bool {
    session.isTentative && !lidConcluded
  }

  var overrideLanguageID: String? {
    session.overrideLanguageID
  }

  /// Stores a per-show choice and resolves again. Passing `nil` clears it.
  func setOverride(_ language: LiveTranslationLanguage?) {
    runOnMain { [weak self] in
      guard let self else { return }
      let url = self.player.info.currentURL
      let metadata = url.map { LibraryMetadata.parse(fileName: $0.lastPathComponent) }
      self.session.setOverride(language, for: url, metadata: metadata)
      self.refresh()
    }
  }

  /// Confirms a watched-list guess from the first finalized phrases. This is
  /// the only LID run: it happens once per show, never per utterance, and it
  /// never overrides a tag or an explicit choice.
  func considerFinalText(_ text: String) {
    runOnMain { [weak self] in
      guard let self else { return }
      let url = self.player.info.currentURL
      let metadata = url.map { LibraryMetadata.parse(fileName: $0.lastPathComponent) }
      let key = LiveTranslationShowIdentity.key(url: url, metadata: metadata)
      if self.lidShowKey != key {
        self.lidShowKey = key
        self.lidPhrases = []
        self.lidAttempted = false
        self.lidConcluded = false
      }
      guard !self.lidAttempted else { return }

      let current: LiveTranslationLanguage
      let candidates: [LiveTranslationLanguage]
      switch self.resolution {
      case .resolved(let language, .watchedList)?:
        current = self.session.tentativeLanguage ?? language
        candidates = LiveTranslationPreferences.watchedLanguages
      case .needsChoice(let list)?:
        guard let tentative = self.session.tentativeLanguage else { return }
        current = tentative
        candidates = list
      default:
        return
      }

      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      self.lidPhrases.append(trimmed)
      guard self.lidPhrases.count >= LiveTranslationLanguageTextIdentifier.maximumPhrases else {
        return
      }
      self.lidAttempted = true
      let identified = LiveTranslationLanguageTextIdentifier.language(
        for: self.lidPhrases)
      if identified?.id == current.id {
        // Agreement finalizes the tentative language: LID heard the same
        // language the tentative recognizer was configured for.
        self.lidConcluded = true
        self.session.setOverride(current, for: url, metadata: metadata)
        self.refresh()
        return
      }
      if let confirmed = LiveTranslationLanguageTextIdentifier.confirmedLanguage(
        for: self.lidPhrases, current: current, watched: candidates) {
        self.lidConcluded = true
        Logger.log(
          "Live translation language confirmed as \(confirmed.id) from speech",
          level: .debug)
        self.session.setOverride(confirmed, for: url, metadata: metadata)
        self.refresh()
        return
      }
      // Inconclusive: keep the tentative language for this session, stop
      // claiming to be "checking", and let the menu be the explicit choice.
      self.lidConcluded = true
      Logger.log("Live translation language could not be confirmed from speech",
                 level: .debug)
      self.player.postNotification(.iinaLiveTranslationLanguageChanged)
    }
  }

  // MARK: - Observation

  private func observePreferences() {
    preferences.addAll([
      .liveTranslationEnabled,
      .liveTranslationTarget,
      .liveTranslationWatchedLanguages,
    ]) { [weak self] _ in
      self?.refresh()
    }
  }

  private func observePlayer() {
    player.observe(.iinaFileLoaded) { [weak self] _ in self?.refresh() }
    player.observe(.iinaTracklistChanged) { [weak self] _ in self?.refresh() }
    player.observe(.iinaAIDChanged) { [weak self] _ in self?.refresh() }
    player.observeGlobal(.iinaMainWindowChanged) { [weak self] _ in self?.refresh() }
    player.observe(.iinaPlayerStopped) { [weak self] _ in self?.clear() }
    player.observe(.iinaPlayerShutdown) { [weak self] _ in self?.clear() }
  }

  private func clear() {
    runOnMain { [weak self] in
      guard let self else { return }
      self.generation += 1
      self.task?.cancel()
      self.task = nil
      self.session.clear()
      self.lidAttempted = false
      self.lidConcluded = false
      self.lidPhrases = []
      self.lidShowKey = nil
      self.player.postNotification(.iinaLiveTranslationLanguageChanged)
    }
  }

  private func refresh() {
    runOnMain { [weak self] in
      guard let self else { return }
      self.generation += 1
      let generation = self.generation
      self.task?.cancel()
      self.session.invalidate()

      guard LiveTranslationPreferences.enabled,
            self.player.info.state.active,
            let url = self.player.info.currentURL else {
        self.session.clear()
        self.player.postNotification(.iinaLiveTranslationLanguageChanged)
        return
      }

      let metadata = LibraryMetadata.parse(fileName: url.lastPathComponent)
      let trackLanguage = self.player.info.currentTrack(.audio)?.lang
      let watched = LiveTranslationPreferences.watchedLanguages
      let target = LiveTranslationPreferences.target

      self.task = Task { @MainActor [weak self] in
        guard let self else { return }
        let result = await self.session.resolve(
          url: url,
          metadata: metadata,
          trackLanguage: trackLanguage,
          watched: watched,
          target: target,
          prompt: self.prompt)
        guard generation == self.generation else { return }
        Logger.log("Live translation language: \(String(describing: result))", level: .debug)
        self.player.postNotification(.iinaLiveTranslationLanguageChanged)
      }
    }
  }

  private func runOnMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }
}

/// The only user-facing prompt in this stage: choose the spoken language for
/// an untagged file. The answer is remembered by the session for this show.
final class LiveTranslationLanguagePrompt: LiveTranslationLanguagePrompting {
  private weak var player: PlayerCore?

  init(player: PlayerCore) {
    self.player = player
  }

  func chooseLanguage(candidates: [LiveTranslationLanguage],
                      showTitle: String?) async -> LiveTranslationLanguagePromptOutcome {
    await MainActor.run { [weak self] () -> LiveTranslationLanguagePromptOutcome in
      guard let self, let player = self.player, player.info.state.active,
            NSApp.isActive,
            player == PlayerCore.lastActive,
            !candidates.isEmpty else { return .unavailable }

      let alert = NSAlert()
      alert.alertStyle = .informational
      alert.messageText = NSLocalizedString(
        "Which language is spoken?", comment: "Live translation language prompt")
      if let showTitle, !showTitle.isEmpty {
        alert.informativeText = String(
          format: NSLocalizedString(
            "Choose the spoken language for %@. UniPlayer remembers it for this show.",
            comment: "Live translation language prompt"),
          showTitle)
      } else {
        alert.informativeText = NSLocalizedString(
          "Choose the spoken language. UniPlayer remembers it for this show.",
          comment: "Live translation language prompt")
      }

      let popup = NSPopUpButton(
        frame: NSRect(x: 0, y: 0,
                      width: Tokens.Size.n240, height: Tokens.Size.n25),
        pullsDown: false)
      for language in candidates {
        popup.addItem(withTitle: language.displayName)
        popup.lastItem?.representedObject = language.id
      }
      popup.setAccessibilityLabel(NSLocalizedString(
        "Spoken Language", comment: "Live translation language prompt"))
      alert.accessoryView = popup

      alert.addButton(withTitle: NSLocalizedString(
        "Use Language", comment: "Live translation language prompt"))
      alert.addButton(withTitle: NSLocalizedString(
        "Not Now", comment: "Live translation language prompt"))

      let response = alert.runModal()
      guard response == .alertFirstButtonReturn else {
        return .declined
      }
      guard player.info.state.active,
            let id = popup.selectedItem?.representedObject as? String,
            let language = LiveTranslationLanguages.language(for: id) else {
        return .unavailable
      }
      return .chosen(language)
    }
  }
}
