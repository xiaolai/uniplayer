//
//  LiveTranslationSettings.swift
//  uniplayer
//
//  Language catalog and persisted choices for on-device live translation.
//  Speech models and Translation packs are separate systems; both are driven
//  from Settings › Live Translation.
//

import Foundation

enum LiveTranslationFallback: Int, InitializingFromKey, CaseIterable {
  case aiProvider = 0
  case ask = 1
  case off = 2

  static var defaultValue: LiveTranslationFallback { .aiProvider }

  var description: String {
    switch self {
    case .aiProvider: return "aiProvider"
    case .ask: return "ask"
    case .off: return "off"
    }
  }
}

enum LiveTranslationStrategy: Int, InitializingFromKey, CaseIterable {
  case lowLatency = 0
  case highFidelity = 1

  static var defaultValue: LiveTranslationStrategy { .lowLatency }

  var description: String {
    switch self {
    case .lowLatency: return "lowLatency"
    case .highFidelity: return "highFidelity"
    }
  }
}

/// One spoken language and the identifiers used by the two package systems.
///
/// Speech and Translation use different locale spellings; `speechIdentifier`
/// is resolved through `supportedLocale(equivalentTo:)` before use, so a
/// device that only ships `fr_CH` still works for French content.
struct LiveTranslationLanguage: Hashable {
  let id: String
  let speechIdentifier: String
  let translationIdentifier: String

  var displayName: String {
    Locale.current.localizedString(forIdentifier: id)
      ?? Locale.current.localizedString(forLanguageCode: translationIdentifier)
      ?? id
  }

  // Shorthand for the catalog entries, useful where the context already
  // supplies the type.
  static var korean: LiveTranslationLanguage { LiveTranslationLanguages.korean }
  static var japanese: LiveTranslationLanguage { LiveTranslationLanguages.japanese }
  static var french: LiveTranslationLanguage { LiveTranslationLanguages.french }
  static var italian: LiveTranslationLanguage { LiveTranslationLanguages.italian }
  static var english: LiveTranslationLanguage { LiveTranslationLanguages.english }
  static var simplifiedChinese: LiveTranslationLanguage {
    LiveTranslationLanguages.simplifiedChinese
  }
  static var traditionalChinese: LiveTranslationLanguage {
    LiveTranslationLanguages.traditionalChinese
  }
  static var cantonese: LiveTranslationLanguage { LiveTranslationLanguages.cantonese }
}

enum LiveTranslationLanguages {
  static let korean = LiveTranslationLanguage(
    id: "ko", speechIdentifier: "ko-KR", translationIdentifier: "ko")
  static let japanese = LiveTranslationLanguage(
    id: "ja", speechIdentifier: "ja-JP", translationIdentifier: "ja")
  static let french = LiveTranslationLanguage(
    id: "fr", speechIdentifier: "fr", translationIdentifier: "fr")
  static let italian = LiveTranslationLanguage(
    id: "it", speechIdentifier: "it", translationIdentifier: "it")
  static let english = LiveTranslationLanguage(
    id: "en", speechIdentifier: "en-US", translationIdentifier: "en")
  static let simplifiedChinese = LiveTranslationLanguage(
    id: "zh-Hans", speechIdentifier: "zh-Hans", translationIdentifier: "zh-Hans")
  static let traditionalChinese = LiveTranslationLanguage(
    id: "zh-Hant", speechIdentifier: "zh-Hant", translationIdentifier: "zh-Hant")
  static let cantonese = LiveTranslationLanguage(
    id: "yue", speechIdentifier: "yue-CN", translationIdentifier: "yue")

  /// Languages offered as spoken languages and pre-download targets.
  static let watchedCandidates: [LiveTranslationLanguage] = [
    korean, japanese, french, italian, english,
    simplifiedChinese, traditionalChinese, cantonese,
  ]

  /// Languages offered as translation targets. Cantonese is excluded because
  /// the Translation framework does not support a `yue` target.
  static let targetCandidates: [LiveTranslationLanguage] = [
    simplifiedChinese, traditionalChinese, english,
    japanese, korean, french, italian,
  ]

  static func language(for id: String) -> LiveTranslationLanguage? {
    watchedCandidates.first { $0.id == id }
  }

  static func target(for id: String) -> LiveTranslationLanguage? {
    targetCandidates.first { $0.id == id }
  }
}

/// Reads and writes the live-translation choices. Kept separate from the
/// settings page so the pure parsing and default rules are testable without
/// touching UserDefaults.
enum LiveTranslationPreferences {
  static var enabled: Bool {
    Preference.bool(for: .liveTranslationEnabled)
  }

  static var targetID: String {
    let stored = Preference.string(for: .liveTranslationTarget) ?? ""
    if LiveTranslationLanguages.target(for: stored) != nil { return stored }
    return defaultTargetID()
  }

  static var target: LiveTranslationLanguage {
    LiveTranslationLanguages.target(for: targetID) ?? LiveTranslationLanguages.simplifiedChinese
  }

  static var watchedIDs: [String] {
    guard let raw = Preference.string(for: .liveTranslationWatchedLanguages) else {
      return ["en", "zh-Hans"]
    }
    return parseWatched(raw)
  }

  static var watchedLanguages: [LiveTranslationLanguage] {
    watchedIDs.compactMap(LiveTranslationLanguages.language(for:))
  }

  static func setWatchedIDs(_ ids: [String]) {
    Preference.set(serializeWatched(ids), for: .liveTranslationWatchedLanguages)
  }

  static var autoDownload: Bool {
    Preference.bool(for: .liveTranslationAutoDownload)
  }

  static var fallback: LiveTranslationFallback {
    LiveTranslationFallback(key: .liveTranslationFallback) ?? .defaultValue
  }

  static var strategy: LiveTranslationStrategy {
    LiveTranslationStrategy(key: .liveTranslationPreferredStrategy) ?? .defaultValue
  }

  static var showSource: Bool {
    Preference.bool(for: .liveTranslationShowSource)
  }

  static var repair: Bool {
    Preference.bool(for: .liveTranslationRepair)
  }

  /// The default target follows the system language. A Chinese system gets
  /// Simplified Chinese; every other system gets English until the user picks.
  static func defaultTargetID(for languageCode: String? = nil) -> String {
    let code = languageCode
      ?? Locale.current.language.languageCode?.identifier
      ?? "en"
    switch code {
    case "zh": return LiveTranslationLanguages.simplifiedChinese.id
    case "ja", "ko", "fr", "it", "en":
      return LiveTranslationLanguages.target(for: code)?.id ?? LiveTranslationLanguages.english.id
    default:
      return LiveTranslationLanguages.english.id
    }
  }

  /// Parses the comma-separated watched-language preference.
  static func parseWatched(_ raw: String) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for token in raw.split(separator: ",") {
      let id = token.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty,
            LiveTranslationLanguages.language(for: id) != nil,
            !seen.contains(id) else { continue }
      seen.insert(id)
      result.append(id)
    }
    return result
  }

  static func serializeWatched(_ ids: [String]) -> String {
    parseWatched(ids.joined(separator: ",")).joined(separator: ",")
  }
}
