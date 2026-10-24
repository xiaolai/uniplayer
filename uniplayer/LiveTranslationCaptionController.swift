//
//  LiveTranslationCaptionController.swift
//  uniplayer
//
//  Commits stable ASR prefixes, translates only the new suffixes, and draws a
//  target-only rolling caption. Source text is shown only when the explicit
//  verification setting is on.
//
//  Debug logs include recognized and translated text so evidence runs can be
//  checked; they are written to the local log only and never leave the Mac.
//

import Cocoa

final class LiveTranslationCaptionController {
  private unowned let player: PlayerCore
  private let overlay: CaptionOverlayController
  private let router: LiveTranslationRouter
  private let preferences = Preference.Observer()
  private let glossaryStore = LiveTranslationGlossaryStore.shared
  private let verifier = CaptionVerifier()
  private lazy var repairCoordinator = LiveTranslationRepairCoordinator(
    verifier: verifier,
    repairer: AssistantCaptionRepairer(),
    isEnabled: { LiveTranslationPreferences.repair })

  private struct PendingChunk {
    let text: String
    let confidence: Double?
    let isFinal: Bool
    let enqueuedAt: Date
    var replaceLast = false
    var replaceAll = false
  }

  private static let maximumPendingChunks = 8
  private static let maximumPendingCharacters = 2_000
  private static let maximumChunkAge: TimeInterval = 15
  private static let maximumFinalAge: TimeInterval = 30

  /// Everything a correction dialog must remember while the alert is open.
  struct CorrectionSnapshot {
    let source: String
    let target: String
    let lineNumber: Int
    let showKey: String
    let sourceLanguageID: String
    let targetLanguageID: String
  }

  private struct CaptionRecord {
    let source: String
    let target: String
    let confidence: Double?
    let lineNumber: Int
  }

  private var committer = StablePrefixCommitter()
  private var pendingChunks: [PendingChunk] = []
  private var translatedLines: [String] = []
  private var sourceLine = ""
  private var lastIngestAt = Date.distantPast
  private var lastDisplayAt = Date.distantPast
  private var currentSourceID: String?
  private var currentTargetID: String?
  private var preparedPair: (source: String, target: String)?
  private var showKey = ""
  private var glossary: [LiveTranslationGlossaryTerm] = []
  private var lastRecord: CaptionRecord?
  private var lineCounter = 0
  private var pipelineGeneration = 0
  private var translationTask: Task<Void, Never>?
  private var repairTask: Task<Void, Never>?
  private var tickTask: Task<Void, Never>?
  private var gapTask: Task<Void, Never>?
  private struct PendingRepair {
    let source: String
    let candidate: String
    let confidence: Double?
    let isFinal: Bool
    let lineNumber: Int
    let targetLanguage: String
  }

  private var aiDecisionPair: String?
  private var aiDecision = false
  private var queuedRepair: PendingRepair?
  private var packInstalledPending = false
  private var lastExpiredSource: String?

  private(set) var latestTargetText = ""
  private(set) var lastFailure: String?
  private(set) var isUsingAIProvider = false

  init(player: PlayerCore) {
    self.player = player
    self.overlay = CaptionOverlayController(
      player: player, overlayID: "1431198514")
    self.router = LiveTranslationRouter(
      onDevice: OnDeviceTranslationSession(),
      aiProvider: AssistantTranslationSession(),
      availability: SystemLiveTranslationAvailability(),
      fallback: { LiveTranslationPreferences.fallback })
    router.requestAIApproval = { [weak self] source, target in
      guard let self else { return false }
      return await self.requestAIProviderApproval(from: source, to: target)
    }
    router.autoDownload = { LiveTranslationPreferences.autoDownload }
    router.onMissingPack = { [weak self] source, target, _ in
      DispatchQueue.main.async {
        self?.requestPackDownload(source: source, target: target)
      }
    }
    observePreferences()
    observePlayer()
  }

  /// The final caption line, which is what the correction action edits. The
  /// overlay may show two lines; correcting both at once would duplicate text.
  var latestTargetLine: String { translatedLines.last ?? "" }

  deinit {
    translationTask?.cancel()
    repairTask?.cancel()
    tickTask?.cancel()
    gapTask?.cancel()
    router.cancel()
  }

  // MARK: - Input

  func ingest(_ text: String, isFinal: Bool, confidence: Double?) {
    runOnMain { [weak self] in
      guard let self else { return }
      guard LiveTranslationPreferences.enabled,
            self.player.info.state == .playing,
            !self.player.info.isSeeking,
            self.player == PlayerCore.lastActive,
            !LiveTranslationStatus.textSubtitleActive(for: self.player),
            let source = self.player.liveTranslationLanguage.resolvedLanguage,
            !self.player.liveTranslationLanguage.shouldSkip else {
        self.clear()
        return
      }
      let target = LiveTranslationPreferences.target
      guard source.id != target.id else {
        self.clear()
        return
      }
      self.verifier.setLanguages(source: source.id, target: target.id)
      if self.currentSourceID != source.id || self.currentTargetID != target.id {
        self.resetPipeline()
        self.currentSourceID = source.id
        self.currentTargetID = target.id
      }

      let url = self.player.info.currentURL
      let metadata = url.map { LibraryMetadata.parse(fileName: $0.lastPathComponent) }
      let key = LiveTranslationShowIdentity.key(url: url, metadata: metadata)
      if key != self.showKey {
        self.showKey = key
        self.glossary = self.glossaryStore.terms(
          for: key, sourceLanguageID: source.id, targetLanguageID: target.id)
      }

      self.lastIngestAt = Date()
      let normalized = SpeechTextNormalizer.normalize(text)
      if !normalized.isEmpty {
        self.sourceLine = normalized
      }
      // The display timer expired this exact sentence a moment ago; its final
      // arrived after the text was already translated. Do not translate and
      // display the same sentence twice.
      if isFinal, self.lastRecord == nil,
         normalized == self.lastExpiredSource {
        self.lastExpiredSource = nil
        self.scheduleTick()
        self.scheduleGapClear()
        return
      }
      if isFinal, !normalized.isEmpty,
         self.committer.finalDiverges(normalized) {
        _ = self.committer.ingest(normalized, isFinal: true)
        self.lastExpiredSource = nil
        self.enqueueReplacement(normalized, confidence: confidence)
      } else {
        let committed = self.committer.ingest(text, isFinal: isFinal)
        self.enqueue(committed, confidence: confidence, isFinal: isFinal)
        if isFinal, committed.isEmpty, let record = self.lastRecord {
          // The final confirms text that was already committed. No suffix
          // exists to translate, but the final confidence still deserves the
          // verification pass that volatile low-confidence lines skip.
          MainActor.assumeIsolated {
            self.scheduleRepair(
              source: record.source, candidate: record.target,
              confidence: confidence, isFinal: true,
              lineNumber: record.lineNumber,
              targetLanguage: target.displayName,
              generation: self.pipelineGeneration)
          }
        }
      }
      if !normalized.isEmpty, normalized != self.lastExpiredSource {
        self.lastExpiredSource = nil
      }
      self.scheduleTick()
      self.scheduleGapClear()
    }
  }

  // MARK: - Observation

  private func observePreferences() {
    preferences.addAll([
      .liveTranslationEnabled,
      .liveTranslationTarget,
      .liveTranslationShowSource,
      .liveTranslationPreferredStrategy,
      .liveTranslationFallback,
    ]) { [weak self] _ in
      self?.clear()
      self?.currentSourceID = nil
      self?.currentTargetID = nil
    }
    preferences.addAll([.liveTranslationRepair]) { [weak self] _ in
      guard let self, !LiveTranslationPreferences.repair else { return }
      self.queuedRepair = nil
      self.repairTask?.cancel()
      self.repairTask = nil
    }
  }

  private func observePlayer() {
    player.observe(.iinaPauseChanged) { [weak self] _ in self?.clear() }
    player.observe(.iinaFileLoaded) { [weak self] _ in self?.clear() }
    player.observe(.iinaPlaybackRestarted) { [weak self] _ in self?.clear() }
    player.observe(.iinaSeekStarted) { [weak self] _ in self?.clear() }
    player.observe(.iinaLiveTranslationSessionRestarted) { [weak self] _ in
      self?.resetPipeline()
      self?.currentSourceID = nil
      self?.currentTargetID = nil
    }
    player.observeGlobal(.iinaLiveTranslationPackInstalled) { [weak self] _ in
      guard let self else { return }
      guard self.translationTask == nil else {
        self.packInstalledPending = true
        return
      }
      self.invalidatePreparedRoute()
    }
    player.observe(.iinaPlayerStopped) { [weak self] _ in self?.clear() }
    player.observe(.iinaPlayerShutdown) { [weak self] _ in self?.clear() }
    player.observe(.iinaLiveTranslationLanguageChanged) { [weak self] _ in
      self?.clear()
      self?.currentSourceID = nil
      self?.currentTargetID = nil
    }
    player.observe(.iinaSIDChanged) { [weak self] _ in
      guard let self else { return }
      if LiveTranslationStatus.textSubtitleActive(for: self.player) {
        self.clear()
      }
    }
    player.observe(.iinaSubVisibilityChanged) { [weak self] _ in
      guard let self else { return }
      if LiveTranslationStatus.textSubtitleActive(for: self.player) {
        self.clear()
      }
    }
  }

  // MARK: - Translation

  private func enqueue(_ chunks: [String], confidence: Double?,
                       isFinal: Bool) {
    guard !chunks.isEmpty else { return }
    let now = Date()
    for chunk in chunks {
      let text = SpeechTextNormalizer.normalize(chunk)
      guard !text.isEmpty else { continue }
      Logger.log("Live translation committed: \(text)", level: .debug)
      pendingChunks.append(PendingChunk(
        text: text, confidence: confidence, isFinal: isFinal,
        enqueuedAt: now))
    }
    trimPendingChunks(now: now)
    startTranslationIfNeeded()
  }

  private func enqueueReplacement(_ text: String, confidence: Double?) {
    pendingChunks.append(PendingChunk(
      text: text, confidence: confidence, isFinal: true,
      enqueuedAt: Date(), replaceAll: true))
    trimPendingChunks(now: Date())
    startTranslationIfNeeded()
  }

  /// A real-time caption is useless once it describes speech that has moved
  /// on. Bound the queue by age, count and total text. Final results get a
  /// longer age budget, but a backlog of finalized speech is still dropped
  /// rather than concatenated forever.
  private func trimPendingChunks(now: Date) {
    var index = 0
    while index < pendingChunks.count {
      let chunk = pendingChunks[index]
      let limit = chunk.isFinal ? Self.maximumFinalAge : Self.maximumChunkAge
      if now.timeIntervalSince(chunk.enqueuedAt) > limit {
        Logger.log(
          "Live translation dropped a stale \(chunk.isFinal ? "final" : "queued") chunk: \(chunk.text)",
          level: .debug)
        pendingChunks.remove(at: index)
      } else {
        index += 1
      }
    }
    while pendingChunks.count > Self.maximumPendingChunks {
      if let index = pendingChunks.firstIndex(where: { !$0.isFinal }) {
        Logger.log(
          "Live translation dropped a queued chunk: \(pendingChunks[index].text)",
          level: .debug)
        pendingChunks.remove(at: index)
        continue
      }
      guard pendingChunks.count >= 2 else { break }
      let first = pendingChunks.removeFirst()
      let second = pendingChunks.removeFirst()
      let text = second.replaceAll
        ? second.text
        : first.text + " " + second.text
      let merged = PendingChunk(
        text: text,
        confidence: second.confidence, isFinal: true,
        // The older timestamp keeps the merged entry's age honest; it must not
        // look fresh because it absorbed a newer chunk.
        enqueuedAt: first.enqueuedAt,
        replaceAll: first.replaceAll || second.replaceAll
          || first.replaceLast || second.replaceLast)
      pendingChunks.insert(merged, at: 0)
      Logger.log("Live translation merged a final-caption backlog",
                 level: .debug)
    }
    var total = pendingChunks.reduce(0) { $0 + $1.text.count }
    while total > Self.maximumPendingCharacters, pendingChunks.count > 1 {
      let dropped = pendingChunks.removeFirst()
      total -= dropped.text.count
      Logger.log(
        "Live translation dropped the oldest caption from an overloaded queue: \(dropped.text)",
        level: .debug)
    }
    if pendingChunks.count == 1, let only = pendingChunks.first,
       only.text.count > Self.maximumPendingCharacters {
      let trimmed = String(only.text.suffix(Self.maximumPendingCharacters))
      pendingChunks[0] = PendingChunk(
        text: trimmed, confidence: only.confidence, isFinal: only.isFinal,
        enqueuedAt: only.enqueuedAt, replaceLast: only.replaceLast,
        replaceAll: only.replaceAll)
      Logger.log("Live translation truncated an oversized caption",
                 level: .debug)
    }
  }

  private func startTranslationIfNeeded() {
    guard translationTask == nil, !pendingChunks.isEmpty else { return }
    let generation = pipelineGeneration
    translationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        guard generation == self.pipelineGeneration,
              !self.pendingChunks.isEmpty else { break }
        if self.packInstalledPending {
          self.packInstalledPending = false
          self.invalidatePreparedRoute()
        }
        guard let source = self.player.liveTranslationLanguage.resolvedLanguage,
              !self.player.liveTranslationLanguage.shouldSkip else {
          self.pendingChunks.removeAll()
          break
        }
        let target = LiveTranslationPreferences.target
        self.trimPendingChunks(now: Date())
        guard !Task.isCancelled, generation == self.pipelineGeneration,
              !self.pendingChunks.isEmpty else { break }
        let chunk = self.pendingChunks.removeFirst()

        if !self.showKey.isEmpty,
           let exact = self.glossaryStore.correction(
             for: chunk.text, showKey: self.showKey,
             sourceLanguageID: source.id, targetLanguageID: target.id) {
          if Date().timeIntervalSince(chunk.enqueuedAt)
              <= Self.maximumFinalAge {
            self.appendTranslated(
              exact, source: chunk.text, confidence: chunk.confidence,
              replaceLast: chunk.replaceLast, replaceAll: chunk.replaceAll)
          }
          continue
        }

        guard await self.prepareIfNeeded(
          source: source, target: target, generation: generation) else {
          if generation == self.pipelineGeneration {
            self.pendingChunks.removeAll()
          }
          break
        }
        guard !Task.isCancelled, generation == self.pipelineGeneration else { break }

        do {
          let translated = try await self.router.translate(chunk.text)
          guard !Task.isCancelled, generation == self.pipelineGeneration else { break }
          // A translation that took long enough for the caption to expire must
          // not appear late over newer speech.
          guard Date().timeIntervalSince(chunk.enqueuedAt)
                  <= Self.maximumFinalAge else {
            Logger.log("Live translation dropped a late translation: \(chunk.text)",
                       level: .debug)
            continue
          }
          self.setFailure(nil)
          // Publish the first pass immediately; repair must never sit between
          // speech and a visible caption.
          guard let lineNumber = self.appendTranslated(
            translated, source: chunk.text, confidence: chunk.confidence,
            replaceLast: chunk.replaceLast, replaceAll: chunk.replaceAll) else {
            continue
          }
          self.scheduleRepair(
            source: chunk.text, candidate: translated,
            confidence: chunk.confidence, isFinal: chunk.isFinal,
            lineNumber: lineNumber, targetLanguage: target.displayName,
            generation: generation)
        } catch {
          guard generation == self.pipelineGeneration else { break }
          self.setFailure(error.localizedDescription)
          self.preparedPair = nil
          self.isUsingAIProvider = false
          self.router.cancel()
          Logger.log("Live translation failed: \(error.localizedDescription)",
                     level: .debug)
        }
      }
      if generation == self.pipelineGeneration {
        self.translationTask = nil
        if self.packInstalledPending {
          self.packInstalledPending = false
          self.invalidatePreparedRoute()
        }
      }
    }
  }

  /// A newly installed pack makes the current route stale. If a translation is
  /// running, the flag defers this until its loop ends.
  private func invalidatePreparedRoute() {
    preparedPair = nil
    isUsingAIProvider = false
    router.cancel()
  }

  @MainActor
  private func prepareIfNeeded(source: LiveTranslationLanguage,
                               target: LiveTranslationLanguage,
                               generation: Int) async -> Bool {
    if let preparedPair, preparedPair.source == source.id,
       preparedPair.target == target.id {
      return true
    }
    do {
      try await router.prepare(from: source, to: target)
      guard !Task.isCancelled, generation == pipelineGeneration else {
        return false
      }
      preparedPair = (source.id, target.id)
      isUsingAIProvider = router.currentRoute == .aiProvider
      setFailure(nil)
      return true
    } catch {
      guard !Task.isCancelled, generation == pipelineGeneration else {
        return false
      }
      isUsingAIProvider = false
      setFailure(error.localizedDescription)
      Logger.log("Live translation is unavailable: \(error.localizedDescription)",
                 level: .debug)
      return false
    }
  }

  private func requestPackDownload(source: LiveTranslationLanguage,
                                   target: LiveTranslationLanguage) {
    runOnMain { [weak self] in
      guard let self else { return }
      guard LiveTranslationPreferences.autoDownload else { return }
      SettingsWindow.default.showPage(identifier: "liveTranslation")
      let info: [String: String] = [
        LiveTranslationPackDownloadRequest.sourceKey: source.id,
        LiveTranslationPackDownloadRequest.targetKey: target.id,
      ]
      DispatchQueue.main.async {
        NotificationCenter.default.post(
          name: .iinaLiveTranslationPackDownloadRequested,
          object: nil, userInfo: info)
      }
    }
  }

  /// One decision per pair per session. Declining falls back to the missing
  /// pack message instead of asking again on every caption.
  @MainActor
  private func requestAIProviderApproval(
    from source: LiveTranslationLanguage,
    to target: LiveTranslationLanguage
  ) async -> Bool {
    let key = "\(source.id)->\(target.id)"
    if aiDecisionPair == key { return aiDecision }
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = NSLocalizedString(
      "Use the AI provider?", comment: "Live translation AI fallback prompt")
    alert.informativeText = String(format: NSLocalizedString(
      "%@ to %@ is not available on this Mac. Use the existing AI provider for this video?",
      comment: "Live translation AI fallback prompt"),
      source.displayName, target.displayName)
    alert.addButton(withTitle: NSLocalizedString(
      "Use AI Provider", comment: "Live translation AI fallback prompt"))
    alert.addButton(withTitle: NSLocalizedString(
      "Not Now", comment: "Live translation AI fallback prompt"))
    aiDecision = alert.runModal() == .alertFirstButtonReturn
    aiDecisionPair = key
    return aiDecision
  }

  private func setFailure(_ message: String?) {
    let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
    guard lastFailure != value else { return }
    lastFailure = value
    player.postNotification(.iinaLiveTranslationSourceTextChanged)
  }

  /// Every caption gets the cheap deterministic check. Repair itself is
  /// serialized: if one is in flight, the newest flagged caption waits in a
  /// single slot rather than being skipped unverified.
  @MainActor
  private func scheduleRepair(
    source: String, candidate: String, confidence: Double?, isFinal: Bool,
    lineNumber: Int?, targetLanguage: String, generation: Int
  ) {
    guard LiveTranslationPreferences.repair, let lineNumber else { return }
    let verification = repairCoordinator.verification(
      source: source, target: candidate,
      confidence: confidence, glossary: glossary)
    guard verification.requiresRepair,
          isFinal || verification.hasDeterministicFlag else { return }

    let request = PendingRepair(
      source: source, candidate: candidate, confidence: confidence,
      isFinal: isFinal, lineNumber: lineNumber,
      targetLanguage: targetLanguage)
    guard repairTask == nil else {
      queuedRepair = request
      return
    }
    startRepair(request, generation: generation)
  }

  @MainActor
  private func startRepair(_ request: PendingRepair, generation: Int) {
    repairTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let corrected = await self.repairCoordinator.repairIfNeeded(
        source: request.source, target: request.candidate,
        confidence: request.confidence, isFinal: request.isFinal,
        glossary: self.glossary, targetLanguage: request.targetLanguage)
      if Task.isCancelled { return }
      self.repairTask = nil
      if let corrected, LiveTranslationPreferences.repair,
         generation == self.pipelineGeneration,
         self.lastRecord?.lineNumber == request.lineNumber,
         let index = self.translatedLines.indices.last {
        let normalized = SpeechTextNormalizer.normalize(corrected)
        if !normalized.isEmpty {
          self.translatedLines[index] = normalized
          self.latestTargetText = self.translatedLines.joined(separator: "\n")
          if let record = self.lastRecord {
            self.lastRecord = CaptionRecord(
              source: record.source, target: normalized,
              confidence: record.confidence, lineNumber: record.lineNumber)
          }
          self.render(immediate: true)
        }
      }
      guard generation == self.pipelineGeneration,
            let queued = self.queuedRepair else { return }
      self.queuedRepair = nil
      self.startRepair(queued, generation: generation)
    }
  }

  @discardableResult
  private func appendTranslated(_ text: String, source: String,
                                confidence: Double?, replaceLast: Bool = false,
                                replaceAll: Bool = false) -> Int? {
    let normalized = SpeechTextNormalizer.normalize(text)
    guard !normalized.isEmpty else { return nil }
    if replaceAll {
      // The final result is the whole utterance; keeping an earlier chunk of
      // the same utterance beside it would display the text twice.
      translatedLines = [normalized]
    } else if replaceLast, !translatedLines.isEmpty {
      translatedLines[translatedLines.count - 1] = normalized
    } else {
      translatedLines.append(normalized)
    }
    if translatedLines.count > 2 {
      translatedLines.removeFirst(translatedLines.count - 2)
    }
    lineCounter += 1
    lastRecord = CaptionRecord(
      source: source, target: normalized,
      confidence: confidence, lineNumber: lineCounter)
    latestTargetText = translatedLines.joined(separator: "\n")
    if latestTargetText.count > 0 {
      Logger.log("Live translation caption: \(latestTargetText)", level: .debug)
    }
    lastDisplayAt = Date()
    render(immediate: replaceLast || replaceAll)
    scheduleGapClear()
    return lineCounter
  }

  /// Captures the caption the correction dialog is about, before playback can
  /// advance and replace it.
  func correctionSnapshot() -> CorrectionSnapshot? {
    guard let record = lastRecord, !showKey.isEmpty,
          let sourceID = currentSourceID
            ?? player.liveTranslationLanguage.resolvedLanguage?.id else {
      return nil
    }
    let targetID = currentTargetID
      ?? LiveTranslationPreferences.target.id
    guard sourceID != targetID else { return nil }
    return CorrectionSnapshot(
      source: record.source, target: record.target,
      lineNumber: record.lineNumber, showKey: showKey,
      sourceLanguageID: sourceID, targetLanguageID: targetID)
  }

  /// Stores the correction for the captured sentence even if playback has
  /// moved on, but updates the overlay only when that caption is still shown.
  func applyCorrection(_ corrected: String, to snapshot: CorrectionSnapshot) {
    runOnMain { [weak self] in
      guard let self else { return }
      let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      self.glossaryStore.setCorrection(
        source: snapshot.source, target: trimmed, showKey: snapshot.showKey,
        sourceLanguageID: snapshot.sourceLanguageID,
        targetLanguageID: snapshot.targetLanguageID)
      if self.showKey == snapshot.showKey,
         self.currentSourceID == snapshot.sourceLanguageID,
         self.currentTargetID == snapshot.targetLanguageID {
        self.glossary = self.glossaryStore.terms(
          for: snapshot.showKey,
          sourceLanguageID: snapshot.sourceLanguageID,
          targetLanguageID: snapshot.targetLanguageID)
      }
      guard self.lastRecord?.lineNumber == snapshot.lineNumber else { return }
      if let index = self.translatedLines.indices.last {
        self.translatedLines[index] = trimmed
      }
      self.latestTargetText = self.translatedLines.joined(separator: "\n")
      self.lineCounter += 1
      self.lastRecord = CaptionRecord(
        source: snapshot.source, target: trimmed,
        confidence: self.lastRecord?.confidence,
        lineNumber: self.lineCounter)
      self.render(immediate: true)
    }
  }

  private func render(immediate: Bool = false) {
    var lines: [String] = []
    if LiveTranslationPreferences.showSource, !sourceLine.isEmpty {
      lines.append(sourceLine)
      if let last = translatedLines.last {
        lines.append(last)
      }
    } else {
      lines.append(contentsOf: translatedLines)
    }
    let text = lines.joined(separator: "\n")
    guard !text.isEmpty else {
      overlay.clear()
      return
    }
    overlay.show(text: text, immediate: immediate)
  }

  // MARK: - Timing

  private func scheduleTick() {
    tickTask?.cancel()
    tickTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard let self, !Task.isCancelled else { return }
      self.enqueue(
        self.committer.tick(), confidence: nil, isFinal: false)
    }
  }

  private func scheduleGapClear() {
    gapTask?.cancel()
    gapTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard let self, !Task.isCancelled else { return }
      self.expireDisplay()
    }
  }

  /// A pause in speech expires the visible caption only. Canceling the
  /// translation or repair task here would discard a line that is still being
  /// produced, and erasing the AI decision would ask again on the next phrase.
  private func expireDisplay() {
    let activity = max(lastIngestAt, lastDisplayAt)
    guard Date().timeIntervalSince(activity) >= 3 else { return }
    lastExpiredSource = lastRecord?.source
    translatedLines.removeAll()
    sourceLine = ""
    latestTargetText = ""
    lastRecord = nil
    committer.reset()
    overlay.clear()
  }

  // MARK: - Clearing

  private func clear() {
    runOnMain { [weak self] in
      guard let self else { return }
      self.pipelineGeneration += 1
      self.translationTask?.cancel()
      self.translationTask = nil
      self.repairTask?.cancel()
      self.repairTask = nil
      self.tickTask?.cancel()
      self.tickTask = nil
      self.gapTask?.cancel()
      self.gapTask = nil
      self.router.cancel()
      self.preparedPair = nil
      self.pendingChunks.removeAll()
      self.translatedLines.removeAll()
      self.sourceLine = ""
      self.latestTargetText = ""
      self.isUsingAIProvider = false
      self.setFailure(nil)
      self.aiDecisionPair = nil
      self.queuedRepair = nil
      self.packInstalledPending = false
      self.lastExpiredSource = nil
      self.lastRecord = nil
      self.committer.reset()
      self.overlay.clear()
    }
  }

  private func resetPipeline() {
    pipelineGeneration += 1
    translationTask?.cancel()
    translationTask = nil
    repairTask?.cancel()
    repairTask = nil
    tickTask?.cancel()
    tickTask = nil
    gapTask?.cancel()
    gapTask = nil
    router.cancel()
    preparedPair = nil
    pendingChunks.removeAll()
    translatedLines.removeAll()
    sourceLine = ""
    latestTargetText = ""
    isUsingAIProvider = false
    setFailure(nil)
    aiDecisionPair = nil
    queuedRepair = nil
    packInstalledPending = false
    lastExpiredSource = nil
    lastRecord = nil
    glossary = []
    showKey = ""
    committer.reset()
    overlay.clear()
  }

  private func runOnMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }
}
