//
//  LiveTranslationPipelineTests.swift
//  UniPlayerTests
//

import AVFoundation
import Foundation
import XCTest
@testable import UniPlayer

@MainActor
final class LiveTranslationPipelineTests: XCTestCase {

  private final class FakeSpeechRecognizer: SpeechRecognizing {
    let updates: AsyncStream<SpeechRecognitionUpdate>
    private let continuation: AsyncStream<SpeechRecognitionUpdate>.Continuation
    private(set) var state: SpeechRecognitionState = .idle

    init() {
      (updates, continuation) = AsyncStream.makeStream()
    }

    func start(language: LiveTranslationLanguage,
               audioFormat: AVAudioFormat) async throws {
      state = .running
    }

    func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) throws {}

    func flush() async throws {
      state = .finished
      continuation.finish()
    }

    func cancel() {
      state = .finished
      continuation.finish()
    }
  }

  private final class FakeAudioSource: AudioCapturing {
    var state: AudioCaptureState = .idle
    var onStateChange: ((AudioCaptureState) -> Void)?
    private var continuation: AsyncStream<AudioFrame>.Continuation?

    func start() async throws -> AsyncStream<AudioFrame> {
      state = .running
      return AsyncStream { continuation in
        self.continuation = continuation
      }
    }

    func stop() {
      state = .idle
      continuation?.finish()
      continuation = nil
    }
  }

  private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

  private func makeCommitter() -> StablePrefixCommitter {
    var committer = StablePrefixCommitter()
    committer.configuration.minimumCommitCharacters = 1
    // These tests exercise the stability window; keep the latency fast path
    // out of the way unless a test opts into it.
    committer.configuration.firstCommitCharacters = 100
    committer.configuration.firstLatinCommitCharacters = 100
    return committer
  }

  // MARK: - Committer

  func testCommitterCommitsAtSentencePunctuation() {
    var committer = makeCommitter()
    let chunks = committer.ingest("你好，世界。", isFinal: false, now: t0)
    XCTAssertEqual(chunks, ["你好，世界。"])
    XCTAssertEqual(committer.committedText, "你好，世界。")
  }

  func testCommitterWaitsForStabilityThenCommits() {
    var committer = makeCommitter()
    XCTAssertTrue(committer.ingest("你好", isFinal: false, now: t0).isEmpty)
    XCTAssertTrue(committer.ingest(
      "你好今天", isFinal: false, now: t0.addingTimeInterval(0.1)).isEmpty)
    XCTAssertEqual(
      committer.tick(now: t0.addingTimeInterval(0.5)),
      ["你好今天"])
  }

  func testFirstPhraseCommitsWithoutTheStabilityWait() {
    var committer = StablePrefixCommitter()
    XCTAssertEqual(
      committer.ingest("안녕하세요", isFinal: false, now: t0),
      ["안녕하세요"])
    XCTAssertEqual(committer.committedText, "안녕하세요")

    var latin = StablePrefixCommitter()
    XCTAssertEqual(
      latin.ingest("Hello there", isFinal: false, now: t0),
      ["Hello there"])
    XCTAssertEqual(latin.committedText, "Hello there")

    var short = StablePrefixCommitter()
    XCTAssertTrue(short.ingest("Hi", isFinal: false, now: t0).isEmpty)
  }

  func testCommitterEmitsOnlyTheNewSuffix() {
    var committer = makeCommitter()
    _ = committer.ingest("你好", isFinal: false, now: t0)
    _ = committer.ingest("你好今天", isFinal: false, now: t0.addingTimeInterval(0.1))
    XCTAssertEqual(
      committer.tick(now: t0.addingTimeInterval(0.5)),
      ["你好今天"])
    _ = committer.ingest("你好今天天气", isFinal: false,
                         now: t0.addingTimeInterval(1.0))
    XCTAssertEqual(
      committer.tick(now: t0.addingTimeInterval(1.5)),
      ["天气"])
  }

  func testCommitterCommitsTheFinalRemainder() {
    var committer = makeCommitter()
    _ = committer.ingest("你好", isFinal: false, now: t0)
    XCTAssertEqual(
      committer.ingest("你好世界", isFinal: true, now: t0.addingTimeInterval(0.5)),
      ["你好世界"])
  }

  func testCommitterDoesNotRepeatCommittedTextOnFinal() {
    var committer = makeCommitter()
    _ = committer.ingest("你好。", isFinal: false, now: t0)
    XCTAssertEqual(
      committer.ingest("你好。世界。", isFinal: true,
                       now: t0.addingTimeInterval(0.5)),
      ["世界。"])
  }

  func testCommitterDoesNotUncommitDivergedText() {
    var committer = makeCommitter()
    _ = committer.ingest("你好世界。", isFinal: false, now: t0)
    XCTAssertTrue(committer.ingest(
      "你好地球。", isFinal: true, now: t0.addingTimeInterval(0.5)).isEmpty)
    // The final result resets the utterance; it never emits text that would
    // roll back an already translated line.
    XCTAssertEqual(committer.committedText, "")
  }

  func testFinalDivergesDetectsRewrittenPrefix() {
    var committer = makeCommitter()
    _ = committer.ingest("你好世界。", isFinal: false, now: t0)
    XCTAssertTrue(committer.finalDiverges("你好地球。"))
    XCTAssertFalse(committer.finalDiverges("你好世界。再见。"))
    committer.reset()
    XCTAssertFalse(committer.finalDiverges("anything"))
  }

  func testEmptyFinalResetsCommittedText() {
    var committer = makeCommitter()
    _ = committer.ingest("你好。", isFinal: false, now: t0)
    XCTAssertEqual(committer.committedText, "你好。")
    XCTAssertTrue(committer.ingest("", isFinal: true,
                                   now: t0.addingTimeInterval(0.5)).isEmpty)
    XCTAssertEqual(committer.committedText, "")
  }

  func testEmptyVolatileRevokesTextBeforeTheNextTick() {
    var committer = makeCommitter()
    _ = committer.ingest("你好今天", isFinal: false, now: t0)
    XCTAssertTrue(committer.ingest("", isFinal: false,
                                   now: t0.addingTimeInterval(0.1)).isEmpty)
    XCTAssertTrue(committer.tick(now: t0.addingTimeInterval(0.5)).isEmpty)
    XCTAssertEqual(committer.committedText, "")
  }

  func testLatinSentencePeriodCommits() {
    var committer = makeCommitter()
    XCTAssertEqual(
      committer.ingest("Hello world. Next", isFinal: false, now: t0),
      ["Hello world."])
    XCTAssertEqual(committer.committedText, "Hello world.")
  }

  func testCommitterDoesNotSplitLatinDecimals() {
    var committer = makeCommitter()
    let chunks = committer.ingest("圆周率是3.14", isFinal: false, now: t0)
    XCTAssertTrue(chunks.isEmpty)
    XCTAssertEqual(
      committer.tick(now: t0.addingTimeInterval(0.5)),
      ["圆周率是3.14"])
  }

  func testCommitterDoesNotSplitALatinWord() {
    var committer = StablePrefixCommitter()
    committer.configuration.firstCommitCharacters = 100
    committer.configuration.firstLatinCommitCharacters = 100
    _ = committer.ingest("We watched the inter", isFinal: false, now: t0)
    // The complete words commit; the unfinished token waits for the final.
    XCTAssertEqual(
      committer.tick(now: t0.addingTimeInterval(0.5)),
      ["We watched the"])
    XCTAssertEqual(
      committer.ingest("We watched the international news.", isFinal: true,
                       now: t0.addingTimeInterval(0.6)),
      [" international news."])
  }

  func testCommitterForcesACommitAtTheCharacterLimit() {
    var committer = makeCommitter()
    committer.configuration.maximumCharacters = 10
    let first = String(repeating: "一", count: 20)
    let second = String(repeating: "一", count: 30)
    XCTAssertTrue(committer.ingest(first, isFinal: false, now: t0).isEmpty)
    XCTAssertEqual(
      committer.ingest(second, isFinal: false,
                       now: t0.addingTimeInterval(0.1)),
      [first])
  }

  func testShortStableFragmentIsHeldUntilPunctuation() {
    var committer = StablePrefixCommitter()
    XCTAssertTrue(committer.ingest("你好", isFinal: false, now: t0).isEmpty)
    XCTAssertTrue(committer.tick(now: t0.addingTimeInterval(0.5)).isEmpty)
    XCTAssertEqual(
      committer.ingest("你好，世界。", isFinal: false,
                       now: t0.addingTimeInterval(0.6)),
      ["你好，世界。"])
  }

  func testCommonPrefix() {
    XCTAssertEqual(
      StablePrefixCommitter.commonPrefix("你好今天", "你好明天"), "你好")
    XCTAssertEqual(
      StablePrefixCommitter.commonPrefix("abc", "abcdef"), "abc")
    XCTAssertEqual(
      StablePrefixCommitter.commonPrefix("", "abc"), "")
  }

  // MARK: - Router

  private final class FakeAvailability: LiveTranslationAvailabilityChecking {
    var statuses: [String: TranslationPackStatus] = [:]

    func status(from source: LiveTranslationLanguage,
                to target: LiveTranslationLanguage) async -> TranslationPackStatus {
      if source.id == target.id { return .notNeeded }
      return statuses["\(source.id)->\(target.id)"] ?? .unsupported
    }
  }

  private final class FakeTranslator: LiveTranslationTranslating {
    var prepared: [(String, String)] = []
    var translations: [String] = []
    var result = "translated"
    var failuresRemaining = 0

    func prepare(from source: LiveTranslationLanguage,
                 to target: LiveTranslationLanguage) async throws {
      prepared.append((source.id, target.id))
    }

    func translate(_ text: String) async throws -> String {
      translations.append(text)
      if failuresRemaining > 0 {
        failuresRemaining -= 1
        throw LiveTranslationTranslationError.notPrepared
      }
      return result
    }

    func cancel() {}
  }

  private func makeRouter(
    statuses: [String: TranslationPackStatus],
    fallback: LiveTranslationFallback,
    ai: FakeTranslator? = nil,
    approval: @escaping (LiveTranslationLanguage, LiveTranslationLanguage)
      async -> Bool = { _, _ in false }
  ) -> (LiveTranslationRouter, FakeTranslator, FakeTranslator?, FakeAvailability) {
    let onDevice = FakeTranslator()
    let availability = FakeAvailability()
    availability.statuses = statuses
    let router = LiveTranslationRouter(
      onDevice: onDevice,
      aiProvider: ai,
      availability: availability,
      fallback: { fallback },
      requestAIApproval: approval)
    return (router, onDevice, ai, availability)
  }

  func testInstalledPairUsesTheOnDeviceSession() async throws {
    let (router, onDevice, _, _) = makeRouter(
      statuses: ["zh-Hans->en": .installed], fallback: .off)
    try await router.prepare(from: .simplifiedChinese, to: .english)
    XCTAssertEqual(router.currentRoute, .onDevice)
    XCTAssertEqual(onDevice.prepared.count, 1)
    _ = try await router.translate("你好")
    XCTAssertEqual(onDevice.translations, ["你好"])
  }

  func testMissingPackFallsBackToTheAIProvider() async throws {
    let ai = FakeTranslator()
    let (router, onDevice, _, _) = makeRouter(
      statuses: ["zh-Hans->en": .available], fallback: .aiProvider, ai: ai)
    try await router.prepare(from: .simplifiedChinese, to: .english)
    XCTAssertEqual(router.currentRoute, .aiProvider)
    XCTAssertTrue(onDevice.prepared.isEmpty)
    XCTAssertEqual(ai.prepared.count, 1)
  }

  func testMissingPackRequestsTheDownloadBeforeFallingBack() async throws {
    let ai = FakeTranslator()
    let (router, _, _, _) = makeRouter(
      statuses: ["zh-Hans->en": .available], fallback: .aiProvider, ai: ai)
    var requests: [(String, String, TranslationPackStatus)] = []
    router.autoDownload = { true }
    router.onMissingPack = { source, target, status in
      requests.append((source.id, target.id, status))
    }
    try await router.prepare(from: .simplifiedChinese, to: .english)
    XCTAssertEqual(router.currentRoute, .aiProvider)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.0, "zh-Hans")
    XCTAssertEqual(requests.first?.1, "en")
    XCTAssertEqual(requests.first?.2, .available)
  }

  func testAutoDownloadOffDoesNotRequestTheDownload() async throws {
    let ai = FakeTranslator()
    let (router, _, _, _) = makeRouter(
      statuses: ["zh-Hans->en": .available], fallback: .aiProvider, ai: ai)
    var requests = 0
    router.autoDownload = { false }
    router.onMissingPack = { _, _, _ in requests += 1 }
    try await router.prepare(from: .simplifiedChinese, to: .english)
    XCTAssertEqual(requests, 0)
  }

  func testUnsupportedPairWithoutAIConfigurationReportsTheFallbackProblem() async {
    let (router, _, _, _) = makeRouter(
      statuses: ["zh-Hans->en": .unsupported], fallback: .aiProvider)
    do {
      try await router.prepare(from: .simplifiedChinese, to: .english)
      XCTFail("expected an unavailable fallback")
    } catch LiveTranslationTranslationError.aiFallbackUnavailable {
      // Expected: the pair is unsupported and no AI provider is configured.
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testUnsupportedPairWithFallbackOffReportsThePair() async {
    let (router, _, _, _) = makeRouter(
      statuses: ["zh-Hans->en": .unsupported], fallback: .off)
    do {
      try await router.prepare(from: .simplifiedChinese, to: .english)
      XCTFail("expected an unavailable pair")
    } catch LiveTranslationTranslationError.unavailablePair {
      // Expected.
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testAskFallbackUsesTheProviderWhenApproved() async throws {
    let ai = FakeTranslator()
    let (router, onDevice, _, _) = makeRouter(
      statuses: ["zh-Hans->en": .available], fallback: .ask, ai: ai,
      approval: { _, _ in true })
    try await router.prepare(from: .simplifiedChinese, to: .english)
    XCTAssertEqual(router.currentRoute, .aiProvider)
    XCTAssertTrue(onDevice.prepared.isEmpty)
    XCTAssertEqual(ai.prepared.count, 1)
  }

  func testAskFallbackDeclinedReportsTheMissingPack() async {
    let ai = FakeTranslator()
    let (router, _, _, _) = makeRouter(
      statuses: ["zh-Hans->en": .available], fallback: .ask, ai: ai,
      approval: { _, _ in false })
    do {
      try await router.prepare(from: .simplifiedChinese, to: .english)
      XCTFail("expected a missing pack")
    } catch LiveTranslationTranslationError.packsMissing {
      // Expected: declining is different from an unsupported pair.
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(router.currentRoute, .unavailable)
  }

  func testMissingPackWithFallbackOffReportsThePackNotThePair() async {
    let (router, _, _, _) = makeRouter(
      statuses: ["zh-Hans->en": .available], fallback: .off)
    do {
      try await router.prepare(from: .simplifiedChinese, to: .english)
      XCTFail("expected a missing pack")
    } catch LiveTranslationTranslationError.packsMissing {
      // Expected.
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testDownloadingAndFailedChecksHaveDistinctReasons() async {
    let (downloading, _, _, _) = makeRouter(
      statuses: ["zh-Hans->en": .downloading], fallback: .off)
    do {
      try await downloading.prepare(from: .simplifiedChinese, to: .english)
      XCTFail("expected a download")
    } catch LiveTranslationTranslationError.packsDownloading {
      // Expected.
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    let (failed, _, _, _) = makeRouter(
      statuses: ["zh-Hans->en": .failed("boom")], fallback: .off)
    do {
      try await failed.prepare(from: .simplifiedChinese, to: .english)
      XCTFail("expected a failed check")
    } catch LiveTranslationTranslationError.packCheckFailed {
      // Expected.
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testTranslationFailureAllowsAReprepare() async throws {
    let (router, onDevice, _, _) = makeRouter(
      statuses: ["zh-Hans->en": .installed], fallback: .off)
    try await router.prepare(from: .simplifiedChinese, to: .english)
    XCTAssertEqual(onDevice.prepared.count, 1)
    onDevice.failuresRemaining = 1
    do {
      _ = try await router.translate("你好")
      XCTFail("expected a translation failure")
    } catch LiveTranslationTranslationError.notPrepared {
      // Expected.
    }
    router.cancel()
    try await router.prepare(from: .simplifiedChinese, to: .english)
    XCTAssertEqual(onDevice.prepared.count, 2)
    let output = try await router.translate("你好")
    XCTAssertEqual(output, "translated")
  }

  func testAudiblePlayerGuardIgnoresMutedAndIdlePlayers() {
    let first = NSObject()
    let second = NSObject()
    let firstID = ObjectIdentifier(first)
    let secondID = ObjectIdentifier(second)
    let playing = [
      PlayerCore.AudiblePlayerSnapshot(
        id: firstID, isPlaying: true, isMuted: false),
      PlayerCore.AudiblePlayerSnapshot(
        id: secondID, isPlaying: true, isMuted: false),
    ]
    XCTAssertTrue(
      PlayerCore.hasOtherAudiblePlayer(than: firstID, among: playing))
    let muted = [
      playing[0],
      PlayerCore.AudiblePlayerSnapshot(
        id: secondID, isPlaying: true, isMuted: true),
    ]
    XCTAssertFalse(
      PlayerCore.hasOtherAudiblePlayer(than: firstID, among: muted))
    let idle = [
      playing[0],
      PlayerCore.AudiblePlayerSnapshot(
        id: secondID, isPlaying: false, isMuted: false),
    ]
    XCTAssertFalse(
      PlayerCore.hasOtherAudiblePlayer(than: firstID, among: idle))
  }

  func testTranscriptionControllerStartsAndStopsWithInjectedSeams() async throws {
    let inventory = SystemSpeechModelInventory()
    let speech = await inventory.status(for: .korean)
    try XCTSkipUnless(
      speech == .installed, "Korean speech model is not installed")

    let oldEnabled = LiveTranslationPreferences.enabled
    let oldTarget = LiveTranslationPreferences.targetID
    let oldWatched = LiveTranslationPreferences.watchedIDs
    let player = PlayerCore.first
    let oldState = player.info.state
    let oldURL = player.info.currentURL
    defer {
      Preference.set(oldEnabled, for: .liveTranslationEnabled)
      Preference.set(oldTarget, for: .liveTranslationTarget)
      LiveTranslationPreferences.setWatchedIDs(oldWatched)
      player.info.currentURL = oldURL
      player.info.state = oldState
      PlayerCore.lastActive = player
    }

    Preference.set(true, for: .liveTranslationEnabled)
    Preference.set("en", for: .liveTranslationTarget)
    LiveTranslationPreferences.setWatchedIDs(["ko", "en"])
    PlayerCore.lastActive = player
    player.info.currentURL = URL(
      fileURLWithPath: "/tmp/live-translation-transcription-test.mkv")
    player.info.state = .playing
    player.liveTranslationLanguage.setOverride(.korean)
    for _ in 0..<50 {
      if player.liveTranslationLanguage.resolvedLanguage?.id == "ko" { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(player.liveTranslationLanguage.resolvedLanguage?.id, "ko")

    let recognizer = FakeSpeechRecognizer()
    let controller = LiveTranslationTranscriptionController(
      player: player,
      sourceFactory: { _, _, _, _ in
        let source = FakeAudioSource()
        let frames = try await source.start()
        return (source, frames, nil)
      },
      recognizerFactory: { recognizer })

    player.postNotification(.iinaPlaybackStarted)
    for _ in 0..<100 {
      if controller.isRunning { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.isRunning)

    player.postNotification(.iinaSeekStarted)
    for _ in 0..<100 {
      if !controller.isRunning { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertFalse(controller.isRunning)
  }

  /// Exercises the real caption controller with the app's first player and the
  /// installed Korean→English pack. No file or mpv video output is required:
  /// the overlay clears when no video dimensions are available, while the
  /// controller's committer, router, translation and pause observer run.
  func testCaptionControllerProducesAndClearsARealCaption() async throws {
    let inventory = SystemTranslationPackInventory()
    let availability = await inventory.status(from: .korean, to: .english)
    try XCTSkipUnless(
      availability == .installed, "Korean→English pack is not installed")

    let oldEnabled = LiveTranslationPreferences.enabled
    let oldTarget = LiveTranslationPreferences.targetID
    let oldWatched = LiveTranslationPreferences.watchedIDs
    let player = PlayerCore.first
    let oldState = player.info.state
    let oldURL = player.info.currentURL
    defer {
      Preference.set(oldEnabled, for: .liveTranslationEnabled)
      Preference.set(oldTarget, for: .liveTranslationTarget)
      LiveTranslationPreferences.setWatchedIDs(oldWatched)
      player.info.currentURL = oldURL
      player.info.state = oldState
    }

    Preference.set(true, for: .liveTranslationEnabled)
    Preference.set("en", for: .liveTranslationTarget)
    LiveTranslationPreferences.setWatchedIDs(["ko", "en"])
    PlayerCore.lastActive = player
    player.info.currentURL = URL(
      fileURLWithPath: "/tmp/live-translation-controller-test.mkv")
    player.info.state = .playing
    player.liveTranslationLanguage.setOverride(.korean)

    for _ in 0..<50 {
      if player.liveTranslationLanguage.resolvedLanguage?.id == "ko" { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(player.liveTranslationLanguage.resolvedLanguage?.id, "ko")

    let captions = LiveTranslationCaptionController(player: player)
    captions.ingest("안녕하세요", isFinal: false, confidence: 0.9)
    var text = ""
    for _ in 0..<100 {
      text = captions.latestTargetText
      if !text.isEmpty { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertFalse(text.isEmpty)
    XCTAssertTrue(text.lowercased().contains("hello"), text)

    player.info.state = .paused
    player.postNotification(.iinaPauseChanged)
    for _ in 0..<50 {
      if captions.latestTargetText.isEmpty { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(captions.latestTargetText.isEmpty)
  }

  func testSourceEqualsTargetSkipsWithoutPreparing() async throws {
    let (router, onDevice, _, _) = makeRouter(
      statuses: [:], fallback: .off)
    try await router.prepare(from: .english, to: .english)
    XCTAssertEqual(router.currentRoute, .skip)
    XCTAssertTrue(onDevice.prepared.isEmpty)
    let translated = try await router.translate("hello")
    XCTAssertEqual(translated, "")
  }
}
