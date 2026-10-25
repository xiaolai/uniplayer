//
//  AssistantLiveTranslation.swift
//  uniplayer
//
//  The AI provider's only live-translation roles: a fallback for an
//  unsupported pair, and repair of a deterministic-verifier flag. Ordinary
//  captions never call it.
//

import Foundation

final class AssistantTextClient {
  typealias OneShotAnswer = (TranslationSource, String, String) async throws -> String

  private let service: AssistantService
  private let configuration: () -> AssistantConfiguration
  private let source: () -> TranslationSource
  private let oneShotAnswer: OneShotAnswer

  init(service: AssistantService = AssistantService(),
       configuration: @escaping () -> AssistantConfiguration = { .load() },
       source: @escaping () -> TranslationSource = { TranslationSettings.liveSource },
       oneShotAnswer: @escaping OneShotAnswer = { source, system, user in
         try await SaySoTranslation.plain(source: source, system: system, user: user)
       }) {
    self.service = service
    self.configuration = configuration
    self.source = source
    self.oneShotAnswer = oneShotAnswer
  }

  /// Resumes exactly once even when cancellation races the stream's callbacks.
  /// `AssistantService.cancel()` suppresses its own callbacks by bumping a
  /// generation, so the checked continuation must be finished here or the
  /// awaiting task would leak forever.
  private final class CompletionBox {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var pending: Result<String, Error>?
    private var text = ""
    private var finished = false

    var isFinished: Bool {
      lock.lock()
      defer { lock.unlock() }
      return finished
    }

    func attach(_ continuation: CheckedContinuation<String, Error>) {
      lock.lock()
      if let pending {
        self.pending = nil
        lock.unlock()
        continuation.resume(with: pending)
        return
      }
      self.continuation = continuation
      lock.unlock()
    }

    /// False when the operation was already cancelled/finished before the
    /// request could start. A canceled caption must never open a provider
    /// request.
    func begin() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return !finished
    }

    func append(_ delta: String) {
      lock.lock()
      text += delta
      lock.unlock()
    }

    func finish(_ result: Result<String, Error>) {
      lock.lock()
      finished = true
      if let continuation {
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return
      }
      if pending == nil {
        pending = result
      }
      lock.unlock()
    }

    func finishSuccessfully() {
      lock.lock()
      let value = text
      lock.unlock()
      finish(.success(value))
    }
  }

  private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?

    var value: UUID? {
      get {
        lock.lock()
        defer { lock.unlock() }
        return token
      }
      set {
        lock.lock()
        token = newValue
        lock.unlock()
      }
    }
  }

  func complete(system: String, user: String) async throws -> String {
    let source = source()
    if source != .assistant {
      // The on-device source answers one composed question; a CLI selection
      // never reaches here because `TranslationSettings.liveSource` falls back
      // to the assistant.
      return try await oneShotAnswer(source, system, user)
    }
    let configuration = configuration()
    guard configuration.isConfigured else {
      throw AssistantError.notConfigured
    }
    let box = CompletionBox()
    let tokenBox = TokenBox()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        box.attach(continuation)
        guard box.begin(), !Task.isCancelled else {
          box.finish(.failure(CancellationError()))
          return
        }
        let token = service.stream(
          configuration: configuration,
          request: AssistantRequest(
            messages: [
              AssistantProviderMessage(role: .system, content: system),
              AssistantProviderMessage(role: .user, content: user),
            ],
            tools: []),
          onEvent: { event in
            if case .text(let delta) = event {
              box.append(delta)
            }
          },
          onError: { error in
            box.finish(.failure(error))
          },
          onFinish: {
            box.finishSuccessfully()
          })
        tokenBox.value = token
        if box.isFinished {
          service.cancel(token: token)
        }
      }
    } onCancel: {
      box.finish(.failure(CancellationError()))
      if let token = tokenBox.value {
        service.cancel(token: token)
      }
    }
  }

  func cancel() {
    service.cancel()
  }
}

final class AssistantTranslationSession: LiveTranslationTranslating {
  private let client: AssistantTextClient
  private var sourceName = ""
  private var targetName = ""

  init(client: AssistantTextClient = AssistantTextClient()) {
    self.client = client
  }

  func prepare(from source: LiveTranslationLanguage,
               to target: LiveTranslationLanguage) async throws {
    let translationSource = TranslationSettings.liveSource
    guard TranslationSettings.isConfigured(for: translationSource) else {
      throw AssistantError.notConfigured
    }
    if translationSource == .appleOnDevice {
      let availability = SaySoTranslation.appleAvailability()
      guard availability == .available else {
        throw AssistantError.providerConfiguration(
          SaySoTranslation.appleAvailabilityText(availability))
      }
    }
    sourceName = source.displayName
    targetName = target.displayName
  }

  func translate(_ text: String) async throws -> String {
    let system = String(
      format: NSLocalizedString(
        "You are a translation engine. Translate the user's text from %@ to %@. Return only the translation, with no notes or quotation marks.",
        comment: "Live translation AI prompt"),
      sourceName, targetName)
    let result = try await client.complete(system: system, user: text)
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func cancel() {
    client.cancel()
  }
}

final class AssistantCaptionRepairer: LiveTranslationRepairing {
  private let client: AssistantTextClient

  init(client: AssistantTextClient = AssistantTextClient()) {
    self.client = client
  }

  func repair(source: String, candidate: String,
              glossary: [LiveTranslationGlossaryTerm],
              targetLanguage: String) async throws -> String {
    let system = String(
      format: NSLocalizedString(
        "You correct one live-translation line into %@. Preserve every number, name, unit, date and negation from the source. Use the glossary exactly. Return only the corrected line; do not explain.",
        comment: "Live translation AI repair prompt"),
      targetLanguage)
    var user = "Source: \(source)\nCandidate: \(candidate)"
    if !glossary.isEmpty {
      let terms = glossary
        .map { "- \($0.source) = \($0.target)" }
        .joined(separator: "\n")
      user += "\nGlossary:\n\(terms)"
    }
    let result = try await client.complete(system: system, user: user)
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
