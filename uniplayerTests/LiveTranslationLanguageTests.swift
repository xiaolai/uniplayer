//
//  LiveTranslationLanguageTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

@MainActor
final class LiveTranslationLanguageTests: XCTestCase {

  private final class FakeSpeechSupport: SpeechLocaleSupporting {
    var unsupported = Set<String>()
    private(set) var checked: [String] = []

    func supportedLocale(for language: LiveTranslationLanguage) async -> Locale? {
      checked.append(language.id)
      return unsupported.contains(language.id)
        ? nil
        : Locale(identifier: language.speechIdentifier)
    }
  }

  private final class FakePrompt: LiveTranslationLanguagePrompting {
    var outcome: LiveTranslationLanguagePromptOutcome = .declined
    private(set) var calls: [(candidates: [LiveTranslationLanguage], title: String?)] = []

    func chooseLanguage(candidates: [LiveTranslationLanguage],
                        showTitle: String?) async -> LiveTranslationLanguagePromptOutcome {
      calls.append((candidates, showTitle))
      return outcome
    }
  }

  private final class FakeStore: ShowLanguageStoring {
    var entries: [String: String] = [:]

    func languageID(for showKey: String) -> String? {
      entries[showKey]
    }

    func setLanguageID(_ languageID: String?, for showKey: String) {
      entries[showKey] = languageID
    }
  }

  private final class BlockingPrompt: LiveTranslationLanguagePrompting {
    private(set) var calls = 0
    private var continuation:
      CheckedContinuation<LiveTranslationLanguagePromptOutcome, Never>?

    func chooseLanguage(candidates: [LiveTranslationLanguage],
                        showTitle: String?) async -> LiveTranslationLanguagePromptOutcome {
      calls += 1
      return await withCheckedContinuation { continuation in
        self.continuation = continuation
      }
    }

    func resume(_ outcome: LiveTranslationLanguagePromptOutcome) {
      continuation?.resume(returning: outcome)
      continuation = nil
    }
  }

  /// Blocks the first speech-support check so a second resolution can finish
  /// while the first is still waiting.
  private final class GatedSpeechSupport: SpeechLocaleSupporting, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var gate: CheckedContinuation<Void, Never>?

    var isWaiting: Bool {
      lock.lock()
      defer { lock.unlock() }
      return gate != nil
    }

    func supportedLocale(for language: LiveTranslationLanguage) async -> Locale? {
      lock.lock()
      callCount += 1
      let number = callCount
      lock.unlock()
      if number == 1 {
        await withCheckedContinuation { continuation in
          lock.lock()
          gate = continuation
          lock.unlock()
        }
      }
      return Locale(identifier: language.speechIdentifier)
    }

    func release() {
      lock.lock()
      let continuation = gate
      gate = nil
      lock.unlock()
      continuation?.resume()
    }
  }

  private func makeResolver(
    unsupported: Set<String> = []
  ) -> (LiveTranslationLanguageResolver, FakeSpeechSupport) {
    let support = FakeSpeechSupport()
    support.unsupported = unsupported
    return (LiveTranslationLanguageResolver(speechSupport: support), support)
  }

  private func metadata(title: String, year: Int? = 2024) -> LibraryMetadata {
    LibraryMetadata(title: title, year: year, season: nil, episode: nil, quality: nil)
  }

  // MARK: - Tags

  func testTagMappingCoversISOCodesAndRegions() {
    let cases: [(String, LiveTranslationLanguage)] = [
      ("en", .english), ("eng", .english), ("en-US", .english),
      ("ja", .japanese), ("jpn", .japanese), ("ja-JP", .japanese),
      ("ko", .korean), ("kor", .korean), ("ko-KR", .korean),
      ("fr", .french), ("fra", .french), ("fre", .french), ("fr-CH", .french),
      ("it", .italian), ("ita", .italian), ("it-CH", .italian),
      ("zh", .simplifiedChinese), ("zho", .simplifiedChinese),
      ("chi", .simplifiedChinese), ("cmn", .simplifiedChinese),
      ("zh-Hans", .simplifiedChinese), ("zh-CN", .simplifiedChinese),
      ("zh-Hant", .traditionalChinese), ("zh-TW", .traditionalChinese),
      ("zh-HK", .traditionalChinese),
      ("yue", .cantonese), ("yue-CN", .cantonese), ("zh-yue", .cantonese),
    ]
    for (tag, expected) in cases {
      XCTAssertEqual(
        LiveTranslationLanguageTags.language(for: tag)?.id,
        expected.id, "tag \(tag)")
    }
  }

  func testMissingAndUnrecognizedTagsAreDistinct() {
    for tag in ["", "und", "unknown", "zxx", "mul"] {
      XCTAssertTrue(LiveTranslationLanguageTags.isMissing(tag), tag)
      XCTAssertNil(LiveTranslationLanguageTags.language(for: tag), tag)
    }
    XCTAssertFalse(LiveTranslationLanguageTags.isMissing("de"))
    XCTAssertNil(LiveTranslationLanguageTags.language(for: "de"))
  }

  // MARK: - Resolver

  func testShowOverrideWinsOverTrackMetadata() async {
    let (resolver, _) = makeResolver()
    let result = await resolver.resolve(
      trackLanguage: "en-US",
      showOverrideID: "ko",
      watched: [.korean, .english],
      target: .simplifiedChinese)

    XCTAssertEqual(result, .resolved(.korean, source: .showOverride))
  }

  func testTrackMetadataIsUsedWhenNoOverrideExists() async {
    let (resolver, _) = makeResolver()
    let result = await resolver.resolve(
      trackLanguage: "jpn",
      showOverrideID: nil,
      watched: [.english],
      target: .simplifiedChinese)

    XCTAssertEqual(result, .resolved(.japanese, source: .trackMetadata))
  }

  func testMissingMetadataFallsBackToASingleWatchedLanguage() async {
    let (resolver, _) = makeResolver()
    let result = await resolver.resolve(
      trackLanguage: "und",
      showOverrideID: nil,
      watched: [.french],
      target: .simplifiedChinese)

    XCTAssertEqual(result, .resolved(.french, source: .watchedList))
  }

  func testMissingMetadataWithSeveralWatchedLanguagesAsksOnce() async {
    let (resolver, _) = makeResolver()
    let result = await resolver.resolve(
      trackLanguage: nil,
      showOverrideID: nil,
      watched: [.korean, .japanese, .french, .italian],
      target: .simplifiedChinese)

    XCTAssertEqual(
      result,
      .needsChoice(candidates: [.korean, .japanese, .french, .italian]))
  }

  func testEmptyWatchedListIsUnsupported() async {
    let (resolver, _) = makeResolver()
    let result = await resolver.resolve(
      trackLanguage: nil,
      showOverrideID: nil,
      watched: [],
      target: .simplifiedChinese)

    XCTAssertEqual(result, .unsupported(.noWatchedLanguages))
  }

  func testSourceEqualToTargetSkipsWithoutCheckingSpeechModels() async {
    let (resolver, support) = makeResolver(unsupported: ["en"])
    let result = await resolver.resolve(
      trackLanguage: "eng",
      showOverrideID: nil,
      watched: [.english],
      target: .english)

    XCTAssertEqual(result, .skip(.english))
    XCTAssertTrue(support.checked.isEmpty)
  }

  func testUnrecognizedTrackTagIsUnsupported() async {
    let (resolver, _) = makeResolver()
    let result = await resolver.resolve(
      trackLanguage: "de-DE",
      showOverrideID: nil,
      watched: [.english],
      target: .simplifiedChinese)

    XCTAssertEqual(result, .unsupported(.unrecognizedTag("de-DE")))
  }

  func testMissingSpeechModelIsUnsupported() async {
    let (resolver, _) = makeResolver(unsupported: ["ko"])
    let result = await resolver.resolve(
      trackLanguage: "ko",
      showOverrideID: nil,
      watched: [.korean],
      target: .simplifiedChinese)

    XCTAssertEqual(result, .unsupported(.speechModelUnavailable(.korean)))
  }

  func testRegionalSpeechSpellingResolvesToTheWatchedLanguage() async {
    let (resolver, support) = makeResolver()
    let result = await resolver.resolve(
      trackLanguage: "fr-CH",
      showOverrideID: nil,
      watched: [.french],
      target: .simplifiedChinese)

    XCTAssertEqual(result, .resolved(.french, source: .trackMetadata))
    XCTAssertEqual(support.checked, ["fr"])
  }

  func testDuplicatesInTheWatchedListDoNotTriggerAChoice() async {
    let (resolver, _) = makeResolver()
    let result = await resolver.resolve(
      trackLanguage: nil,
      showOverrideID: nil,
      watched: [.korean, .korean],
      target: .simplifiedChinese)

    XCTAssertEqual(result, .resolved(.korean, source: .watchedList))
  }

  // MARK: - Text identification

  func testTextIdentifierRecognizesTheWatchedLanguages() {
    let cases: [(String, String)] = [
      ("Bonjour, comment allez-vous aujourd'hui ? Je vais très bien, merci beaucoup.", "fr"),
      ("Buongiorno, come stai oggi? Sto molto bene, grazie mille.", "it"),
      ("안녕하세요, 오늘 날씨가 정말 좋네요. 산책하기 좋은 날입니다.", "ko"),
      ("こんにちは、今日はとても良い天気ですね。散歩に行きましょう。", "ja"),
      ("Hello there, the weather is lovely today. Shall we go for a walk?", "en"),
    ]
    for (text, expected) in cases {
      XCTAssertEqual(
        LiveTranslationLanguageTextIdentifier.language(for: [text])?.id,
        expected, text)
    }
  }

  func testTextIdentifierUsesOnlyTheFirstTwoPhrases() {
    let french = "Bonjour, comment allez-vous aujourd'hui ? Je vais très bien, merci beaucoup."
    let japanese = "こんにちは、今日はとても良い天気ですね。散歩に行きましょう。"
    let korean = "안녕하세요, 오늘 날씨가 정말 좋네요. 산책하기 좋은 날입니다."
    let identified = LiveTranslationLanguageTextIdentifier.language(
      for: [french, japanese, korean])
    XCTAssertNotNil(identified)
    XCTAssertNotEqual(identified?.id, "ko")
  }

  func testTextIdentifierRejectsEmptyInput() {
    XCTAssertNil(LiveTranslationLanguageTextIdentifier.language(for: []))
    XCTAssertNil(LiveTranslationLanguageTextIdentifier.language(for: ["  ", ""]))
  }

  func testConfirmationOnlyAcceptsADifferentWatchedLanguage() {
    let english = "Hello there, the weather is lovely today. Shall we go for a walk?"
    XCTAssertEqual(
      LiveTranslationLanguageTextIdentifier.confirmedLanguage(
        for: [english], current: .korean, watched: [.korean, .english])?.id,
      "en")
    XCTAssertNil(LiveTranslationLanguageTextIdentifier.confirmedLanguage(
      for: [english], current: .english, watched: [.korean, .english]))
    XCTAssertNil(LiveTranslationLanguageTextIdentifier.confirmedLanguage(
      for: [english], current: .korean, watched: [.korean]))
  }

  // MARK: - Show identity

  func testEpisodesOfTheSameShowShareAKey() {
    let first = LibraryMetadata.parse(fileName: "The.Show.S01E01.1080p.mkv")
    let second = LibraryMetadata.parse(fileName: "The.Show.S01E02.1080p.mkv")
    let urlA = URL(fileURLWithPath: "/shows/The.Show.S01E01.1080p.mkv")
    let urlB = URL(fileURLWithPath: "/other/The.Show.S01E02.1080p.mkv")

    XCTAssertEqual(
      LiveTranslationShowIdentity.key(url: urlA, metadata: first),
      LiveTranslationShowIdentity.key(url: urlB, metadata: second))
  }

  func testDifferentYearsProduceDifferentKeys() {
    let url = URL(fileURLWithPath: "/movies/Title.mkv")
    XCTAssertNotEqual(
      LiveTranslationShowIdentity.key(url: url, metadata: metadata(title: "Title", year: 2020)),
      LiveTranslationShowIdentity.key(url: url, metadata: metadata(title: "Title", year: 2021)))
  }

  func testTitleNormalizationIgnoresCaseAndDiacritics() {
    let url = URL(fileURLWithPath: "/movies/x.mkv")
    XCTAssertEqual(
      LiveTranslationShowIdentity.key(url: url, metadata: metadata(title: "Café Show")),
      LiveTranslationShowIdentity.key(url: url, metadata: metadata(title: "cafe  show")))
  }

  func testNetworkKeyDropsQueryAndFragment() {
    let a = URL(string: "https://media.example.com/show/episode-1?token=1#start")!
    let b = URL(string: "https://media.example.com/show/episode-1?token=2")!
    XCTAssertEqual(
      LiveTranslationShowIdentity.key(url: a, metadata: nil),
      LiveTranslationShowIdentity.key(url: b, metadata: nil))
  }

  func testNetworkKeyKeepsMediaIdentifyingParameters() {
    let a = URL(string: "https://media.example.com/watch?v=A")!
    let b = URL(string: "https://media.example.com/watch?v=B")!
    XCTAssertNotEqual(
      LiveTranslationShowIdentity.key(url: a, metadata: nil),
      LiveTranslationShowIdentity.key(url: b, metadata: nil))
    let signedA = URL(string: "https://media.example.com/watch?v=A&token=1")!
    let signedB = URL(string: "https://media.example.com/watch?v=A&token=2")!
    XCTAssertEqual(
      LiveTranslationShowIdentity.key(url: signedA, metadata: nil),
      LiveTranslationShowIdentity.key(url: signedB, metadata: nil))
  }

  func testNetworkStreamsWithParsedMetadataDoNotShareAKey() {
    let a = URL(string: "https://a.example/show-a/index.m3u8")!
    let b = URL(string: "https://b.example/show-b/index.m3u8")!
    XCTAssertNotEqual(
      LiveTranslationShowIdentity.key(url: a, metadata: metadata(title: "index")),
      LiveTranslationShowIdentity.key(url: b, metadata: metadata(title: "index")))
  }

  func testFileKeyUsesTheNameNotTheDirectory() {
    let a = URL(fileURLWithPath: "/one/Movie.mkv")
    let b = URL(fileURLWithPath: "/two/Movie.mkv")
    XCTAssertEqual(
      LiveTranslationShowIdentity.key(url: a, metadata: nil),
      LiveTranslationShowIdentity.key(url: b, metadata: nil))
  }

  // MARK: - Store

  func testStorePersistsAcrossInstances() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translation-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let first = LiveTranslationShowLanguageStore(fileURL: url)
    first.setLanguageID("ko", for: "show:korean-drama|2024")
    XCTAssertEqual(first.languageID(for: "show:korean-drama|2024"), "ko")

    let second = LiveTranslationShowLanguageStore(fileURL: url)
    XCTAssertEqual(second.languageID(for: "show:korean-drama|2024"), "ko")

    second.setLanguageID(nil, for: "show:korean-drama|2024")
    let third = LiveTranslationShowLanguageStore(fileURL: url)
    XCTAssertNil(third.languageID(for: "show:korean-drama|2024"))
  }

  func testStoreRejectsUnknownLanguageIDs() {
    let store = LiveTranslationShowLanguageStore(fileURL: nil)
    store.setLanguageID("xx", for: "show:x|2024")
    XCTAssertNil(store.languageID(for: "show:x|2024"))
  }

  func testStoreStartsEmptyAfterCorruptFile() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translation-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("not json".utf8).write(to: url)

    let store = LiveTranslationShowLanguageStore(fileURL: url)
    XCTAssertNil(store.languageID(for: "show:x|2024"))
    store.setLanguageID("ja", for: "show:x|2024")
    XCTAssertEqual(store.languageID(for: "show:x|2024"), "ja")
  }

  // MARK: - Session

  func testSessionPromptsOnceAndRemembersTheChoice() async {
    let (resolver, _) = makeResolver()
    let store = FakeStore()
    let session = LiveTranslationLanguageSession(resolver: resolver, store: store)
    let prompt = FakePrompt()
    prompt.outcome = .chosen(.korean)

    let url = URL(fileURLWithPath: "/shows/PromptOnce.S01E01.mkv")
    let metadata = LibraryMetadata.parse(fileName: url.lastPathComponent)
    let first = await session.resolve(
      url: url, metadata: metadata, trackLanguage: nil,
      watched: [.english, .korean, .japanese],
      target: .simplifiedChinese, prompt: prompt)

    XCTAssertEqual(first, .resolved(.korean, source: .userChoice))
    XCTAssertEqual(prompt.calls.count, 1)
    XCTAssertEqual(prompt.calls.first?.title, metadata.title)
    XCTAssertEqual(store.entries.count, 1)

    let second = await session.resolve(
      url: url, metadata: metadata, trackLanguage: nil,
      watched: [.english, .korean, .japanese],
      target: .simplifiedChinese, prompt: prompt)

    XCTAssertEqual(second, .resolved(.korean, source: .showOverride))
    XCTAssertEqual(prompt.calls.count, 1)
  }

  func testSessionDoesNotAskAgainAfterTheUserDeclines() async {
    let (resolver, _) = makeResolver()
    let store = FakeStore()
    let session = LiveTranslationLanguageSession(resolver: resolver, store: store)
    let prompt = FakePrompt()
    prompt.outcome = .declined

    let url = URL(fileURLWithPath: "/shows/Declined.S01E01.mkv")
    let metadata = LibraryMetadata.parse(fileName: url.lastPathComponent)
    let first = await session.resolve(
      url: url, metadata: metadata, trackLanguage: nil,
      watched: [.english, .korean], target: .simplifiedChinese, prompt: prompt)
    let second = await session.resolve(
      url: url, metadata: metadata, trackLanguage: nil,
      watched: [.english, .korean], target: .simplifiedChinese, prompt: prompt)

    XCTAssertEqual(first, .needsChoice(candidates: [.english, .korean]))
    XCTAssertEqual(second, first)
    XCTAssertEqual(prompt.calls.count, 1)
    XCTAssertTrue(store.entries.isEmpty)
    // A declined prompt still gives ASR a tentative locale so LID can confirm
    // or replace the guess after the first finalized phrases.
    XCTAssertTrue(session.isTentative)
    XCTAssertEqual(session.resolvedLanguage, .english)
  }

  func testUnavailablePromptIsRetriedOnTheNextResolution() async {
    let (resolver, _) = makeResolver()
    let store = FakeStore()
    let session = LiveTranslationLanguageSession(resolver: resolver, store: store)
    let prompt = FakePrompt()
    prompt.outcome = .unavailable

    let url = URL(fileURLWithPath: "/shows/Retry.S01E01.mkv")
    let metadata = LibraryMetadata.parse(fileName: url.lastPathComponent)
    let first = await session.resolve(
      url: url, metadata: metadata, trackLanguage: nil,
      watched: [.english, .korean], target: .simplifiedChinese, prompt: prompt)
    XCTAssertEqual(first, .needsChoice(candidates: [.english, .korean]))
    XCTAssertEqual(prompt.calls.count, 1)

    prompt.outcome = .chosen(.korean)
    let second = await session.resolve(
      url: url, metadata: metadata, trackLanguage: nil,
      watched: [.english, .korean], target: .simplifiedChinese, prompt: prompt)
    XCTAssertEqual(second, .resolved(.korean, source: .userChoice))
    XCTAssertEqual(prompt.calls.count, 2)
  }

  func testOnlyOneSessionPromptsForTheSameShow() async {
    let (resolver, _) = makeResolver()
    let store = FakeStore()
    let first = LiveTranslationLanguageSession(resolver: resolver, store: store)
    let second = LiveTranslationLanguageSession(resolver: resolver, store: store)
    let prompt = BlockingPrompt()
    let url = URL(fileURLWithPath: "/shows/SharedShow.S01E01.mkv")
    let metadata = LibraryMetadata.parse(fileName: url.lastPathComponent)

    let firstTask = Task {
      await first.resolve(
        url: url, metadata: metadata, trackLanguage: nil,
        watched: [.english, .korean],
        target: .simplifiedChinese, prompt: prompt)
    }
    while prompt.calls == 0 {
      await Task.yield()
    }

    let secondTask = Task {
      await second.resolve(
        url: url, metadata: metadata, trackLanguage: nil,
        watched: [.english, .korean],
        target: .simplifiedChinese, prompt: prompt)
    }
    for _ in 0..<50 {
      await Task.yield()
    }
    XCTAssertEqual(prompt.calls, 1)

    prompt.resume(.declined)
    let firstResult = await firstTask.value
    let secondResult = await secondTask.value
    let expected = LiveTranslationLanguageResolution.needsChoice(
      candidates: [.english, .korean])
    XCTAssertEqual(firstResult, expected)
    XCTAssertEqual(secondResult, expected)
    XCTAssertEqual(prompt.calls, 1)

    let again = await second.resolve(
      url: url, metadata: metadata, trackLanguage: nil,
      watched: [.english, .korean],
      target: .simplifiedChinese, prompt: prompt)
    XCTAssertEqual(again, expected)
    XCTAssertEqual(prompt.calls, 1)
  }

  func testSessionUsesAStoredOverrideWithoutPrompting() async {
    let (resolver, _) = makeResolver()
    let store = FakeStore()
    let url = URL(fileURLWithPath: "/shows/Tagged.S01E01.mkv")
    let metadata = LibraryMetadata.parse(fileName: url.lastPathComponent)
    let key = LiveTranslationShowIdentity.key(url: url, metadata: metadata)
    store.entries[key] = "ja"

    let session = LiveTranslationLanguageSession(resolver: resolver, store: store)
    let prompt = FakePrompt()
    let result = await session.resolve(
      url: url, metadata: metadata, trackLanguage: "en",
      watched: [.english, .japanese],
      target: .simplifiedChinese, prompt: prompt)

    XCTAssertEqual(result, .resolved(.japanese, source: .showOverride))
    XCTAssertTrue(prompt.calls.isEmpty)
  }

  func testSessionSkipsWhenSourceEqualsTarget() async {
    let (resolver, _) = makeResolver()
    let store = FakeStore()
    let url = URL(fileURLWithPath: "/shows/Chinese.S01E01.mkv")
    let metadata = LibraryMetadata.parse(fileName: url.lastPathComponent)
    store.entries[LiveTranslationShowIdentity.key(url: url, metadata: metadata)] = "zh-Hans"

    let session = LiveTranslationLanguageSession(resolver: resolver, store: store)
    let prompt = FakePrompt()
    let result = await session.resolve(
      url: url, metadata: metadata, trackLanguage: "ko",
      watched: [.korean, .simplifiedChinese],
      target: .simplifiedChinese, prompt: prompt)

    XCTAssertEqual(result, .skip(.simplifiedChinese))
    XCTAssertTrue(session.shouldSkip)
    XCTAssertTrue(prompt.calls.isEmpty)
  }

  func testSetOverrideClearsAndReplacesTheStoredChoice() async {
    let (resolver, _) = makeResolver()
    let store = FakeStore()
    let session = LiveTranslationLanguageSession(resolver: resolver, store: store)
    let url = URL(fileURLWithPath: "/shows/Override.S01E01.mkv")
    let metadata = LibraryMetadata.parse(fileName: url.lastPathComponent)

    session.setOverride(.japanese, for: url, metadata: metadata)
    let key = LiveTranslationShowIdentity.key(url: url, metadata: metadata)
    XCTAssertEqual(store.entries[key], "ja")

    session.setOverride(nil, for: url, metadata: metadata)
    XCTAssertNil(store.entries[key])
  }

  func testAStaleResolutionCannotOverwriteANewerOne() async {
    let support = GatedSpeechSupport()
    let resolver = LiveTranslationLanguageResolver(speechSupport: support)
    let session = LiveTranslationLanguageSession(
      resolver: resolver, store: FakeStore())
    let url = URL(fileURLWithPath: "/shows/Stale.S01E01.mkv")
    let metadata = LibraryMetadata.parse(fileName: url.lastPathComponent)

    let stale = Task {
      await session.resolve(
        url: url, metadata: metadata, trackLanguage: "ko",
        watched: [.korean, .japanese], target: .simplifiedChinese,
        prompt: nil)
    }
    while !support.isWaiting {
      await Task.yield()
    }
    let fresh = await session.resolve(
      url: url, metadata: metadata, trackLanguage: "ja",
      watched: [.korean, .japanese], target: .simplifiedChinese,
      prompt: nil)
    XCTAssertEqual(fresh, .resolved(.japanese, source: .trackMetadata))

    support.release()
    _ = await stale.value
    XCTAssertEqual(session.resolvedLanguage, .japanese)
  }
}
