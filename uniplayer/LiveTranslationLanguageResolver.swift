//
//  LiveTranslationLanguageResolver.swift
//  uniplayer
//
//  Decides which language is being spoken once per show. The order is:
//  a remembered choice, the audio track's language tag, then the languages
//  the person said they watch. Language identification is a confirmation
//  for the first finalized phrases, never a per-utterance loop.
//

import Foundation
import NaturalLanguage

enum LiveTranslationLanguageSource: String, Equatable {
  case showOverride
  case trackMetadata
  case watchedList
  case userChoice
  case languageIdentification
}

enum LiveTranslationLanguageUnsupportedReason: Equatable {
  case noWatchedLanguages
  case unrecognizedTag(String)
  case speechModelUnavailable(LiveTranslationLanguage)
}

enum LiveTranslationLanguageResolution: Equatable {
  case resolved(LiveTranslationLanguage, source: LiveTranslationLanguageSource)
  case skip(LiveTranslationLanguage)
  case needsChoice(candidates: [LiveTranslationLanguage])
  case unsupported(LiveTranslationLanguageUnsupportedReason)

  var resolvedLanguage: LiveTranslationLanguage? {
    if case .resolved(let language, _) = self { return language }
    return nil
  }

  var shouldSkip: Bool {
    if case .skip = self { return true }
    return false
  }
}

/// The subset of the speech inventory the resolver needs. Kept narrow so the
/// resolver can be tested without loading Apple's speech assets.
protocol SpeechLocaleSupporting {
  func supportedLocale(for language: LiveTranslationLanguage) async -> Locale?
}

extension SystemSpeechModelInventory: SpeechLocaleSupporting {
  func supportedLocale(for language: LiveTranslationLanguage) async -> Locale? {
    await locale(for: language)
  }
}

/// Maps the many spellings a track tag can use onto the watched catalog.
/// ISO 639-2 codes, regional variants and the `fr_CH`/`it_CH` forms Apple
/// returns are all accepted.
enum LiveTranslationLanguageTags {
  static func isMissing(_ raw: String) -> Bool {
    let tag = normalize(raw)
    return tag.isEmpty || ["und", "unknown", "zxx", "mul"].contains(tag)
  }

  static func language(for raw: String) -> LiveTranslationLanguage? {
    let tag = normalize(raw)
    guard !isMissing(tag) else { return nil }

    if tag.hasPrefix("yue") || tag.hasPrefix("zh-yue") {
      return .cantonese
    }
    if tag.hasPrefix("zh") {
      if tag.contains("hant") || tag.contains("tw")
          || tag.contains("hk") || tag.contains("mo") {
        return .traditionalChinese
      }
      return .simplifiedChinese
    }

    let primary = tag.split(separator: "-").first.map(String.init) ?? tag
    switch primary {
    case "en", "eng": return .english
    case "ja", "jpn": return .japanese
    case "ko", "kor": return .korean
    case "fr", "fra", "fre": return .french
    case "it", "ita": return .italian
    case "yue": return .cantonese
    case "zh", "zho", "chi", "cmn": return .simplifiedChinese
    default: return nil
    }
  }

  private static func normalize(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
  }
}

struct LiveTranslationLanguageResolver {
  let speechSupport: SpeechLocaleSupporting

  func resolve(trackLanguage: String?,
               showOverrideID: String?,
               watched: [LiveTranslationLanguage],
               target: LiveTranslationLanguage) async -> LiveTranslationLanguageResolution {
    if let showOverrideID,
       let language = LiveTranslationLanguages.language(for: showOverrideID) {
      return await resolve(
        language: language, source: .showOverride, target: target)
    }

    let tag = trackLanguage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !LiveTranslationLanguageTags.isMissing(tag) {
      guard let language = LiveTranslationLanguageTags.language(for: tag) else {
        return .unsupported(.unrecognizedTag(tag))
      }
      return await resolve(
        language: language, source: .trackMetadata, target: target)
    }

    var seen = Set<String>()
    let candidates = watched.filter { seen.insert($0.id).inserted }
    guard !candidates.isEmpty else {
      return .unsupported(.noWatchedLanguages)
    }
    guard candidates.count == 1 else {
      return .needsChoice(candidates: candidates)
    }
    return await resolve(
      language: candidates[0], source: .watchedList, target: target)
  }

  func resolve(language: LiveTranslationLanguage,
               source: LiveTranslationLanguageSource,
               target: LiveTranslationLanguage) async -> LiveTranslationLanguageResolution {
    if language.id == target.id {
      return .skip(language)
    }
    guard await speechSupport.supportedLocale(for: language) != nil else {
      return .unsupported(.speechModelUnavailable(language))
    }
    return .resolved(language, source: source)
  }
}

/// Confirms a fallback resolution from the first finalized phrases. The cap
/// matters: running language identification per utterance is both wasteful
/// and unstable on short clauses.
enum LiveTranslationLanguageTextIdentifier {
  static let maximumPhrases = 2

  static func language(for phrases: [String]) -> LiveTranslationLanguage? {
    let text = phrases.prefix(maximumPhrases)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard !text.isEmpty else { return nil }

    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let dominant = recognizer.dominantLanguage else { return nil }
    return LiveTranslationLanguageTags.language(for: dominant.rawValue)
  }

  /// Confirms a watched-list fallback once per show. Returns a different
  /// watched language only; metadata and explicit choices are never overridden.
  static func confirmedLanguage(
    for phrases: [String],
    current: LiveTranslationLanguage,
    watched: [LiveTranslationLanguage]
  ) -> LiveTranslationLanguage? {
    guard let identified = language(for: phrases),
          identified.id != current.id,
          watched.contains(where: { $0.id == identified.id }) else {
      return nil
    }
    return identified
  }
}
