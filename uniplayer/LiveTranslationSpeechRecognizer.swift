//
//  LiveTranslationSpeechRecognizer.swift
//  uniplayer
//
//  On-device volatile and final transcription with SpeechAnalyzer. The
//  recognizer owns one analyzer for one locale; callers create a new session
//  after a seek or a locale change.
//

import AVFoundation
import CoreMedia
import Foundation
import Speech

struct SpeechRecognitionUpdate: Equatable {
  let text: String
  let isFinal: Bool
  let range: CMTimeRange
  let confidence: Double?
}

enum SpeechRecognitionState: Equatable {
  case idle
  case preparing
  case running
  case finished
  case failed(String)
}

enum SpeechRecognitionError: LocalizedError, Equatable {
  case alreadyRunning
  case notRunning
  case unsupportedLocale(String)
  case modelMissing(String)
  case modelDownloading(String)

  var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      return NSLocalizedString(
        "Speech recognition is already running.", comment: "Live translation speech error")
    case .notRunning:
      return NSLocalizedString(
        "Speech recognition is not running.", comment: "Live translation speech error")
    case .unsupportedLocale(let language):
      return String(format: NSLocalizedString(
        "Speech recognition does not support %@.", comment: "Live translation speech error"),
        language)
    case .modelMissing(let language):
      return String(format: NSLocalizedString(
        "The %@ speech model is not installed.", comment: "Live translation speech error"),
        language)
    case .modelDownloading(let language):
      return String(format: NSLocalizedString(
        "The %@ speech model is still downloading.", comment: "Live translation speech error"),
        language)
    }
  }
}

protocol SpeechRecognizing: AnyObject {
  var updates: AsyncStream<SpeechRecognitionUpdate> { get }
  var state: SpeechRecognitionState { get }
  func start(language: LiveTranslationLanguage, audioFormat: AVAudioFormat) async throws
  func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) throws
  func flush() async throws
  func cancel()
}

/// Normalizes punctuation and whitespace before display and translation.
/// Speech results often contain spaces before Chinese punctuation and between
/// CJK characters that no reader wants to see.
enum SpeechTextNormalizer {
  // Kana and Han characters, deliberately excluding Hangul: Korean uses
  // spaces between words, so removing them would join separate words.
  private static let cjkHan =
    "\u{3040}-\u{30FF}\u{3400}-\u{4DBF}\u{4E00}-\u{9FFF}\u{F900}-\u{FAFF}"
  private static let cjkPunctuation = "，。！？、；：）】」』》"
  private static let cjkOpening = "（【「『《"

  static func normalize(_ text: String) -> String {
    var value = text
      .replacingOccurrences(of: "\\s+", with: " ",
                            options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return "" }

    // No space before ASCII punctuation; a space after it remains, which is
    // correct for Latin and Korean prose.
    value = value.replacingOccurrences(
      of: "\\s+([,.;:!?])", with: "$1",
      options: .regularExpression)

    // Full-width CJK punctuation takes no spaces on either side.
    value = value.replacingOccurrences(
      of: "\\s+([\(cjkPunctuation)])", with: "$1",
      options: .regularExpression)
    value = value.replacingOccurrences(
      of: "([\(cjkOpening)\(cjkPunctuation)])\\s+", with: "$1",
      options: .regularExpression)

    // Han/kana sequences never need inter-character spaces.
    value = value.replacingOccurrences(
      of: "(?<=[\(cjkHan)])\\s+(?=[\(cjkHan)])", with: "",
      options: .regularExpression)
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

final class SpeechAnalyzerSession: SpeechRecognizing {
  let updates: AsyncStream<SpeechRecognitionUpdate>

  private let updateContinuation:
    AsyncStream<SpeechRecognitionUpdate>.Continuation
  private let stateLock = NSLock()
  private let feedLock = NSLock()

  private var _state: SpeechRecognitionState = .idle
  var state: SpeechRecognitionState {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _state
  }

  private var analyzer: SpeechAnalyzer?
  private var transcriber: SpeechTranscriber?
  private var converter: AnalyzerInputConverter?
  private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
  private var resultsTask: Task<Void, Never>?

  init() {
    let (stream, continuation) = AsyncStream<SpeechRecognitionUpdate>.makeStream(
      bufferingPolicy: .bufferingNewest(32))
    self.updates = stream
    self.updateContinuation = continuation
  }

  deinit {
    resultsTask?.cancel()
    updateContinuation.finish()
  }

  func start(language: LiveTranslationLanguage,
             audioFormat: AVAudioFormat) async throws {
    guard state == .idle else { throw SpeechRecognitionError.alreadyRunning }
    setState(.preparing)

    guard let locale = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: language.speechIdentifier)) else {
      let error = SpeechRecognitionError.unsupportedLocale(language.displayName)
      setState(.failed(error.localizedDescription))
      throw error
    }
    let transcriber = SpeechTranscriber(
      locale: locale, preset: .progressiveTranscription)
    switch await AssetInventory.status(forModules: [transcriber]) {
    case .installed:
      break
    case .supported:
      let error = SpeechRecognitionError.modelMissing(language.displayName)
      setState(.failed(error.localizedDescription))
      throw error
    case .downloading:
      let error = SpeechRecognitionError.modelDownloading(language.displayName)
      setState(.failed(error.localizedDescription))
      throw error
    case .unsupported:
      let error = SpeechRecognitionError.unsupportedLocale(language.displayName)
      setState(.failed(error.localizedDescription))
      throw error
    @unknown default:
      let error = SpeechRecognitionError.unsupportedLocale(language.displayName)
      setState(.failed(error.localizedDescription))
      throw error
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
      compatibleWith: [transcriber], considering: audioFormat) ?? audioFormat
    let converter = AnalyzerInputConverter(analyzerFormat: bestFormat)
    let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream(
      bufferingPolicy: .bufferingNewest(32))

    self.analyzer = analyzer
    self.transcriber = transcriber
    self.converter = converter
    self.inputBuilder = builder

    resultsTask = Task { [weak self] in
      guard let self else { return }
      do {
        for try await result in transcriber.results {
          self.emit(result)
        }
        Logger.log("Live translation ASR results ended", level: .debug)
        self.finishUpdates()
      } catch is CancellationError {
        self.finishUpdates()
      } catch {
        Logger.log("Live translation ASR failed: \(error.localizedDescription)",
                   level: .debug)
        self.setFailed(error.localizedDescription)
        self.finishUpdates()
      }
    }

    do {
      try await analyzer.start(inputSequence: inputSequence)
      setState(.running)
    } catch {
      setState(.failed(error.localizedDescription))
      throw error
    }
  }

  func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) throws {
    guard state == .running else {
      throw SpeechRecognitionError.notRunning
    }
    feedLock.lock()
    defer { feedLock.unlock() }
    guard let converter, let inputBuilder else {
      throw SpeechRecognitionError.notRunning
    }
    for input in try converter.convert(buffer, at: time) {
      inputBuilder.yield(input)
    }
  }

  func flush() async throws {
    guard state == .running else {
      throw SpeechRecognitionError.notRunning
    }
    feedLock.lock()
    guard let converter, let inputBuilder else {
      feedLock.unlock()
      throw SpeechRecognitionError.notRunning
    }
    do {
      for input in try converter.flush() {
        inputBuilder.yield(input)
      }
    } catch {
      feedLock.unlock()
      throw error
    }
    inputBuilder.finish()
    self.inputBuilder = nil
    feedLock.unlock()
    // The results stream can end before finalize returns. Mark the session as
    // intentionally finishing so the controller does not report an unexpected
    // stop during a normal EOF flush.
    setState(.finished)

    guard let analyzer else {
      throw SpeechRecognitionError.notRunning
    }
    do {
      try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
      setState(.failed(error.localizedDescription))
      throw error
    }
  }

  func cancel() {
    feedLock.lock()
    inputBuilder?.finish()
    inputBuilder = nil
    feedLock.unlock()
    let pendingAnalyzer = analyzer
    analyzer = nil
    resultsTask?.cancel()
    resultsTask = nil
    setState(.finished)
    finishUpdates()
    Task {
      await pendingAnalyzer?.cancelAndFinishNow()
    }
  }

  // MARK: - Results

  private func emit(_ result: SpeechTranscriber.Result) {
    let text = SpeechTextNormalizer.normalize(String(result.text.characters))
    updateContinuation.yield(SpeechRecognitionUpdate(
      text: text,
      isFinal: result.isFinal,
      range: result.range,
      confidence: Self.confidence(in: result.text)))
  }

  private func finishUpdates() {
    updateContinuation.finish()
  }

  private static func confidence(in text: AttributedString) -> Double? {
    var values: [Double] = []
    for run in text.runs {
      if let value = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
        values.append(value)
      }
    }
    return values.min()
  }

  private func setState(_ state: SpeechRecognitionState) {
    stateLock.lock()
    _state = state
    stateLock.unlock()
  }

  private func setFailed(_ message: String) {
    setState(.failed(message))
  }
}
