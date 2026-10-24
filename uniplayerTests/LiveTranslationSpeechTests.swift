//
//  LiveTranslationSpeechTests.swift
//  UniPlayerTests
//

import AVFoundation
import Speech
import XCTest
@testable import UniPlayer

@MainActor
final class LiveTranslationSpeechTests: XCTestCase {

  private final class BlockingProvider: AssistantProvider, @unchecked Sendable {
    let identifier = "test"
    private let lock = NSLock()
    private var count = 0

    var streams: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }

    func stream(
      _ request: AssistantRequest,
      configuration: AssistantConfiguration
    ) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
      lock.lock()
      count += 1
      lock.unlock()
      // Never finishes on its own; only cancellation can end the wait.
      return AsyncThrowingStream { _ in }
    }
  }

  private final class ImmediateProvider: AssistantProvider {
    let identifier = "immediate"

    func stream(
      _ request: AssistantRequest,
      configuration: AssistantConfiguration
    ) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
      AsyncThrowingStream { continuation in
        continuation.yield(.text("Corrected line."))
        continuation.finish()
      }
    }
  }

  private func format() -> AVAudioFormat {
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000, channels: 1, interleaved: false)!
  }

  func testNormalizerCollapsesWhitespace() {
    XCTAssertEqual(
      SpeechTextNormalizer.normalize("  Hello   world  "),
      "Hello world")
    XCTAssertEqual(SpeechTextNormalizer.normalize(" \n\t "), "")
  }

  func testAssistantCancellationResumesTheAwaitingTask() async {
    let provider = BlockingProvider()
    let service = AssistantService(providerFactory: { _ in provider })
    let client = AssistantTextClient(
      service: service,
      configuration: {
        AssistantConfiguration(
          provider: .openAICompatible,
          endpoint: "http://localhost:11434/v1",
          model: "test", apiKey: nil)
      })
    let task = Task { try await client.complete(system: "system", user: "user") }
    try? await Task.sleep(for: .milliseconds(100))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
      // Expected: the checked continuation is resumed instead of leaking.
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(provider.streams, 1)
  }

  func testAlreadyCancelledAssistantRequestDoesNotStart() async {
    let provider = BlockingProvider()
    let service = AssistantService(providerFactory: { _ in provider })
    let client = AssistantTextClient(
      service: service,
      configuration: {
        AssistantConfiguration(
          provider: .openAICompatible,
          endpoint: "http://localhost:11434/v1",
          model: "test", apiKey: nil)
      })
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await client.complete(system: "system", user: "user")
    }
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(provider.streams, 0)
  }

  func testCaptionRepairerRoundTripThroughTheAssistantService() async throws {
    let service = AssistantService(providerFactory: { _ in ImmediateProvider() })
    let client = AssistantTextClient(
      service: service,
      configuration: {
        AssistantConfiguration(
          provider: .openAICompatible,
          endpoint: "http://localhost:11434/v1",
          model: "test", apiKey: nil)
      })
    let repairer = AssistantCaptionRepairer(client: client)
    let corrected = try await repairer.repair(
      source: "Pay 45 dollars.", candidate: "Pay dollars.",
      glossary: [], targetLanguage: "English")
    XCTAssertEqual(corrected, "Corrected line.")
  }

  func testNormalizerRemovesSpacesAroundCJKCharacters() {
    XCTAssertEqual(
      SpeechTextNormalizer.normalize("你 好 ， 世 界 ！"),
      "你好，世界！")
    XCTAssertEqual(
      SpeechTextNormalizer.normalize("こんにちは 、 世界"),
      "こんにちは、世界")
    XCTAssertEqual(
      SpeechTextNormalizer.normalize("안녕하세요 , 반갑습니다"),
      "안녕하세요, 반갑습니다")
  }

  func testNormalizerKeepsLatinWordSpacing() {
    XCTAssertEqual(
      SpeechTextNormalizer.normalize("Bonjour,  comment allez-vous ?"),
      "Bonjour, comment allez-vous?")
    XCTAssertEqual(
      SpeechTextNormalizer.normalize("你好 world"),
      "你好 world")
  }

  func testNormalizerHandlesOpeningPunctuation() {
    XCTAssertEqual(
      SpeechTextNormalizer.normalize("他说： 「 你好 」"),
      "他说：「你好」")
  }

  func testUnsupportedLocaleFailsBeforeCreatingAnAnalyzer() async {
    let language = LiveTranslationLanguage(
      id: "xx", speechIdentifier: "xx-XX", translationIdentifier: "xx")
    let session = SpeechAnalyzerSession()
    do {
      try await session.start(language: language, audioFormat: format())
      XCTFail("expected an unsupported locale")
    } catch SpeechRecognitionError.unsupportedLocale {
      // Expected.
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(session.state, .failed(
      SpeechRecognitionError.unsupportedLocale(language.displayName).localizedDescription))
  }

  func testMissingSpeechModelFailsExplicitly() async throws {
    let supported = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: "ja-JP")) != nil
    try XCTSkipUnless(supported, "Japanese speech is not supported on this Mac")
    let installed = await SpeechTranscriber.installedLocales
    try XCTSkipIf(
      installed.contains(where: { $0.identifier.hasPrefix("ja") }),
      "Japanese speech is already installed")

    let session = SpeechAnalyzerSession()
    do {
      try await session.start(
        language: LiveTranslationLanguage.japanese, audioFormat: format())
      XCTFail("expected a missing model")
    } catch SpeechRecognitionError.modelMissing {
      // Expected.
    } catch SpeechRecognitionError.modelDownloading {
      // A system download from another task is also an honest refusal.
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }
}
