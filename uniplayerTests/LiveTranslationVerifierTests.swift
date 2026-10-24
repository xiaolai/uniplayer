//
//  LiveTranslationVerifierTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

@MainActor
final class LiveTranslationVerifierTests: XCTestCase {

  private let verifier = CaptionVerifier()

  private func verify(_ source: String, _ target: String,
                      confidence: Double? = 0.9,
                      glossary: [LiveTranslationGlossaryTerm] = []) -> Set<CaptionVerificationFlag> {
    verifier.verify(
      source: source, target: target,
      confidence: confidence, glossary: glossary).flags
  }

  // MARK: - Deterministic checks

  func testCleanLineHasNoFlags() {
    XCTAssertTrue(verify("The weather is nice today.", "今天天气很好。").isEmpty)
  }

  func testMissingNumberIsFlagged() {
    XCTAssertTrue(verify("The train leaves at 9:45.", "火车开走了。").contains(.numberMismatch))
    XCTAssertFalse(verify("The train leaves at 9:45.", "火车9:45开。").contains(.numberMismatch))
  }

  func testMissingDateIsFlagged() {
    XCTAssertTrue(verify("The meeting is on 2026-10-24.", "会议在今天。").contains(.dateMismatch))
  }

  func testMissingUnitSymbolIsFlagged() {
    XCTAssertTrue(verify("It is 30°C outside.", "外面很热。").contains(.unitMismatch))
    XCTAssertFalse(verify("It is 30°C outside.", "外面30°C。").contains(.unitMismatch))
  }

  func testDroppedNegationIsFlagged() {
    XCTAssertTrue(verify("I do not want it.", "我想要。").contains(.negationDropped))
    XCTAssertTrue(verify("不要走。", "Go.").contains(.negationDropped))
    XCTAssertFalse(verify("I do not want it.", "I don't want it.").contains(.negationDropped))
    XCTAssertFalse(verify("The north is cold.", "北方很冷。").contains(.negationDropped))
  }

  func testMissingAcronymIsFlagged() {
    XCTAssertTrue(verify("NASA launched the mission.", "任务发射了。").contains(.acronymMismatch))
    XCTAssertFalse(verify("NASA launched the mission.", "NASA发射了任务。").contains(.acronymMismatch))
  }

  func testGlossaryTermIsEnforced() {
    let glossary = [LiveTranslationGlossaryTerm(source: "OpenAI", target: "OpenAI")]
    XCTAssertTrue(verify("OpenAI released a model.", "一家公司发布了模型。", glossary: glossary)
      .contains(.glossaryMismatch))
    XCTAssertFalse(verify("OpenAI released a model.", "OpenAI 发布了模型。", glossary: glossary)
      .contains(.glossaryMismatch))
  }

  func testLowConfidenceIsFlagged() {
    XCTAssertTrue(verify("hello", "你好", confidence: 0.3).contains(.lowConfidence))
    XCTAssertFalse(verify("hello", "你好", confidence: 0.9).contains(.lowConfidence))
  }

  func testNumbersAreNormalized() {
    XCTAssertFalse(verify("There are 1,000 people.", "有1000人。").contains(.numberMismatch))
    XCTAssertFalse(verify("Pi is 3.14.", "圆周率是3.14。").contains(.numberMismatch))
  }

  func testNumbersWrittenAsWordsMatchDigits() {
    XCTAssertFalse(verify("There are 3 people.", "有三个人。").contains(.numberMismatch))
    XCTAssertFalse(verify("I have two apples.", "我有两个苹果。").contains(.numberMismatch))
    XCTAssertFalse(verify("他有三十七个人。", "He has 37 people.").contains(.numberMismatch))
    XCTAssertFalse(verify("这里有一百零二人。", "There are 102 people.")
      .contains(.numberMismatch))
    XCTAssertTrue(verify("There are 3 people.", "有一个人。").contains(.numberMismatch))
    XCTAssertTrue(verify("There are two apples.", "有五个苹果。").contains(.numberMismatch))
  }

  func testDateWithMonthNameIsNotFlagged() {
    XCTAssertFalse(verify("The meeting is on 2026-10-24.",
                          "会议在2026年10月24日。").contains(.dateMismatch))
    XCTAssertFalse(verify("The meeting is on 2026-10-24.",
                          "The meeting is on October 24, 2026.").contains(.dateMismatch))
    XCTAssertFalse(verify("The meeting is on 2026-10-24.",
                          "会议在2026年10月24日。").contains(.numberMismatch))
    XCTAssertTrue(verify("The meeting is on 2026-10-24.",
                         "会议在2026年10月25日。").contains(.dateMismatch))
  }

  func testChangedMonthInANumericDateIsFlagged() {
    XCTAssertTrue(verify("The meeting is on 2026-10-24.",
                         "会议在2026年11月24日。").contains(.dateMismatch))
    XCTAssertTrue(verify("The meeting is on 2026-10-24.",
                         "会议在24/11/2026。").contains(.dateMismatch))
    XCTAssertFalse(verify("The meeting is on 2026-10-24.",
                          "会议在24/10/2026。").contains(.dateMismatch))
    XCTAssertFalse(verify("The meeting is on 05/06/2026.",
                          "会议在2026-06-05。").contains(.dateMismatch))
  }

  func testSignedAndDecimalCommaNumbers() {
    XCTAssertTrue(verify("The value is -5.", "价值是5。")
      .contains(.numberMismatch))
    XCTAssertFalse(verify("The value is 1,5.", "价值是1.5。")
      .contains(.numberMismatch))
    XCTAssertFalse(verify("The value is 1.5.", "价值是1,5。")
      .contains(.numberMismatch))
  }

  func testLocaleAwareDecimalSeparators() {
    let french = CaptionVerifier()
    french.setLanguages(source: "fr", target: "en")
    XCTAssertFalse(french.verify(
      source: "La valeur est 1,234.",
      target: "The value is 1.234.",
      confidence: 0.9, glossary: []).flags.contains(.numberMismatch))
    XCTAssertFalse(french.verify(
      source: "La valeur est 1 234,5.",
      target: "The value is 1,234.5.",
      confidence: 0.9, glossary: []).flags.contains(.numberMismatch))

    let english = CaptionVerifier()
    english.setLanguages(source: "en", target: "fr")
    XCTAssertFalse(english.verify(
      source: "The value is 1,234.",
      target: "La valeur est 1 234.",
      confidence: 0.9, glossary: []).flags.contains(.numberMismatch))
    XCTAssertTrue(english.verify(
      source: "There are 1,234 people.",
      target: "Il y a 1,234 personnes.",
      confidence: 0.9, glossary: []).flags.contains(.numberMismatch))
  }

  func testChineseNumeralInAnIdiomIsNotANumber() {
    XCTAssertFalse(verify("一起走吧。", "Let's go together.")
      .contains(.numberMismatch))
    XCTAssertFalse(verify("十分钟后见。", "See you in ten minutes.")
      .contains(.numberMismatch))
    XCTAssertFalse(verify("我只有一块钱。", "I only have one yuan.")
      .contains(.numberMismatch))
    XCTAssertTrue(verify("有三个人。", "There are 2 people.")
      .contains(.numberMismatch))
  }

  func testTwoDatesMustBothBePresent() {
    let source = "It runs from 2026-10-24 to 2026-11-24."
    let target = "从2026年10月24日到2026年11月24日。"
    XCTAssertFalse(verify(source, target).contains(.dateMismatch))
    XCTAssertTrue(verify(source, "从2026年10月24日到2026年12月24日。")
      .contains(.dateMismatch))
  }

  func testBackTranslationComparison() {
    let comparison = BackTranslationComparison()
    XCTAssertTrue(comparison.flags(source: "Pay 45 dollars.", backTranslated: "Pay dollars.")
      .contains(.backTranslationMismatch))
    XCTAssertTrue(comparison.flags(source: "NASA said so.", backTranslated: "They said so.")
      .contains(.backTranslationMismatch))
    XCTAssertTrue(comparison.flags(source: "Pay 45 dollars.", backTranslated: "Pay 45 dollars.")
      .isEmpty)
  }

  // MARK: - Repair gate

  private final class FlaggedVerifier: CaptionVerifying {
    var flags: Set<CaptionVerificationFlag> = [.numberMismatch]

    func verify(source: String, target: String, confidence: Double?,
                glossary: [LiveTranslationGlossaryTerm]) -> CaptionVerification {
      CaptionVerification(flags: flags)
    }
  }

  private final class CountingRepairer: LiveTranslationRepairing {
    var calls = 0
    var result = "corrected"

    func repair(source: String, candidate: String,
                glossary: [LiveTranslationGlossaryTerm],
                targetLanguage: String) async throws -> String {
      calls += 1
      return result
    }
  }

  func testCleanLineNeverCallsTheRepairer() async {
    let repairer = CountingRepairer()
    let coordinator = LiveTranslationRepairCoordinator(
      verifier: CaptionVerifier(), repairer: repairer, isEnabled: { true })
    let corrected = await coordinator.repairIfNeeded(
      source: "hello", target: "你好", confidence: 0.9, isFinal: true,
      glossary: [], targetLanguage: "Chinese")
    XCTAssertNil(corrected)
    XCTAssertEqual(repairer.calls, 0)
  }

  func testFlaggedFinalLineCallsTheRepairer() async {
    let verifier = FlaggedVerifier()
    let repairer = CountingRepairer()
    let coordinator = LiveTranslationRepairCoordinator(
      verifier: verifier, repairer: repairer, isEnabled: { true })
    let corrected = await coordinator.repairIfNeeded(
      source: "Pay 45 dollars.", target: "Pay dollars.", confidence: 0.9,
      isFinal: true, glossary: [], targetLanguage: "English")
    XCTAssertEqual(corrected, "corrected")
    XCTAssertEqual(repairer.calls, 1)
  }

  func testOnlyLowConfidenceOnVolatileLineDoesNotRepair() async {
    let verifier = FlaggedVerifier()
    verifier.flags = [.lowConfidence]
    let repairer = CountingRepairer()
    let coordinator = LiveTranslationRepairCoordinator(
      verifier: verifier, repairer: repairer, isEnabled: { true })
    let corrected = await coordinator.repairIfNeeded(
      source: "hello", target: "你好", confidence: 0.2, isFinal: false,
      glossary: [], targetLanguage: "Chinese")
    XCTAssertNil(corrected)
    XCTAssertEqual(repairer.calls, 0)
  }

  func testRepairOffLeavesTheFirstPass() async {
    let repairer = CountingRepairer()
    let coordinator = LiveTranslationRepairCoordinator(
      verifier: FlaggedVerifier(), repairer: repairer, isEnabled: { false })
    let corrected = await coordinator.repairIfNeeded(
      source: "Pay 45 dollars.", target: "Pay dollars.", confidence: 0.9,
      isFinal: true, glossary: [], targetLanguage: "English")
    XCTAssertNil(corrected)
    XCTAssertEqual(repairer.calls, 0)
  }

  func testRepairBudgetStopsAfterTheLimit() async {
    let repairer = CountingRepairer()
    let coordinator = LiveTranslationRepairCoordinator(
      verifier: FlaggedVerifier(), repairer: repairer,
      budget: LiveTranslationRepairBudget(maximumAttempts: 1, window: 60),
      isEnabled: { true })
    let first = await coordinator.repairIfNeeded(
      source: "Pay 45 dollars.", target: "Pay dollars.", confidence: 0.9,
      isFinal: true, glossary: [], targetLanguage: "English")
    let second = await coordinator.repairIfNeeded(
      source: "Pay 45 dollars.", target: "Pay dollars.", confidence: 0.9,
      isFinal: true, glossary: [], targetLanguage: "English")
    XCTAssertEqual(first, "corrected")
    XCTAssertNil(second)
    XCTAssertEqual(repairer.calls, 1)
  }

  // MARK: - Glossary store

  func testGlossaryStorePersistsCorrectionsPerShow() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translation-glossary-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = LiveTranslationGlossaryStore(fileURL: url)
    store.setCorrection(
      source: "OpenAI", target: "开放人工智能", showKey: "show:a",
      sourceLanguageID: "en", targetLanguageID: "zh-Hans")
    XCTAssertEqual(
      store.correction(
        for: "openai", showKey: "show:a",
        sourceLanguageID: "en", targetLanguageID: "zh-Hans"),
      "开放人工智能")
    XCTAssertNil(store.correction(
      for: "openai", showKey: "show:b",
      sourceLanguageID: "en", targetLanguageID: "zh-Hans"))
    XCTAssertEqual(store.terms(
      for: "show:a", sourceLanguageID: "en", targetLanguageID: "zh-Hans").count, 1)

    let reloaded = LiveTranslationGlossaryStore(fileURL: url)
    XCTAssertEqual(
      reloaded.correction(
        for: "OpenAI", showKey: "show:a",
        sourceLanguageID: "en", targetLanguageID: "zh-Hans"),
      "开放人工智能")

    reloaded.setCorrection(
      source: "OpenAI", target: nil, showKey: "show:a",
      sourceLanguageID: "en", targetLanguageID: "zh-Hans")
    XCTAssertNil(reloaded.correction(
      for: "OpenAI", showKey: "show:a",
      sourceLanguageID: "en", targetLanguageID: "zh-Hans"))
  }

  func testGlossaryCorrectionsAreScopedToTheLanguagePair() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translation-glossary-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = LiveTranslationGlossaryStore(fileURL: url)
    store.setCorrection(
      source: "OpenAI", target: "开放人工智能", showKey: "show:a",
      sourceLanguageID: "en", targetLanguageID: "zh-Hans")
    XCTAssertNil(store.correction(
      for: "OpenAI", showKey: "show:a",
      sourceLanguageID: "en", targetLanguageID: "fr"))
    XCTAssertTrue(store.terms(
      for: "show:a", sourceLanguageID: "en", targetLanguageID: "fr").isEmpty)
  }

  func testLegacyGlossaryWithoutAPairIsIgnored() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translation-glossary-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let legacy = #"{"show:a":{"openai":"旧翻译"}}"#
    try Data(legacy.utf8).write(to: url)

    let store = LiveTranslationGlossaryStore(fileURL: url)
    XCTAssertTrue(store.terms(
      for: "show:a", sourceLanguageID: "en", targetLanguageID: "zh-Hans").isEmpty)
  }

  func testRepairBudgetWindowExpires() {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let budget = LiveTranslationRepairBudget(maximumAttempts: 1, window: 60)
    XCTAssertTrue(budget.allow(now: start))
    XCTAssertFalse(budget.allow(now: start.addingTimeInterval(1)))
    XCTAssertTrue(budget.allow(now: start.addingTimeInterval(61)))
  }
}
