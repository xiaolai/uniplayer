//
//  LiveTranslationGlossaryStore.swift
//  uniplayer
//
//  Per-show terms and user corrections, scoped to the source→target language
//  pair. A correction saved while translating into Chinese must never be
//  replayed after switching the same show to English. An exact source match is
//  reused verbatim; shorter terms feed the verifier and AI repair prompt.
//

import Foundation

struct LiveTranslationGlossaryTerm: Equatable, Codable {
  let source: String
  let target: String
}

protocol LiveTranslationGlossaryStoring: AnyObject {
  func terms(for showKey: String, sourceLanguageID: String,
             targetLanguageID: String) -> [LiveTranslationGlossaryTerm]
  func correction(for source: String, showKey: String,
                  sourceLanguageID: String, targetLanguageID: String) -> String?
  func setCorrection(source: String, target: String?, showKey: String,
                     sourceLanguageID: String, targetLanguageID: String)
}

final class LiveTranslationGlossaryStore: LiveTranslationGlossaryStoring {
  static let shared = LiveTranslationGlossaryStore(fileURL: defaultFileURL)

  private static var defaultFileURL: URL {
    Utility.appSupportDirUrl
      .appendingPathComponent("live_translation_glossary.json")
  }

  private let fileURL: URL?
  private let lock = NSLock()
  /// showKey → pairKey → normalized source → target
  private var entries: [String: [String: [String: String]]]

  init(fileURL: URL?) {
    self.fileURL = fileURL
    self.entries = Self.load(from: fileURL)
  }

  func terms(for showKey: String, sourceLanguageID: String,
             targetLanguageID: String) -> [LiveTranslationGlossaryTerm] {
    let pair = Self.pairKey(sourceLanguageID, targetLanguageID)
    lock.lock()
    defer { lock.unlock() }
    return (entries[showKey]?[pair] ?? [:])
      .map { LiveTranslationGlossaryTerm(source: $0.key, target: $0.value) }
      .sorted { $0.source.localizedStandardCompare($1.source) == .orderedAscending }
  }

  func correction(for source: String, showKey: String,
                  sourceLanguageID: String, targetLanguageID: String) -> String? {
    let key = Self.normalize(source)
    guard !key.isEmpty else { return nil }
    let pair = Self.pairKey(sourceLanguageID, targetLanguageID)
    lock.lock()
    defer { lock.unlock() }
    return entries[showKey]?[pair]?[key]
  }

  func setCorrection(source: String, target: String?, showKey: String,
                     sourceLanguageID: String, targetLanguageID: String) {
    let key = Self.normalize(source)
    guard !key.isEmpty else { return }
    let pair = Self.pairKey(sourceLanguageID, targetLanguageID)
    lock.lock()
    if let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      var show = entries[showKey] ?? [:]
      var corrections = show[pair] ?? [:]
      corrections[key] = target.trimmingCharacters(in: .whitespacesAndNewlines)
      show[pair] = corrections
      entries[showKey] = show
    } else if var show = entries[showKey], var corrections = show[pair] {
      corrections.removeValue(forKey: key)
      show[pair] = corrections.isEmpty ? nil : corrections
      entries[showKey] = show.isEmpty ? nil : show
    }
    let snapshot = entries
    lock.unlock()
    persist(snapshot)
  }

  static func pairKey(_ source: String, _ target: String) -> String {
    "\(source)->\(target)"
  }

  private static func normalize(_ source: String) -> String {
    source.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private static func load(
    from fileURL: URL?
  ) -> [String: [String: [String: String]]] {
    guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
      return [:]
    }
    do {
      let data = try Data(contentsOf: fileURL)
      if let current = try? JSONDecoder().decode(
        [String: [String: [String: String]]].self, from: data) {
        return current
      }
      // The pre-pair format has no language information. Keep the file (it is
      // a backup for the person) but do not guess which target each correction
      // belonged to; a wrong target would poison AI repair.
      Logger.log(
        "Live translation glossary from an older format was ignored because it has no language pair",
        level: .debug)
      return [:]
    } catch {
      Logger.log(
        "Unable to read live translation glossary: \(error.localizedDescription)",
        level: .error)
      return [:]
    }
  }

  private func persist(_ snapshot: [String: [String: [String: String]]]) {
    guard let fileURL else { return }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(snapshot)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      Logger.log(
        "Unable to save live translation glossary: \(error.localizedDescription)",
        level: .error)
    }
  }
}
