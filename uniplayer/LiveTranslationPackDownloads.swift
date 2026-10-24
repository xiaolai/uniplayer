//
//  LiveTranslationPackDownloads.swift
//  uniplayer
//
//  Translation packs can only be downloaded from a session created by
//  SwiftUI's translationTask. This file hosts that session invisibly inside
//  the AppKit settings page and turns it into an async installer.
//

import SwiftUI
import Translation

/// Keys for a settings-page download requested by the caption pipeline when
/// automatic downloads are on.
enum LiveTranslationPackDownloadRequest {
  static let sourceKey = "source"
  static let targetKey = "target"
}

struct TranslationPackDownloadRequest {
  let id: UUID
  let source: Locale.Language
  let target: Locale.Language
  let configuration: TranslationSession.Configuration
}

final class TranslationPackDownloadCoordinator: ObservableObject {
  @Published fileprivate(set) var request: TranslationPackDownloadRequest?
  private var continuation: CheckedContinuation<Void, Error>?

  @MainActor
  func prepare(from source: Locale.Language,
               to target: Locale.Language,
               strategy: TranslationSession.Strategy) async throws {
    guard continuation == nil else { throw LiveTranslationPackError.canceled }
    let request = TranslationPackDownloadRequest(
      id: UUID(), source: source, target: target,
      configuration: TranslationSession.Configuration(
        source: source, target: target, preferredStrategy: strategy))
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        self.request = request
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancel(token: request.id)
      }
    }
  }

  @MainActor
  func cancel(token: UUID? = nil) {
    if let token, token != request?.id { return }
    request = nil
    finish(.failure(LiveTranslationPackError.canceled), token: nil)
  }

  @MainActor
  func isCurrent(source: Locale.Language, target: Locale.Language) -> Bool {
    request?.source.minimalIdentifier == source.minimalIdentifier
      && request?.target.minimalIdentifier == target.minimalIdentifier
  }

  @MainActor
  fileprivate func finish(_ result: Result<Void, Error>, token: UUID?) {
    // The token is the immutable identity of the request that produced this
    // callback. A late completion from a cancelled request cannot finish a
    // replacement that happens to use the same language pair.
    if let token, token != request?.id { return }
    guard let pending = continuation else { return }
    continuation = nil
    request = nil
    pending.resume(with: result)
  }
}

struct TranslationPackDownloadHost: View {
  @ObservedObject var coordinator: TranslationPackDownloadCoordinator

  var body: some View {
    let request = coordinator.request
    Rectangle()
      .fill(Tokens.Palette.clear.color)
      .frame(width: Tokens.Space.n1, height: Tokens.Space.n1)
      .translationTask(request?.configuration) { session in
        guard let request else { return }
        let token = request.id
        do {
          try await session.prepareTranslation()
          // prepareTranslation() returns once the person approves the
          // downloads, not when they finish. Keep the session alive until the
          // pair is actually installed; tearing it down early cancels the
          // system download and leaves the settings page claiming success.
          guard let source = session.sourceLanguage,
                let target = session.targetLanguage else {
            await MainActor.run {
              coordinator.finish(.success(()), token: token)
            }
            return
          }
          let availability = LanguageAvailability()
          let deadline = ContinuousClock.now + .seconds(180)
          while await availability.status(from: source, to: target) != .installed {
            if ContinuousClock.now >= deadline {
              await MainActor.run {
                coordinator.finish(
                  .failure(LiveTranslationPackError.downloadTimedOut),
                  token: token)
              }
              return
            }
            let stillCurrent = await MainActor.run {
              coordinator.isCurrent(source: source, target: target)
            }
            guard stillCurrent else { return }
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
          }
          await MainActor.run {
            coordinator.finish(.success(()), token: token)
          }
        } catch {
          await MainActor.run {
            coordinator.finish(.failure(error), token: token)
          }
        }
      }
      .accessibilityHidden(true)
  }
}

final class SystemTranslationPackInstaller: TranslationPackInstalling {
  private let coordinator: TranslationPackDownloadCoordinator

  init(coordinator: TranslationPackDownloadCoordinator) {
    self.coordinator = coordinator
  }

  func install(from source: LiveTranslationLanguage,
               to target: LiveTranslationLanguage) async throws {
    guard source.id != target.id else { return }
    // Read the choice at install time: the setting can change after this
    // object is created.
    let strategy: TranslationSession.Strategy =
      LiveTranslationPreferences.strategy == .highFidelity ? .highFidelity : .lowLatency
    try await coordinator.prepare(
      from: Locale.Language(identifier: source.translationIdentifier),
      to: Locale.Language(identifier: target.translationIdentifier),
      strategy: strategy)
  }

  func cancel() {
    Task { @MainActor in
      coordinator.cancel()
    }
  }
}
