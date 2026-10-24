//
//  LiveTranslationSettingsTests.swift
//  UniPlayerTests
//

import Foundation
import Speech
import XCTest
@testable import UniPlayer

@MainActor
final class LiveTranslationSettingsTests: XCTestCase {

  func testOldDownloadTokenCannotCancelANewRequest() async {
    let coordinator = TranslationPackDownloadCoordinator()
    let installer = SystemTranslationPackInstaller(coordinator: coordinator)
    let first = Task {
      try await installer.install(from: .korean, to: .english)
    }
    while coordinator.request == nil {
      await Task.yield()
    }
    let oldToken = coordinator.request!.id
    coordinator.cancel(token: oldToken)
    do {
      try await first.value
      XCTFail("expected cancellation")
    } catch {
      // The old request was cancelled.
    }

    let second = Task {
      try await installer.install(from: .korean, to: .english)
    }
    while coordinator.request == nil
      || coordinator.request!.id == oldToken {
      await Task.yield()
    }
    // A late cancellation from the first request must not touch the second.
    coordinator.cancel(token: oldToken)
    XCTAssertNotNil(coordinator.request)
    coordinator.cancel()
    do {
      try await second.value
      XCTFail("expected cancellation")
    } catch {
      // Cleaned up.
    }
  }

  // MARK: - Fakes

  private final class FakeSpeechInventory: SpeechModelInventory {
    var statuses: [String: SpeechPackStatus]
    var installError: Error?
    private(set) var installCount = 0

    init(_ statuses: [String: SpeechPackStatus] = [:]) {
      self.statuses = statuses
    }

    func status(for language: LiveTranslationLanguage) async -> SpeechPackStatus {
      statuses[language.id] ?? .available
    }

    func install(_ language: LiveTranslationLanguage) async throws {
      installCount += 1
      if let installError { throw installError }
      statuses[language.id] = .installed
    }
  }

  private final class BlockingSpeechInventory: SpeechModelInventory {
    private(set) var installCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func status(for language: LiveTranslationLanguage) async -> SpeechPackStatus {
      .available
    }

    func install(_ language: LiveTranslationLanguage) async throws {
      installCount += 1
      await withCheckedContinuation { continuation in
        self.continuation = continuation
      }
    }

    func resume() {
      continuation?.resume()
      continuation = nil
    }
  }

  private final class FakeTranslationInventory: TranslationPackInventory {
    var statuses: [String: TranslationPackStatus]

    init(_ statuses: [String: TranslationPackStatus] = [:]) {
      self.statuses = statuses
    }

    func status(from source: LiveTranslationLanguage,
                to target: LiveTranslationLanguage) async -> TranslationPackStatus {
      guard source.id != target.id else { return .notNeeded }
      return statuses[Self.key(source, target)] ?? .available
    }

    static func key(_ source: LiveTranslationLanguage,
                    _ target: LiveTranslationLanguage) -> String {
      "\(source.id)->\(target.id)"
    }
  }

  private final class FakeTranslationInstaller: TranslationPackInstalling {
    var installs: [(String, String)] = []
    var installError: Error?
    private(set) var cancelCount = 0
    var onInstall: ((String, String) -> Void)?

    func install(from source: LiveTranslationLanguage,
                 to target: LiveTranslationLanguage) async throws {
      installs.append((source.id, target.id))
      if let installError { throw installError }
      onInstall?(source.id, target.id)
    }

    func cancel() {
      cancelCount += 1
    }
  }

  private func makeModel(
    speech: SpeechModelInventory,
    translation: TranslationPackInventory,
    installer: TranslationPackInstalling
  ) -> LiveTranslationPackModel {
    LiveTranslationPackModel(
      speech: speech, translation: translation, installer: installer)
  }

  // MARK: - Language catalog

  func testTargetCatalogCoversTheWatchedLanguages() {
    let targetIDs = Set(LiveTranslationLanguages.targetCandidates.map(\.id))
    XCTAssertEqual(
      targetIDs,
      ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "it"])
    XCTAssertFalse(targetIDs.contains("yue"))
    XCTAssertNotNil(LiveTranslationLanguages.target(for: "ko"))
    XCTAssertNotNil(LiveTranslationLanguages.target(for: "zh-Hans"))
  }

  func testWatchedCatalogContainsTheFourSourceLanguages() {
    let ids = Set(LiveTranslationLanguages.watchedCandidates.map(\.id))
    for id in ["ko", "ja", "fr", "it", "en", "zh-Hans"] {
      XCTAssertTrue(ids.contains(id), "missing watched language \(id)")
    }
    XCTAssertNotNil(LiveTranslationLanguages.language(for: "yue"))
  }

  func testLanguageCarriesDifferentIdentifiersForTheTwoSystems() {
    let korean = LiveTranslationLanguages.korean
    XCTAssertEqual(korean.speechIdentifier, "ko-KR")
    XCTAssertEqual(korean.translationIdentifier, "ko")
    XCTAssertEqual(LiveTranslationLanguages.french.speechIdentifier, "fr")
    XCTAssertEqual(LiveTranslationLanguages.french.translationIdentifier, "fr")
    XCTAssertEqual(LiveTranslationLanguages.cantonese.translationIdentifier, "yue")
  }

  func testLanguageDisplayNameIsNonEmpty() {
    for language in LiveTranslationLanguages.watchedCandidates {
      XCTAssertFalse(language.displayName.isEmpty)
    }
  }

  // MARK: - Watched-language parsing

  func testParseWatchedTrimsFiltersAndDeduplicates() {
    let parsed = LiveTranslationPreferences.parseWatched(
      " ko, ja , xx, ko, fr ,, ja-CN ")
    XCTAssertEqual(parsed, ["ko", "ja", "fr"])
  }

  func testSerializeWatchedNormalizesOrderAndDuplicates() {
    let serialized = LiveTranslationPreferences.serializeWatched(
      ["ja", "ko", "ja", "unknown"])
    XCTAssertEqual(serialized, "ja,ko")
  }

  func testParseWatchedRoundTripsThroughSerialize() {
    let original = ["it", "fr", "en", "zh-Hans"]
    let parsed = LiveTranslationPreferences.parseWatched(
      LiveTranslationPreferences.serializeWatched(original))
    XCTAssertEqual(parsed, original)
  }

  func testParseWatchedRejectsOnlyUnknownLanguages() {
    XCTAssertEqual(LiveTranslationPreferences.parseWatched(""), [])
    XCTAssertEqual(LiveTranslationPreferences.parseWatched("xx, yue"), ["yue"])
  }

  // MARK: - Defaults

  func testDefaultTargetFollowsTheSystemLanguage() {
    XCTAssertEqual(LiveTranslationPreferences.defaultTargetID(for: "zh"), "zh-Hans")
    XCTAssertEqual(LiveTranslationPreferences.defaultTargetID(for: "ko"), "ko")
    XCTAssertEqual(LiveTranslationPreferences.defaultTargetID(for: "ja"), "ja")
    XCTAssertEqual(LiveTranslationPreferences.defaultTargetID(for: "fr"), "fr")
    XCTAssertEqual(LiveTranslationPreferences.defaultTargetID(for: "it"), "it")
    XCTAssertEqual(LiveTranslationPreferences.defaultTargetID(for: "en"), "en")
  }

  func testDefaultTargetForOtherSystemLanguagesIsEnglish() {
    XCTAssertEqual(LiveTranslationPreferences.defaultTargetID(for: "de"), "en")
    XCTAssertEqual(LiveTranslationPreferences.defaultTargetID(for: "xx"), "en")
  }

  func testEnumDefaultsMatchThePlan() {
    XCTAssertEqual(LiveTranslationFallback.defaultValue, .aiProvider)
    XCTAssertEqual(LiveTranslationStrategy.defaultValue, .lowLatency)
  }

  // MARK: - Pack model

  func testRefreshBuildsOneRowPerWatchedLanguageInOrder() async {
    let speech = FakeSpeechInventory(["ko": .available, "ja": .installed])
    let translation = FakeTranslationInventory([
      "ko->zh-Hans": .available,
      "ja->zh-Hans": .installed,
    ])
    let model = makeModel(
      speech: speech, translation: translation, installer: FakeTranslationInstaller())

    await model.refresh(
      watched: [.korean, .japanese],
      target: .simplifiedChinese)

    XCTAssertEqual(model.rows.map(\.language.id), ["ko", "ja"])
    XCTAssertEqual(model.rows[0].speech, .available)
    XCTAssertEqual(model.rows[0].translation, .available)
    XCTAssertEqual(model.rows[1].speech, .installed)
    XCTAssertEqual(model.rows[1].translation, .installed)
    XCTAssertNil(model.rows[0].error)
  }

  func testRefreshDeduplicatesRepeatedLanguages() async {
    let model = makeModel(
      speech: FakeSpeechInventory(),
      translation: FakeTranslationInventory(),
      installer: FakeTranslationInstaller())

    await model.refresh(
      watched: [.korean, .japanese, .korean],
      target: .simplifiedChinese)

    XCTAssertEqual(model.rows.map(\.language.id), ["ko", "ja"])
  }

  func testRefreshReportsUnsupportedStatuses() async {    let speech = FakeSpeechInventory(["ko": .unsupported])
    let translation = FakeTranslationInventory(["ko->zh-Hans": .unsupported])
    let model = makeModel(
      speech: speech, translation: translation, installer: FakeTranslationInstaller())

    await model.refresh(watched: [.korean], target: .simplifiedChinese)

    XCTAssertEqual(model.rows.first?.speech, .unsupported)
    XCTAssertEqual(model.rows.first?.translation, .unsupported)
  }

  func testRefreshUsesNotNeededWhenSourceEqualsTarget() async {
    let model = makeModel(
      speech: FakeSpeechInventory(),
      translation: FakeTranslationInventory(),
      installer: FakeTranslationInstaller())

    await model.refresh(watched: [.simplifiedChinese], target: .simplifiedChinese)

    XCTAssertEqual(model.rows.first?.translation, .notNeeded)
  }

  func testInstallSpeechUpdatesTheRow() async {
    let speech = FakeSpeechInventory(["ko": .available])
    let model = makeModel(
      speech: speech,
      translation: FakeTranslationInventory(),
      installer: FakeTranslationInstaller())
    await model.refresh(watched: [.korean], target: .simplifiedChinese)

    await model.installSpeech(for: .korean)

    XCTAssertEqual(speech.installCount, 1)
    XCTAssertEqual(model.rows.first?.speech, .installed)
  }

  func testInstallSpeechFailureIsVisibleAndSurvivesUntilRefresh() async {
    let speech = FakeSpeechInventory(["ko": .available])
    speech.installError = LiveTranslationPackError.unsupportedLanguage("Korean")
    let model = makeModel(
      speech: speech,
      translation: FakeTranslationInventory(),
      installer: FakeTranslationInstaller())
    await model.refresh(watched: [.korean], target: .simplifiedChinese)

    await model.installSpeech(for: .korean)

    guard case .failed(let message) = model.rows.first?.speech else {
      return XCTFail("expected a failed speech status")
    }
    XCTAssertFalse(message.isEmpty)
    XCTAssertEqual(model.rows.first?.error, message)

    await model.refresh(watched: [.korean], target: .simplifiedChinese)
    XCTAssertNil(model.rows.first?.error)
  }

  func testInstallTranslationUpdatesTheRow() async {
    let translation = FakeTranslationInventory(["ko->zh-Hans": .available])
    let installer = FakeTranslationInstaller()
    installer.onInstall = { source, target in
      translation.statuses["\(source)->\(target)"] = .installed
    }
    let model = makeModel(
      speech: FakeSpeechInventory(),
      translation: translation,
      installer: installer)
    await model.refresh(watched: [.korean], target: .simplifiedChinese)

    await model.installTranslation(for: .korean)

    XCTAssertEqual(installer.installs.map { "\($0.0)->\($0.1)" }, ["ko->zh-Hans"])
    XCTAssertEqual(model.rows.first?.translation, .installed)
  }

  func testInstallTranslationIsSkippedWhenSourceEqualsTarget() async {
    let installer = FakeTranslationInstaller()
    let model = makeModel(
      speech: FakeSpeechInventory(),
      translation: FakeTranslationInventory(),
      installer: installer)
    await model.refresh(watched: [.simplifiedChinese], target: .simplifiedChinese)

    await model.installTranslation(for: .simplifiedChinese)

    XCTAssertTrue(installer.installs.isEmpty)
  }

  func testInstallTranslationFailureIsVisible() async {
    let installer = FakeTranslationInstaller()
    installer.installError = NSError(
      domain: "test", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Offline"])
    let model = makeModel(
      speech: FakeSpeechInventory(),
      translation: FakeTranslationInventory(["ko->zh-Hans": .available]),
      installer: installer)
    await model.refresh(watched: [.korean], target: .simplifiedChinese)

    await model.installTranslation(for: .korean)

    XCTAssertEqual(model.rows.first?.translation, .failed("Offline"))
    XCTAssertEqual(model.rows.first?.error, "Offline")
  }

  func testInstallAllMissingDownloadsOnlyMissingPacks() async {
    let speech = FakeSpeechInventory([
      "ko": .available,
      "ja": .installed,
      "fr": .available,
    ])
    let translation = FakeTranslationInventory([
      "ko->zh-Hans": .available,
      "ja->zh-Hans": .installed,
      "fr->zh-Hans": .unsupported,
    ])
    let installer = FakeTranslationInstaller()
    installer.onInstall = { source, target in
      translation.statuses["\(source)->\(target)"] = .installed
    }
    let model = makeModel(speech: speech, translation: translation, installer: installer)
    await model.refresh(
      watched: [.korean, .japanese, .french],
      target: .simplifiedChinese)

    await model.installAllMissing()

    XCTAssertEqual(speech.installCount, 2)
    XCTAssertEqual(installer.installs.map { "\($0.0)->\($0.1)" }, ["ko->zh-Hans"])
    XCTAssertEqual(model.rows.map(\.speech), [.installed, .installed, .installed])
    XCTAssertEqual(model.rows.map(\.translation), [.installed, .installed, .unsupported])
    XCTAssertFalse(model.isDownloadingAll)
  }

  func testCancelStopsTheDownloadAllSequence() async {
    let speech = BlockingSpeechInventory()
    let installer = FakeTranslationInstaller()
    let model = makeModel(
      speech: speech,
      translation: FakeTranslationInventory(),
      installer: installer)
    await model.refresh(watched: [.korean], target: .simplifiedChinese)

    let task = Task { await model.installAllMissing() }
    while speech.installCount == 0 {
      await Task.yield()
    }
    model.cancelDownloads()
    XCTAssertTrue(model.isDownloadingAll)
    XCTAssertEqual(installer.cancelCount, 1)

    speech.resume()
    await task.value

    XCTAssertFalse(model.isDownloadingAll)
    XCTAssertEqual(speech.installCount, 1)
  }

  // MARK: - System inventories

  func testSettingsPageBuildsWithoutLoadingSystemState() {
    let page = SettingsPageLiveTranslation()
    let view = page.getView()
    XCTAssertFalse(view.subviews.isEmpty)
    XCTAssertFalse(page.builtSections.isEmpty)
    XCTAssertEqual(page.title, "Live Translation")
  }

  func testSettingsKeysResolveToLocalizedText() {
    let ui = SettingsUIHelper.sharedUI
    for key in [
      "liveTranslation.label",
      "liveTranslation.target.label",
      "liveTranslation.packs.title",
      "liveTranslation.status.installed",
      "liveTranslation.audioAccess.open",
    ] {
      XCTAssertNotEqual(
        ui.localized(key), "settings.\(key)",
        "missing Base localization for settings.\(key)")
    }
  }

  func testSystemSpeechInventorySupportsTheWatchedLanguages() async throws {
    try XCTSkipUnless(SpeechTranscriber.isAvailable, "Speech models are unavailable")
    let inventory = SystemSpeechModelInventory()
    for language in [
      LiveTranslationLanguages.korean,
      LiveTranslationLanguages.japanese,
      LiveTranslationLanguages.french,
      LiveTranslationLanguages.italian,
    ] {
      let locale = await inventory.locale(for: language)
      XCTAssertNotNil(locale, "no supported speech locale for \(language.id)")
      let status = await inventory.status(for: language)
      XCTAssertNotEqual(
        status, .unsupported,
        "Speech reports \(language.id) as unsupported on this Mac")
    }
  }

  func testSystemTranslationInventorySupportsTheWatchedPairs() async {
    let inventory = SystemTranslationPackInventory()
    for language in [
      LiveTranslationLanguages.korean,
      LiveTranslationLanguages.japanese,
      LiveTranslationLanguages.french,
      LiveTranslationLanguages.italian,
    ] {
      let status = await inventory.status(
        from: language, to: .simplifiedChinese)
      XCTAssertNotEqual(
        status, .unsupported,
        "Translation reports \(language.id) → zh-Hans as unsupported on this Mac")
    }
  }

  func testSystemTranslationInventoryReportsNoTranslationForSameLanguage() async {
    let inventory = SystemTranslationPackInventory()
    let status = await inventory.status(
      from: .simplifiedChinese, to: .simplifiedChinese)
    XCTAssertEqual(status, .notNeeded)
  }
}
