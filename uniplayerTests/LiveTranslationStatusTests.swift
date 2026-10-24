//
//  LiveTranslationStatusTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

@MainActor
final class LiveTranslationStatusTests: XCTestCase {

  private func input(
    enabled: Bool = true,
    textSubtitleActive: Bool = false,
    isPlaying: Bool = true,
    resolution: LiveTranslationLanguageResolution? = .resolved(.korean, source: .trackMetadata),
    isTentativeLanguage: Bool = false,
    captureIsFile: Bool = false,
    anotherPlayerPlaying: Bool = false,
    permission: LiveTranslationAudioPermission.State = .unknown,
    transcriptionFailure: String? = nil,
    fallbackNotice: String? = nil,
    failure: String? = nil,
    usesAIProvider: Bool = false
  ) -> LiveTranslationStatusInput {
    LiveTranslationStatusInput(
      enabled: enabled, textSubtitleActive: textSubtitleActive,
      isPlaying: isPlaying,
      resolution: resolution,
      isTentativeLanguage: isTentativeLanguage,
      captureIsFile: captureIsFile,
      anotherPlayerPlaying: anotherPlayerPlaying,
      permission: permission,
      transcriptionFailure: transcriptionFailure,
      fileAudioFallback: fallbackNotice, captionFailure: failure,
      usesAIProvider: usesAIProvider)
  }

  func testOffState() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(enabled: false)), .off)
  }

  func testTextSubtitlePrecedence() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(textSubtitleActive: true)),
      .subtitlePrecedence)
  }

  func testResolvingBeforeTheLanguageIsKnown() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(resolution: nil)), .resolving)
  }

  func testNeedsChoiceState() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(resolution: .needsChoice(
        candidates: [.korean, .english]))),
      .chooseLanguage)
  }

  func testTentativeLanguageIsShownAsChecking() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(
        resolution: .needsChoice(candidates: [.korean, .english]),
        isTentativeLanguage: true)),
      .checkingLanguage)
  }

  func testSourceEqualsTargetState() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(resolution: .skip(.english))),
      .nothingToTranslate)
  }

  func testNoWatchedLanguagesState() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(resolution: .unsupported(.noWatchedLanguages))),
      .noWatchedLanguages)
  }

  func testSpeechModelMissingState() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(
        resolution: .unsupported(.speechModelUnavailable(.japanese)))),
      .speechModelMissing(LiveTranslationLanguages.japanese.displayName))
  }

  func testUnsupportedLanguageState() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(
        resolution: .unsupported(.unrecognizedTag("de")))),
      .unsupportedLanguage("de"))
  }

  func testCaptionFailureTakesPriorityOverPermission() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(
        permission: .denied, failure: "missing pack")),
      .captionFailure("missing pack"))
    XCTAssertEqual(
      LiveTranslationStatus.state(input(permission: .denied)),
      .permissionDenied)
  }

  func testWorkingFallbackExplainsPermissionSuspicion() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(
        permission: .suspected,
        fallbackNotice: "System audio was unavailable; translating from the file audio track.")),
      .fileAudioFallback(
        "System audio was unavailable; translating from the file audio track."))
    XCTAssertEqual(
      LiveTranslationStatus.state(input(permission: .suspected)),
      .permissionSuspected)
  }

  func testCaptionFailureIsSurfaced() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(failure: "The pack is not installed.")),
      .captionFailure("The pack is not installed."))
  }

  func testPausedState() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(isPlaying: false)), .paused)
    // A missing language prompt still wins over the paused notice.
    XCTAssertEqual(
      LiveTranslationStatus.state(input(
        isPlaying: false,
        resolution: .needsChoice(candidates: [.korean]))),
      .chooseLanguage)
  }

  func testTranscriptionFailureIsSurfaced() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(
        transcriptionFailure: "The Japanese speech model is not installed.")),
      .transcriptionFailure("The Japanese speech model is not installed."))
  }

  func testSuspectedPermissionIsDistinctFromDenied() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(permission: .suspected)),
      .permissionSuspected)
  }

  func testFileBackedSessionIgnoresSystemAudioPermission() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(
        captureIsFile: true, permission: .suspected)),
      .translating)
  }

  func testAnotherAudiblePlayerBlocksTheCaption() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(anotherPlayerPlaying: true)),
      .otherPlayerActive)
  }

  func testFileFallbackNoticeIsSurfaced() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(
        fallbackNotice: "Playback is muted; translating from the file audio track.")),
      .fileAudioFallback(
        "Playback is muted; translating from the file audio track."))
  }

  func testTranscriptionFailureBeatsCaptionFailure() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(
        transcriptionFailure: "speech failed", failure: "caption failed")),
      .transcriptionFailure("speech failed"))
  }

  func testTranslatingState() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input()), .translating)
  }

  func testAIProviderRouteIsDistinct() {
    XCTAssertEqual(
      LiveTranslationStatus.state(input(usesAIProvider: true)),
      .translatingViaAI)
  }

  func testEveryStateHasText() {
    let target = LiveTranslationLanguages.english
    let states: [LiveTranslationAvailabilityState] = [
      .off, .subtitlePrecedence, .resolving, .chooseLanguage,
      .checkingLanguage, .otherPlayerActive, .nothingToTranslate, .noWatchedLanguages,
      .unsupportedLanguage("de"), .speechModelMissing("Japanese"),
      .permissionDenied, .permissionSuspected, .paused,
      .transcriptionFailure("speech failed"),
      .fileAudioFallback("using the file track"),
      .captionFailure("failed"), .translating, .translatingViaAI,
    ]
    for state in states {
      XCTAssertFalse(
        LiveTranslationStatus.text(state, target: target).isEmpty,
        "missing text for \(state)")
    }
  }

  func testSettingsDestination() {
    XCTAssertTrue(LiveTranslationStatus.opensSettings(.noWatchedLanguages))
    XCTAssertTrue(LiveTranslationStatus.opensSettings(
      .speechModelMissing("Japanese")))
    XCTAssertTrue(LiveTranslationStatus.opensSettings(
      .unsupportedLanguage("de")))
    XCTAssertTrue(LiveTranslationStatus.opensSettings(
      .transcriptionFailure("speech failed")))
    XCTAssertTrue(LiveTranslationStatus.opensSettings(
      .fileAudioFallback("using the file track")))
    XCTAssertFalse(LiveTranslationStatus.opensSettings(.off))
    XCTAssertFalse(LiveTranslationStatus.opensSettings(.subtitlePrecedence))
    XCTAssertFalse(LiveTranslationStatus.opensSettings(.permissionDenied))
    XCTAssertFalse(LiveTranslationStatus.opensSettings(.permissionSuspected))
  }

  func testNewStatusStringsExistInBothLocalizationTables() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    for table in ["Base", "en"] {
      let url = root.appendingPathComponent(
        "uniplayer/\(table).lproj/Localizable.strings")
      let text = try String(contentsOf: url, encoding: .utf8)
      for key in ["Checking the spoken language…",
                  "Speech recognition stopped."] {
        XCTAssertTrue(
          text.contains("\"\(key)\" ="), "\(table) is missing \(key)")
      }
    }
  }
}
