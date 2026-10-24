//
//  LiveTranslationPackInventory.swift
//  uniplayer
//
//  The two package systems behind live translation. Speech models are managed
//  by AssetInventory; Translation packs are managed by the system translation
//  service. Status is always surfaced explicitly so a missing pack never
//  degrades into silent captions.
//

import Foundation
import Speech
import Translation

enum SpeechPackStatus: Equatable {
  case checking
  case installed
  case available
  case downloading
  case unsupported
  case failed(String)

  var canDownload: Bool {
    switch self {
    case .available, .failed: return true
    default: return false
    }
  }
}

enum TranslationPackStatus: Equatable {
  case checking
  case installed
  case available
  case downloading
  case unsupported
  case notNeeded
  case failed(String)

  var canDownload: Bool {
    switch self {
    case .available, .failed: return true
    default: return false
    }
  }
}

protocol SpeechModelInventory {
  func status(for language: LiveTranslationLanguage) async -> SpeechPackStatus
  func install(_ language: LiveTranslationLanguage) async throws
}

protocol TranslationPackInventory {
  func status(from source: LiveTranslationLanguage,
              to target: LiveTranslationLanguage) async -> TranslationPackStatus
}

protocol TranslationPackInstalling {
  func install(from source: LiveTranslationLanguage,
               to target: LiveTranslationLanguage) async throws
  func cancel()
}

extension TranslationPackInstalling {
  func cancel() {}
}

struct SystemSpeechModelInventory: SpeechModelInventory {
  func locale(for language: LiveTranslationLanguage) async -> Locale? {
    await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: language.speechIdentifier))
  }

  func status(for language: LiveTranslationLanguage) async -> SpeechPackStatus {
    guard let locale = await locale(for: language) else { return .unsupported }
    // `installedLocales` lists locales the transcriber can transcribe, but
    // the module can still need its own asset set. AssetInventory is the
    // authority for whether a transcriber is ready to run.
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    switch await AssetInventory.status(forModules: [transcriber]) {
    case .installed: return .installed
    case .supported: return .available
    case .downloading: return .downloading
    case .unsupported: return .unsupported
    @unknown default: return .unsupported
    }
  }

  func install(_ language: LiveTranslationLanguage) async throws {
    guard let locale = await locale(for: language) else {
      throw LiveTranslationPackError.unsupportedLanguage(language.displayName)
    }
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await request.downloadAndInstall()
    }
  }
}

struct SystemTranslationPackInventory: TranslationPackInventory {
  func status(from source: LiveTranslationLanguage,
              to target: LiveTranslationLanguage) async -> TranslationPackStatus {
    guard source.id != target.id else { return .notNeeded }
    let availability = LanguageAvailability()
    switch await availability.status(
      from: Locale.Language(identifier: source.translationIdentifier),
      to: Locale.Language(identifier: target.translationIdentifier)) {
    case .installed: return .installed
    case .supported: return .available
    case .unsupported: return .unsupported
    @unknown default: return .unsupported
    }
  }
}

enum LiveTranslationPackError: LocalizedError, Equatable {
  case unsupportedLanguage(String)
  case canceled
  case downloadTimedOut

  var errorDescription: String? {
    switch self {
    case .unsupportedLanguage(let language):
      return String(format: NSLocalizedString(
        "%@ is not supported by Apple’s on-device recognition.",
        comment: "Live translation pack error"), language)
    case .canceled:
      return NSLocalizedString("The download was canceled.",
                               comment: "Live translation pack error")
    case .downloadTimedOut:
      return NSLocalizedString(
        "The language download did not finish. Check your connection and try again.",
        comment: "Live translation pack error")
    }
  }
}

struct LiveTranslationPackRow: Identifiable, Equatable {
  let language: LiveTranslationLanguage
  var speech: SpeechPackStatus = .checking
  var translation: TranslationPackStatus = .checking
  var error: String?

  var id: String { language.id }
}

/// Combines both package systems into one row per watched language and owns
/// the download-all sequence. UI updates are delivered through `onUpdate` so
/// the AppKit settings page does not need to observe an object. The class is
/// not actor-isolated so the page can own it, but every mutating method runs
/// on the main actor.
final class LiveTranslationPackModel {
  private let speech: SpeechModelInventory
  private let translation: TranslationPackInventory
  private let installer: TranslationPackInstalling

  private(set) var rows: [LiveTranslationPackRow] = []
  private(set) var isDownloadingAll = false
  var onUpdate: (() -> Void)?

  private var target = LiveTranslationLanguages.simplifiedChinese
  private var downloadTask: Task<Void, Never>?
  private var refreshGeneration = 0

  init(speech: SpeechModelInventory,
       translation: TranslationPackInventory,
       installer: TranslationPackInstalling) {
    self.speech = speech
    self.translation = translation
    self.installer = installer
  }

  @MainActor
  func refresh(watched: [LiveTranslationLanguage],
               target: LiveTranslationLanguage) async {
    refreshGeneration += 1
    let generation = refreshGeneration
    self.target = target
    var seen = Set<String>()
    let unique = watched.filter { seen.insert($0.id).inserted }
    let previous = Dictionary(uniqueKeysWithValues:
      rows.map { ($0.language.id, $0) })
    rows = unique.map { language in
      var row = previous[language.id] ?? LiveTranslationPackRow(language: language)
      row.speech = .checking
      row.translation = .checking
      row.error = nil
      return row
    }
    notify()
    for language in unique {
      let speechStatus = await speech.status(for: language)
      guard generation == refreshGeneration else { return }
      let translationStatus = await translation.status(from: language, to: target)
      guard generation == refreshGeneration else { return }
      updateRow(language.id) {
        $0.speech = speechStatus
        $0.translation = translationStatus
      }
      notify()
    }
  }

  @MainActor
  func installSpeech(for language: LiveTranslationLanguage) async {
    guard let index = rows.firstIndex(where: { $0.language.id == language.id }) else { return }
    rows[index].speech = .downloading
    rows[index].error = nil
    notify()
    do {
      try await speech.install(language)
      let status = await speech.status(for: language)
      updateRow(language.id) { $0.speech = status }
    } catch is CancellationError {
      let status = await speech.status(for: language)
      updateRow(language.id) { $0.speech = status }
    } catch LiveTranslationPackError.canceled {
      let status = await speech.status(for: language)
      updateRow(language.id) { $0.speech = status }
    } catch {
      updateRow(language.id) {
        $0.speech = .failed(error.localizedDescription)
        $0.error = error.localizedDescription
      }
    }
    notify()
  }

  @MainActor
  func installTranslation(for language: LiveTranslationLanguage) async {
    guard let index = rows.firstIndex(where: { $0.language.id == language.id }) else { return }
    // Capture the pair before the download: a settings change during the
    // wait must not make the result describe a different target.
    let destination = target
    guard language.id != destination.id else { return }
    rows[index].translation = .downloading
    rows[index].error = nil
    notify()
    do {
      try await installer.install(from: language, to: destination)
      let status = await translation.status(from: language, to: destination)
      guard target == destination else { return }
      updateRow(language.id) { $0.translation = status }
    } catch LiveTranslationPackError.canceled {
      let status = await translation.status(from: language, to: destination)
      guard target == destination else { return }
      updateRow(language.id) { $0.translation = status }
    } catch is CancellationError {
      let status = await translation.status(from: language, to: destination)
      guard target == destination else { return }
      updateRow(language.id) { $0.translation = status }
    } catch {
      guard target == destination else { return }
      updateRow(language.id) {
        $0.translation = .failed(error.localizedDescription)
        $0.error = error.localizedDescription
      }
    }
    notify()
  }

  /// Rows can be reordered or removed by a refresh while a download awaits.
  /// Never write through a captured index; resolve the language again.
  @MainActor
  private func updateRow(_ languageID: String,
                         _ update: (inout LiveTranslationPackRow) -> Void) {
    guard let index = rows.firstIndex(where: { $0.language.id == languageID }) else {
      return
    }
    update(&rows[index])
  }

  @MainActor
  func installAllMissing() async {
    guard !isDownloadingAll else { return }
    isDownloadingAll = true
    notify()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performInstallAll()
    }
    downloadTask = task
    await task.value
    downloadTask = nil
    isDownloadingAll = false
    notify()
  }

  /// Stops the sequence at the next boundary and aborts a translation
  /// download that is waiting for the system sheet. Safe to call for a
  /// single in-flight download too.
  @MainActor
  func cancelDownloads() {
    installer.cancel()
    downloadTask?.cancel()
    notify()
  }

  @MainActor
  private func performInstallAll() async {
    for language in rows.map(\.language) {
      if Task.isCancelled { break }
      if let index = rows.firstIndex(where: { $0.language.id == language.id }),
         rows[index].speech.canDownload {
        await installSpeech(for: language)
      }
      if Task.isCancelled { break }
      if let index = rows.firstIndex(where: { $0.language.id == language.id }),
         rows[index].translation.canDownload {
        await installTranslation(for: language)
      }
    }
  }

  @MainActor
  private func notify() {
    onUpdate?()
  }
}
