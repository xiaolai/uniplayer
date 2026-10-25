//
//  TranslationProviders.swift
//  uniplayer
//
//  Subtitle translation can use the assistant connection, the reader's own
//  Claude or Codex CLI, or Apple's on-device model. The CLI and on-device
//  sources are one-shot: SaySo owns their transport, isolation and typed
//  failures, and this file only composes the question and words the errors.
//

import Foundation
import SaySoAI
import SaySoAICLI
import SaySoAIApple

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Where subtitle file translation comes from. Live translation stays on a
/// source that can answer fast enough for rolling captions.
enum TranslationSource: String, CaseIterable, Identifiable {
  case assistant
  case codexCLI
  case claudeCLI
  case appleOnDevice

  var id: String { rawValue }

  var title: String {
    switch self {
    case .assistant:
      return NSLocalizedString("Same as Assistant", comment: "Translation source")
    case .codexCLI:
      return NSLocalizedString("Codex CLI", comment: "Translation source")
    case .claudeCLI:
      return NSLocalizedString("Claude CLI", comment: "Translation source")
    case .appleOnDevice:
      return NSLocalizedString("Apple On-Device", comment: "Translation source")
    }
  }

  var supportsLive: Bool {
    switch self {
    case .assistant, .appleOnDevice: return true
    case .codexCLI, .claudeCLI: return false
    }
  }

  var needsModel: Bool {
    switch self {
    case .codexCLI, .claudeCLI: return true
    case .assistant, .appleOnDevice: return false
    }
  }

  var explanation: String {
    switch self {
    case .assistant:
      return NSLocalizedString(
        "Uses the provider configured above. Live translation and the inspector keep working.",
        comment: "Translation source")
    case .codexCLI:
      return NSLocalizedString(
        "Runs your signed-in Codex CLI in an app-owned folder and sends subtitle text to Codex. Subtitle files only: live captions need a faster source.",
        comment: "Translation source")
    case .claudeCLI:
      return NSLocalizedString(
        "Runs your signed-in Claude Code CLI in an app-owned folder and sends subtitle text to Claude. Subtitle files only: live captions need a faster source.",
        comment: "Translation source")
    case .appleOnDevice:
      return NSLocalizedString(
        "Runs Apple's on-device model. Nothing leaves this Mac; availability depends on this Mac and Apple Intelligence.",
        comment: "Translation source")
    }
  }
}

/// The preferences and app-owned folders the one-shot providers need.
enum TranslationSettings {
  static var source: TranslationSource {
    TranslationSource(rawValue: Preference.string(for: .translationSource) ?? "") ?? .assistant
  }

  /// Live captions must not wait for a child process; a CLI selection falls
  /// back to the assistant connection for that surface.
  static var liveSource: TranslationSource {
    source.supportsLive ? source : .assistant
  }

  static func model(for source: TranslationSource) -> String? {
    let value: String
    switch source {
    case .codexCLI:
      value = Preference.string(for: .translationCodexModel) ?? ""
    case .claudeCLI:
      value = Preference.string(for: .translationClaudeModel) ?? ""
    case .assistant, .appleOnDevice:
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static var applicationSupportDirectory: URL {
    Utility.appSupportDirUrl.appendingPathComponent("AI", isDirectory: true)
  }

  static var claudeConfigDirectory: URL {
    applicationSupportDirectory.appendingPathComponent("claude", isDirectory: true)
  }

  static var codexHome: URL {
    applicationSupportDirectory.appendingPathComponent("codex", isDirectory: true)
  }

  static var workingDirectory: URL {
    applicationSupportDirectory.appendingPathComponent("work", isDirectory: true)
  }

  /// The command a reader runs once to sign the app-owned Claude folder in.
  /// The path is quoted because Application Support contains a space.
  static var claudeSignInCommand: String {
    let path = claudeConfigDirectory.path.replacingOccurrences(of: "'", with: "'\\''")
    return "CLAUDE_CONFIG_DIR='\(path)' claude"
  }

  static func isConfigured(for source: TranslationSource) -> Bool {
    switch source {
    case .assistant: return AssistantConfiguration.load().isConfigured
    case .codexCLI, .claudeCLI, .appleOnDevice: return true
    }
  }

  static func isConfigured(for source: TranslationSource,
                           configuration: AssistantConfiguration) -> Bool {
    switch source {
    case .assistant:
      return configuration.isConfigured
    case .codexCLI, .claudeCLI, .appleOnDevice:
      // The CLI and on-device sources report a missing binary, sign-in or
      // model when asked; requiring a key here would block them for no reason.
      return true
    }
  }

  static func configurationProblem(for source: TranslationSource) -> String? {
    guard source == .assistant else { return nil }
    return configurationProblem(for: source, configuration: .load())
  }

  static func configurationProblem(for source: TranslationSource,
                                   configuration: AssistantConfiguration) -> String? {
    switch source {
    case .assistant:
      if configuration.endpointURL == nil {
        return AssistantError.invalidEndpoint.errorDescription
      }
      if configuration.model.isEmpty {
        return AssistantError.notConfigured.errorDescription
      }
      if configuration.requiresAPIKey, configuration.apiKey?.isEmpty != false {
        return AssistantError.missingAPIKey.errorDescription
      }
      return nil
    case .codexCLI, .claudeCLI, .appleOnDevice:
      return nil
    }
  }
}

/// The question and schema the one-shot providers receive. The assistant
/// connection keeps its system and user roles; the other sources get one
/// composed question because that is what SaySo's `AIProvider` accepts.
enum TranslationPrompt {
  static let answerSchema = """
    {"type":"object","properties":{"translations":{"type":"array","items":{"type":"object","properties":{"id":{"type":"integer"},"text":{"type":"string"}},"required":["id","text"],"additionalProperties":false}}},"required":["translations"],"additionalProperties":false}
    """

  static func question(system: String, user: String) -> String {
    "\(system)\n\n\(user)"
  }
}

#if canImport(FoundationModels)
@Generable
struct AppleTranslationBatch: Codable, Sendable {
  @Guide(description: "One entry for every input line, in the same order")
  var translations: [AppleTranslationLine]
}

@Generable
struct AppleTranslationLine: Codable, Sendable {
  var id: Int
  var text: String
}
#else
struct AppleTranslationBatch: Codable, Sendable {
  var translations: [AppleTranslationLine]
}

struct AppleTranslationLine: Codable, Sendable {
  var id: Int
  var text: String
}
#endif

/// The one-shot providers SaySo supplies. Each call is a complete answer; the
/// caller parses it exactly as it parsed the streaming assistant's answer.
enum SaySoTranslation {
  static func batch(source: TranslationSource, system: String, user: String) async throws -> String {
    let question = TranslationPrompt.question(system: system, user: user)
    switch source {
    case .assistant:
      throw AssistantError.notConfigured
    case .codexCLI:
      let provider = try codexProvider()
      return try await answer(provider, question: question, source: source)
    case .claudeCLI:
      let provider = claudeProvider()
      return try await answer(provider, question: question, source: source)
    case .appleOnDevice:
      return try await answer(appleBatchProvider(), question: question, source: source)
    }
  }

  static func plain(source: TranslationSource, system: String, user: String) async throws -> String {
    let question = TranslationPrompt.question(system: system, user: user)
    switch source {
    case .assistant:
      throw AssistantError.notConfigured
    case .codexCLI:
      throw AssistantError.providerConfiguration(
        NSLocalizedString("Codex CLI is only used for subtitle files, not live captions.",
                          comment: "Translation source"))
    case .claudeCLI:
      throw AssistantError.providerConfiguration(
        NSLocalizedString("Claude CLI is only used for subtitle files, not live captions.",
                          comment: "Translation source"))
    case .appleOnDevice:
      return try await answer(applePlainProvider(), question: question, source: source)
    }
  }

  static func check(source: TranslationSource) async throws -> String {
    do {
      switch source {
      case .assistant:
        return NSLocalizedString("Uses the assistant connection.", comment: "Translation source")
      case .codexCLI:
        return try await codexProvider().check()
      case .claudeCLI:
        return try await claudeProvider().check()
      case .appleOnDevice:
        return appleAvailabilityText(appleAvailability())
      }
    } catch let error as AIProviderError {
      throw assistantError(error, source: source)
    } catch {
      throw AssistantError.provider(error.localizedDescription)
    }
  }

  /// Runs the CLI's own documented login in the app-owned Codex home. The
  /// URL and code arrive through `onLine`; the library writes no credential.
  static func signInToCodex(
    onLine: @escaping @Sendable (String) -> Void
  ) async throws -> String {
    do {
      return try await codexProvider().login(onLine: onLine)
    } catch let error as AIProviderError {
      throw assistantError(error, source: .codexCLI)
    } catch {
      throw AssistantError.provider(error.localizedDescription)
    }
  }

  static func appleAvailability() -> AppleAvailability {
    AppleOnDeviceProvider<AppleTranslationBatch>.availability()
  }

  static func appleAvailabilityText(_ availability: AppleAvailability) -> String {
    switch availability {
    case .available:
      return NSLocalizedString("Available on this Mac.", comment: "On-device model")
    case .deviceNotEligible:
      return NSLocalizedString("This Mac cannot run Apple's on-device model.",
                               comment: "On-device model")
    case .appleIntelligenceNotEnabled:
      return NSLocalizedString("Turn on Apple Intelligence in System Settings.",
                               comment: "On-device model")
    case .modelNotReady:
      return NSLocalizedString("The on-device model is still preparing. Try again shortly.",
                               comment: "On-device model")
    case .system(let required, let running):
      return String(format: NSLocalizedString(
        "The on-device model needs macOS %@ or later; this Mac runs %@.",
        comment: "On-device model"), required, running)
    case .unknown:
      return NSLocalizedString("The on-device model is unavailable.",
                               comment: "On-device model")
    }
  }

  // MARK: - Providers

  private static func codexProvider() throws -> CodexCLIProvider {
    do {
      return try CodexCLIProvider(configuration: .init(
        codexHome: TranslationSettings.codexHome,
        workingDirectory: TranslationSettings.workingDirectory,
        model: TranslationSettings.model(for: .codexCLI)))
    } catch {
      throw assistantError(error, source: .codexCLI)
    }
  }

  private static func claudeProvider() -> ClaudeCLIProvider {
    ClaudeCLIProvider(configuration: .init(
      configDirectory: TranslationSettings.claudeConfigDirectory,
      workingDirectory: TranslationSettings.workingDirectory,
      model: TranslationSettings.model(for: .claudeCLI),
      answerSchema: TranslationPrompt.answerSchema))
  }

  private static func appleBatchProvider() -> AppleOnDeviceProvider<AppleTranslationBatch> {
    AppleOnDeviceProvider(configuration: .init(encode: { batch in
      guard let data = try? JSONEncoder().encode(batch) else {
        return #"{"translations":[]}"#
      }
      return String(decoding: data, as: UTF8.self)
    }))
  }

  private static func applePlainProvider() -> AppleOnDeviceProvider<String> {
    AppleOnDeviceProvider(configuration: .init(encode: { $0 }))
  }

  private static func answer(_ provider: some AIProvider, question: String,
                             source: TranslationSource) async throws -> String {
    do {
      return try await provider.answer(to: question)
    } catch {
      throw assistantError(error, source: source)
    }
  }

  // MARK: - Errors

  static func assistantError(_ error: AIProviderError,
                             source: TranslationSource) -> AssistantError {
    switch error {
    case .cancelled:
      return .cancelled
    case .insecureEndpoint:
      return .providerConfiguration(NSLocalizedString(
        "This provider needs HTTPS, or plain HTTP on this Mac. A LAN address is refused.",
        comment: "Translation provider error"))
    case .redirectRefused:
      return .providerConfiguration(NSLocalizedString(
        "The provider redirected to another address; the request was refused.",
        comment: "Translation provider error"))
    case .unreachable:
      return .offline
    case .unauthorised:
      return .unauthorized
    case .modelNotFound:
      return .providerConfiguration(NSLocalizedString(
        "The selected model was not found.", comment: "Translation provider error"))
    case .rateLimited:
      return .provider(NSLocalizedString(
        "The provider is rate limited. Try again later.", comment: "Translation provider error"))
    case .refused:
      return .provider(NSLocalizedString(
        "The model declined to answer.", comment: "Translation provider error"))
    case .truncated:
      return .provider(NSLocalizedString(
        "The answer was cut off. Try fewer lines at once.", comment: "Translation provider error"))
    case .badShape:
      return .malformedResponse
    case .server(_, let message):
      return .provider(message)
    case .timeout:
      return .timedOut
    case .notInstalled:
      return .providerConfiguration(notInstalledMessage(source))
    case .notSignedIn:
      return .providerConfiguration(notSignedInMessage(source))
    case .versionTooOld:
      return .providerConfiguration(versionTooOldMessage(source))
    case .unsupportedAuth:
      return .providerConfiguration(NSLocalizedString(
        "This CLI is signed in with a mode UniPlayer does not support.",
        comment: "Translation provider error"))
    case .unavailable(let reason):
      return .providerConfiguration(appleAvailabilityText(reason))
    case .contextExceeded:
      return .provider(NSLocalizedString(
        "The selected lines are too long for the on-device model. Try fewer lines.",
        comment: "Translation provider error"))
    case .guardrail:
      return .provider(NSLocalizedString(
        "The model declined to translate this text.", comment: "Translation provider error"))
    case .framework:
      return .provider(NSLocalizedString(
        "The provider failed before it could answer.", comment: "Translation provider error"))
    }
  }

  private static func notInstalledMessage(_ source: TranslationSource) -> String {
    switch source {
    case .codexCLI:
      return NSLocalizedString("Codex is not installed. Install the Codex CLI and try again.",
                               comment: "Translation provider error")
    case .claudeCLI:
      return NSLocalizedString("Claude Code is not installed. Install the Claude CLI and try again.",
                               comment: "Translation provider error")
    case .assistant, .appleOnDevice:
      return NSLocalizedString("The translation provider is not available.",
                               comment: "Translation provider error")
    }
  }

  private static func notSignedInMessage(_ source: TranslationSource) -> String {
    switch source {
    case .codexCLI:
      return NSLocalizedString("Sign in to Codex in Settings › AI, then try again.",
                               comment: "Translation provider error")
    case .claudeCLI:
      return NSLocalizedString(
        "Sign in to Claude Code in Settings › AI. The app uses its own folder and never reads ~/.claude.",
        comment: "Translation provider error")
    case .assistant, .appleOnDevice:
      return NSLocalizedString("The translation provider needs a sign-in.",
                               comment: "Translation provider error")
    }
  }

  private static func versionTooOldMessage(_ source: TranslationSource) -> String {
    switch source {
    case .codexCLI:
      return String(format: NSLocalizedString(
        "Update the Codex CLI to version %@ or later.",
        comment: "Translation provider error"), CodexCLIProvider.minimumVersion)
    case .claudeCLI:
      return String(format: NSLocalizedString(
        "Update Claude Code to version %@ or later.",
        comment: "Translation provider error"), ClaudeCLIProvider.minimumVersion)
    case .assistant, .appleOnDevice:
      return NSLocalizedString("The translation provider is too old.",
                               comment: "Translation provider error")
    }
  }
}
