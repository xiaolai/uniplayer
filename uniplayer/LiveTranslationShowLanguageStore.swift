//
//  LiveTranslationShowLanguageStore.swift
//  uniplayer
//
//  Remembers the spoken language per show. The key is derived from the parsed
//  show title and year, not a raw file path, so moving a file or opening the
//  next episode keeps the choice. The store is deliberately outside
//  UserDefaults: it is per-show library memory, not a global preference.
//

import CryptoKit
import Foundation

enum LiveTranslationShowIdentity {
  /// A stable key for the show, not the file. Episodes of the same series
  /// share a key; a different year or title does not.
  static func key(url: URL?, metadata: LibraryMetadata?) -> String {
    // Filename metadata is only trustworthy for local files. A network URL
    // such as .../index.m3u8 would otherwise collapse every unrelated stream
    // onto "show:index" and share language memory and corrections.
    if let metadata, !metadata.title.isEmpty, url?.isFileURL != false {
      let title = normalized(metadata.title)
      if !title.isEmpty {
        let year = metadata.year.map(String.init) ?? ""
        return "show:\(title)|\(year)"
      }
    }

    guard let url else { return "unknown" }
    if url.isFileURL {
      let name = normalized((url.lastPathComponent as NSString).deletingPathExtension)
      return "file:\(name.isEmpty ? url.lastPathComponent : name)"
    }

    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    // Credentials in userinfo and signing material must never reach the
    // persisted JSON, and an opaque digest keeps the whole URL out of it too.
    components?.user = nil
    components?.password = nil
    components?.fragment = nil
    if let items = components?.queryItems {
      // Exact names and provider prefixes only: a substring rule would delete
      // identity parameters such as mediaKey or video_hash.
      let authNames: Set<String> = [
        "token", "access_token", "id_token", "sig", "signature",
        "expires", "expiry", "auth", "authorization", "key", "apikey",
        "api_key", "policy", "secret", "password", "hdnts",
      ]
      let kept = items.filter { item in
        let name = item.name.lowercased()
        if authNames.contains(name) { return false }
        return !name.hasPrefix("x-amz-") && !name.hasPrefix("x-goog-")
      }
      components?.queryItems = kept.isEmpty ? nil : kept
    }
    let identity = components?.string ?? url.absoluteString
    let digest = SHA256.hash(data: Data(identity.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "url:sha256:\(digest)"
  }

  private static func normalized(_ title: String) -> String {
    let folded = title.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: .current)
    let cleaned = folded.unicodeScalars.map { scalar -> String in
      if CharacterSet.alphanumerics.contains(scalar)
          || CharacterSet.whitespacesAndNewlines.contains(scalar) {
        return String(scalar)
      }
      return " "
    }.joined()
    return cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

protocol ShowLanguageStoring: AnyObject {
  func languageID(for showKey: String) -> String?
  func setLanguageID(_ languageID: String?, for showKey: String)
}

final class LiveTranslationShowLanguageStore: ShowLanguageStoring {
  static let shared = LiveTranslationShowLanguageStore(fileURL: defaultFileURL)

  private static var defaultFileURL: URL {
    Utility.appSupportDirUrl
      .appendingPathComponent("live_translation_show_languages.json")
  }

  private let fileURL: URL?
  private let lock = NSLock()
  private var entries: [String: String]

  /// Passing `nil` keeps the store in memory, which is useful in tests.
  init(fileURL: URL?) {
    self.fileURL = fileURL
    let loaded = Self.load(from: fileURL)
    self.entries = loaded.filter {
      LiveTranslationLanguages.language(for: $0.value) != nil
    }
  }

  func languageID(for showKey: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    guard let id = entries[showKey],
          LiveTranslationLanguages.language(for: id) != nil else { return nil }
    return id
  }

  func setLanguageID(_ languageID: String?, for showKey: String) {
    lock.lock()
    if let languageID, LiveTranslationLanguages.language(for: languageID) != nil {
      entries[showKey] = languageID
    } else {
      entries.removeValue(forKey: showKey)
    }
    let snapshot = entries
    lock.unlock()
    persist(snapshot)
  }

  private static func load(from fileURL: URL?) -> [String: String] {
    guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
      return [:]
    }
    do {
      let data = try Data(contentsOf: fileURL)
      return try JSONDecoder().decode([String: String].self, from: data)
    } catch {
      Logger.log(
        "Unable to read live translation language memory: \(error.localizedDescription)",
        level: .error)
      return [:]
    }
  }

  private func persist(_ snapshot: [String: String]) {
    guard let fileURL else { return }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(snapshot)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      Logger.log(
        "Unable to save live translation language memory: \(error.localizedDescription)",
        level: .error)
    }
  }
}

enum LiveTranslationLanguagePromptOutcome: Equatable {
  case chosen(LiveTranslationLanguage)
  case declined
  /// The prompt could not be shown (no active player or window). The show is
  /// not marked as asked, so a later refresh can try again.
  case unavailable
}

protocol LiveTranslationLanguagePrompting: AnyObject {
  func chooseLanguage(candidates: [LiveTranslationLanguage],
                      showTitle: String?) async -> LiveTranslationLanguagePromptOutcome
}

/// The testable core of per-show language resolution. The controller drives
/// it; the prompt is injected so tests do not need a window. State is
/// lock-protected because a slow resolve can be overtaken by a newer one; the
/// generation counter makes the stale result a no-op.
final class LiveTranslationLanguageSession {
  /// One prompt at a time per show, even when several players observe the
  /// same file. The first session to claim the key asks; the others resolve
  /// from the stored choice on their next refresh.
  private static let promptLock = NSLock()
  private static var promptingKeys = Set<String>()
  /// Shows already asked about during this launch. The per-show choice in the
  /// store handles the chosen case; this also stops a second player from
  /// re-asking after the person declined once.
  private static var askedKeys = Set<String>()

  private let resolver: LiveTranslationLanguageResolver
  private let store: ShowLanguageStoring
  private let stateLock = NSLock()
  private var promptedKeys = Set<String>()
  private var resolveGeneration = 0

  private var _resolution: LiveTranslationLanguageResolution?
  private var _tentative: LiveTranslationLanguage?
  private var _showKey: String?
  private var _showTitle: String?

  init(resolver: LiveTranslationLanguageResolver, store: ShowLanguageStoring) {
    self.resolver = resolver
    self.store = store
  }

  var resolution: LiveTranslationLanguageResolution? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _resolution
  }

  var showKey: String? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _showKey
  }

  var showTitle: String? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _showTitle
  }

  var resolvedLanguage: LiveTranslationLanguage? {
    resolution?.resolvedLanguage ?? tentativeLanguage
  }

  /// A guess used only while the user has not chosen and the speech has not
  /// identified itself yet. It gives ASR a locale so LID can confirm or replace
  /// the guess after the first finalized phrases.
  var tentativeLanguage: LiveTranslationLanguage? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _tentative
  }

  var isTentative: Bool {
    tentativeLanguage != nil && resolution?.resolvedLanguage == nil
  }

  var shouldSkip: Bool {
    resolution?.shouldSkip == true
  }

  var overrideLanguageID: String? {
    guard let showKey else { return nil }
    return store.languageID(for: showKey)
  }

  func resolve(url: URL?,
               metadata: LibraryMetadata?,
               trackLanguage: String?,
               watched: [LiveTranslationLanguage],
               target: LiveTranslationLanguage,
               prompt: LiveTranslationLanguagePrompting?) async -> LiveTranslationLanguageResolution {
    stateLock.lock()
    resolveGeneration += 1
    let generation = resolveGeneration
    stateLock.unlock()

    let key = LiveTranslationShowIdentity.key(url: url, metadata: metadata)
    let title = metadata?.title ?? url?.lastPathComponent

    let override = store.languageID(for: key)
    var result = await resolver.resolve(
      trackLanguage: trackLanguage,
      showOverrideID: override,
      watched: watched,
      target: target)
    guard isCurrentResolution(generation) else { return result }

    if case .needsChoice(let candidates) = result {
      stateLock.lock()
      let alreadyPrompted = promptedKeys.contains(key)
      stateLock.unlock()
      let alreadyAsked = alreadyPrompted || Self.wasAsked(key)
      if !alreadyAsked, Self.claimPrompt(key) {
        guard isCurrentResolution(generation) else {
          Self.releasePrompt(key)
          return result
        }
        let outcome = await prompt?.chooseLanguage(
          candidates: candidates, showTitle: title) ?? .unavailable
        Self.releasePrompt(key)
        // Validate and write under the same lock: a newer resolution cannot
        // invalidate the attempt between the check and the persisted choice.
        stateLock.lock()
        guard generation == resolveGeneration else {
          stateLock.unlock()
          return result
        }
        switch outcome {
        case .chosen(let choice):
          promptedKeys.insert(key)
          store.setLanguageID(choice.id, for: key)
          stateLock.unlock()
          Self.markAsked(key)
          result = await resolver.resolve(
            language: choice, source: .userChoice, target: target)
        case .declined:
          promptedKeys.insert(key)
          stateLock.unlock()
          Self.markAsked(key)
        case .unavailable:
          stateLock.unlock()
        }
      }
    }

    stateLock.lock()
    defer { stateLock.unlock() }
    guard generation == resolveGeneration else { return result }
    _showKey = key
    _showTitle = title
    _resolution = result
    if case .needsChoice(let candidates) = result {
      _tentative = candidates.first
    } else {
      _tentative = nil
    }
    return result
  }

  private func isCurrentResolution(_ generation: Int) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return generation == resolveGeneration
  }

  func setOverride(_ language: LiveTranslationLanguage?,
                   for url: URL?,
                   metadata: LibraryMetadata?) {
    let key = LiveTranslationShowIdentity.key(url: url, metadata: metadata)
    store.setLanguageID(language?.id, for: key)
    stateLock.lock()
    promptedKeys.remove(key)
    stateLock.unlock()
    Self.unmarkAsked(key)
  }

  func invalidate() {
    stateLock.lock()
    resolveGeneration += 1
    stateLock.unlock()
  }

  func clear() {
    stateLock.lock()
    resolveGeneration += 1
    _resolution = nil
    _tentative = nil
    _showKey = nil
    _showTitle = nil
    stateLock.unlock()
  }

  private static func wasAsked(_ key: String) -> Bool {
    promptLock.lock()
    defer { promptLock.unlock() }
    return askedKeys.contains(key)
  }

  private static func markAsked(_ key: String) {
    promptLock.lock()
    askedKeys.insert(key)
    promptLock.unlock()
  }

  private static func unmarkAsked(_ key: String) {
    promptLock.lock()
    askedKeys.remove(key)
    promptLock.unlock()
  }

  private static func claimPrompt(_ key: String) -> Bool {
    promptLock.lock()
    defer { promptLock.unlock() }
    guard !promptingKeys.contains(key) else { return false }
    promptingKeys.insert(key)
    return true
  }

  private static func releasePrompt(_ key: String) {
    promptLock.lock()
    promptingKeys.remove(key)
    promptLock.unlock()
  }
}
