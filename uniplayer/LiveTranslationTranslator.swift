//
//  LiveTranslationTranslator.swift
//  uniplayer
//
//  Chooses the on-device translation session when the pair is installed and
//  falls back to the existing AI provider only when the settings allow it.
//

import Foundation
import Translation

enum LiveTranslationRoute: Equatable {
  case onDevice
  case aiProvider
  case unavailable
  case skip
}

enum LiveTranslationTranslationError: LocalizedError, Equatable {
  case packsMissing(String, String)
  case packsDownloading(String, String)
  case packCheckFailed(String, String)
  case notPrepared
  case unavailablePair(String, String)
  case aiFallbackUnavailable

  var errorDescription: String? {
    switch self {
    case .packsMissing(let source, let target):
      return String(format: NSLocalizedString(
        "The %@ to %@ translation pack is not installed.",
        comment: "Live translation error"), source, target)
    case .packsDownloading(let source, let target):
      return String(format: NSLocalizedString(
        "The %@ to %@ translation pack is still downloading.",
        comment: "Live translation error"), source, target)
    case .packCheckFailed(let source, let target):
      return String(format: NSLocalizedString(
        "The %@ to %@ translation pack could not be checked.",
        comment: "Live translation error"), source, target)
    case .notPrepared:
      return NSLocalizedString(
        "Translation is not ready.", comment: "Live translation error")
    case .unavailablePair(let source, let target):
      return String(format: NSLocalizedString(
        "%@ to %@ is not supported on this device.",
        comment: "Live translation error"), source, target)
    case .aiFallbackUnavailable:
      return NSLocalizedString(
        "The AI fallback is not configured.", comment: "Live translation error")
    }
  }
}

protocol LiveTranslationTranslating: AnyObject {
  func prepare(from source: LiveTranslationLanguage,
               to target: LiveTranslationLanguage) async throws
  func translate(_ text: String) async throws -> String
  func cancel()
}

protocol LiveTranslationAvailabilityChecking {
  func status(from source: LiveTranslationLanguage,
              to target: LiveTranslationLanguage) async -> TranslationPackStatus
}

struct SystemLiveTranslationAvailability: LiveTranslationAvailabilityChecking {
  private let inventory = SystemTranslationPackInventory()

  func status(from source: LiveTranslationLanguage,
              to target: LiveTranslationLanguage) async -> TranslationPackStatus {
    await inventory.status(from: source, to: target)
  }
}

/// One direct session, created only for an installed pair. The direct
/// initializer cannot request downloads, so the settings page owns that step.
final class OnDeviceTranslationSession: LiveTranslationTranslating {
  private var session: TranslationSession?
  private var sourceID: String?
  private var targetID: String?
  private var strategy: TranslationSession.Strategy?
  private var generation = 0

  func prepare(from source: LiveTranslationLanguage,
               to target: LiveTranslationLanguage) async throws {
    let desired: TranslationSession.Strategy =
      LiveTranslationPreferences.strategy == .highFidelity ? .highFidelity : .lowLatency
    if session != nil, sourceID == source.id, targetID == target.id,
       strategy == desired {
      return
    }
    cancel()
    generation += 1
    let attempt = generation

    let availability = LanguageAvailability()
    let status = await availability.status(
      from: Locale.Language(identifier: source.translationIdentifier),
      to: Locale.Language(identifier: target.translationIdentifier))
    guard attempt == generation else { return }
    guard status == .installed else {
      throw LiveTranslationTranslationError.packsMissing(
        source.displayName, target.displayName)
    }

    let session = TranslationSession(
      installedSource: Locale.Language(identifier: source.translationIdentifier),
      target: Locale.Language(identifier: target.translationIdentifier),
      preferredStrategy: desired)
    try await session.prepareTranslation()
    guard attempt == generation else { return }
    self.session = session
    self.sourceID = source.id
    self.targetID = target.id
    self.strategy = desired
  }

  func translate(_ text: String) async throws -> String {
    guard let session else {
      throw LiveTranslationTranslationError.notPrepared
    }
    let response = try await session.translate(text)
    return response.targetText
  }

  func cancel() {
    generation += 1
    session = nil
    sourceID = nil
    targetID = nil
    strategy = nil
  }
}

final class LiveTranslationRouter {
  private let onDevice: LiveTranslationTranslating
  private let aiProvider: LiveTranslationTranslating?
  private let availability: LiveTranslationAvailabilityChecking
  private let fallback: () -> LiveTranslationFallback
  var requestAIApproval:
    (LiveTranslationLanguage, LiveTranslationLanguage) async -> Bool
  /// Called before a missing/unsupported pair falls back, so the app can start
  /// the pack download the setting promises regardless of the fallback route.
  var onMissingPack:
    ((LiveTranslationLanguage, LiveTranslationLanguage, TranslationPackStatus) -> Void)?
  var autoDownload: () -> Bool = { false }

  private var route: LiveTranslationRoute = .unavailable
  private var pair: (source: String, target: String)?
  private var unavailableReason: LiveTranslationTranslationError?
  private var lastPackRequest: (pair: String, at: Date)?
  private var prepareGeneration = 0

  var currentRoute: LiveTranslationRoute { route }

  init(onDevice: LiveTranslationTranslating,
       aiProvider: LiveTranslationTranslating?,
       availability: LiveTranslationAvailabilityChecking,
       fallback: @escaping () -> LiveTranslationFallback,
       requestAIApproval: @escaping
         (LiveTranslationLanguage, LiveTranslationLanguage) async -> Bool
         = { _, _ in false }) {
    self.onDevice = onDevice
    self.aiProvider = aiProvider
    self.availability = availability
    self.fallback = fallback
    self.requestAIApproval = requestAIApproval
  }

  func prepare(from source: LiveTranslationLanguage,
               to target: LiveTranslationLanguage) async throws {
    if source.id == target.id {
      route = .skip
      pair = (source.id, target.id)
      unavailableReason = nil
      return
    }
    if pair?.source == source.id, pair?.target == target.id,
       route == .onDevice || route == .aiProvider {
      return
    }
    cancel()
    prepareGeneration += 1
    let attempt = prepareGeneration
    pair = (source.id, target.id)
    let decision = await decide(from: source, to: target, attempt: attempt)
    // A newer prepare or cancel superseded this attempt; it must not publish
    // its route over the replacement's state.
    guard attempt == prepareGeneration else { return }
    switch decision.route {
    case .onDevice:
      try await onDevice.prepare(from: source, to: target)
    case .aiProvider:
      guard let aiProvider else {
        route = .unavailable
        throw LiveTranslationTranslationError.aiFallbackUnavailable
      }
      try await aiProvider.prepare(from: source, to: target)
    case .unavailable:
      route = .unavailable
      unavailableReason = decision.reason
      throw decision.reason
        ?? LiveTranslationTranslationError.unavailablePair(
          source.displayName, target.displayName)
    case .skip:
      break
    }
    // Cache a route only after its translator prepared successfully. A failed
    // preparation must be retried, not served from the shortcut above.
    guard attempt == prepareGeneration else { return }
    route = decision.route
    unavailableReason = decision.reason
  }

  func translate(_ text: String) async throws -> String {
    switch route {
    case .onDevice:
      return try await onDevice.translate(text)
    case .aiProvider:
      guard let aiProvider else {
        throw LiveTranslationTranslationError.aiFallbackUnavailable
      }
      return try await aiProvider.translate(text)
    case .skip:
      return ""
    case .unavailable:
      throw LiveTranslationTranslationError.notPrepared
    }
  }

  func cancel() {
    prepareGeneration += 1
    onDevice.cancel()
    aiProvider?.cancel()
    route = .unavailable
    pair = nil
    unavailableReason = nil
  }

  private func decide(
    from source: LiveTranslationLanguage,
    to target: LiveTranslationLanguage,
    attempt: Int
  ) async -> (route: LiveTranslationRoute, reason: LiveTranslationTranslationError?) {
    let status = await availability.status(from: source, to: target)
    guard attempt == prepareGeneration else { return (.unavailable, nil) }
    switch status {
    case .installed:
      return (.onDevice, nil)
    case .notNeeded:
      return (.skip, nil)
    case .available:
      let decision = await fallbackRoute(
        from: source, to: target,
        missingReason: .packsMissing(source.displayName, target.displayName),
        attempt: attempt)
      // Ask for the download after any fallback prompt, not on top of it.
      notifyMissingPack(.available, source, target, attempt: attempt)
      return decision
    case .downloading, .checking:
      notifyMissingPack(.downloading, source, target, attempt: attempt)
      return (.unavailable,
              .packsDownloading(source.displayName, target.displayName))
    case .failed:
      notifyMissingPack(.failed(""), source, target, attempt: attempt)
      return (.unavailable,
              .packCheckFailed(source.displayName, target.displayName))
    case .unsupported:
      return await fallbackRoute(
        from: source, to: target,
        missingReason: .unavailablePair(
          source.displayName, target.displayName),
        attempt: attempt)
    }
  }

  private func notifyMissingPack(
    _ status: TranslationPackStatus,
    _ source: LiveTranslationLanguage,
    _ target: LiveTranslationLanguage,
    attempt: Int
  ) {
    guard attempt == prepareGeneration, autoDownload(),
          let onMissingPack else { return }
    let key = "\(source.id)->\(target.id)"
    if let last = lastPackRequest, last.pair == key,
       Date().timeIntervalSince(last.at) < 60 {
      return
    }
    lastPackRequest = (key, Date())
    onMissingPack(source, target, status)
  }

  private func fallbackRoute(
    from source: LiveTranslationLanguage,
    to target: LiveTranslationLanguage,
    missingReason: LiveTranslationTranslationError,
    attempt: Int
  ) async -> (route: LiveTranslationRoute, reason: LiveTranslationTranslationError?) {
    switch fallback() {
    case .aiProvider:
      return aiProvider != nil
        ? (.aiProvider, nil) : (.unavailable, .aiFallbackUnavailable)
    case .ask:
      guard aiProvider != nil else {
        return (.unavailable, .aiFallbackUnavailable)
      }
      guard attempt == prepareGeneration else { return (.unavailable, nil) }
      if await requestAIApproval(source, target) {
        guard attempt == prepareGeneration else { return (.unavailable, nil) }
        return (.aiProvider, nil)
      }
      return (.unavailable, missingReason)
    case .off:
      return (.unavailable, missingReason)
    }
  }
}
