//
//  LiveTranslationCommitter.swift
//  uniplayer
//
//  Turns volatile ASR revisions into committed chunks. The committer keeps
//  the longest common prefix, waits for a short stability window, and forces a
//  commit at sentence punctuation or after a bounded lag. Final results commit
//  their remainder immediately.
//

import Foundation

struct StablePrefixCommitter {
  struct Configuration: Equatable {
    var stabilityWindow: TimeInterval = 0.3
    var maximumLag: TimeInterval = 8
    var maximumCharacters = 160
    /// A stability pause in the middle of a word must not ship a one-letter
    /// fragment to translation. Punctuation and final results bypass this.
    var minimumCommitCharacters = 12
    /// The first phrase is the latency-critical one. It commits as soon as a
    /// usable phrase exists instead of waiting for the stability window used
    /// for later chunks; a final result replaces it if ASR revises it.
    var firstCommitCharacters = 4
    var firstLatinCommitCharacters = 8
  }

  var configuration = Configuration()
  private(set) var committedText = ""

  private var lastVolatile = ""
  private var candidate = ""
  private var candidateSince: Date?
  private var utteranceStartedAt: Date?
  private var lastUpdateAt: Date?
  private var stableUpdates = 0

  mutating func ingest(_ text: String, isFinal: Bool,
                       now: Date = Date()) -> [String] {
    let normalized = speechText(text)
    if normalized.isEmpty {
      if isFinal {
        reset()
      } else {
        revokeVolatile(now: now)
      }
      return []
    }

    if isFinal {
      let chunks = commitFinal(normalized, now: now)
      reset()
      return chunks
    }

    if utteranceStartedAt == nil {
      utteranceStartedAt = now
    }
    lastUpdateAt = now

    // Latency fast path for the very first phrase. Waiting for the normal
    // stability window here costs the target's entire budget.
    if committedText.isEmpty {
      let hasLatin = normalized.contains { $0.isASCII && $0.isLetter }
      let threshold = hasLatin
        ? configuration.firstLatinCommitCharacters
        : configuration.firstCommitCharacters
      let firstTarget = Self.lastSentenceBoundary(in: normalized) ?? normalized
      if firstTarget.count >= threshold {
        return commit(firstTarget)
      }
    }

    let common = Self.commonPrefix(lastVolatile, normalized)
    let nextCandidate = common.hasPrefix(committedText)
      ? common
      : committedText

    if nextCandidate == candidate {
      stableUpdates += 1
    } else {
      candidate = nextCandidate
      candidateSince = now
      stableUpdates = 0
    }
    lastVolatile = normalized

    if let boundary = Self.lastSentenceBoundary(in: normalized),
       boundary.count > committedText.count,
       normalized.hasPrefix(boundary),
       candidate.count < boundary.count {
      candidate = boundary
    }

    let pending = candidate.count - committedText.count
    let stableEnough = (stableUpdates >= 2
      || (candidateSince.map { now.timeIntervalSince($0) >= configuration.stabilityWindow } ?? false))
      && pending >= configuration.minimumCommitCharacters
    let lagged = (utteranceStartedAt.map {
      now.timeIntervalSince($0) >= configuration.maximumLag
    } ?? false) && pending >= configuration.minimumCommitCharacters
    let tooLong = pending >= configuration.maximumCharacters
    let boundaryReady = !candidate.isEmpty
      && Self.lastSentenceBoundary(in: candidate) == candidate

    if stableEnough || lagged || tooLong {
      return commit(candidate, trimToWord: true)
    }
    if boundaryReady {
      return commit(candidate)
    }
    return []
  }

  /// Called on a timer when no new volatile result has arrived. A pause is the
  /// strongest stability signal, so the last volatile text becomes committable.
  mutating func tick(now: Date = Date()) -> [String] {
    guard let lastUpdateAt,
          now.timeIntervalSince(lastUpdateAt) >= configuration.stabilityWindow,
          lastVolatile.count > committedText.count else {
      return []
    }
    var target = lastVolatile
    if let boundary = Self.lastSentenceBoundary(in: lastVolatile),
       boundary.count > committedText.count {
      target = boundary
      return commit(target)
    }
    if target.count - committedText.count < configuration.minimumCommitCharacters {
      return []
    }
    return commit(target, trimToWord: true)
  }

  mutating func reset() {
    committedText = ""
    lastVolatile = ""
    candidate = ""
    candidateSince = nil
    utteranceStartedAt = nil
    lastUpdateAt = nil
    stableUpdates = 0
  }

  /// A volatile result may revoke text it previously reported. Clear the
  /// pending candidate so the next tick cannot commit withdrawn words.
  mutating func revokeVolatile(now: Date = Date()) {
    lastVolatile = ""
    candidate = committedText
    candidateSince = nil
    lastUpdateAt = now
    stableUpdates = 0
  }

  /// True when a final result rewrites text that was already committed. The
  /// caption layer translates the whole final in that case instead of
  /// pretending the committed prefix is still authoritative.
  func finalDiverges(_ text: String) -> Bool {
    !committedText.isEmpty
      && !speechText(text).hasPrefix(committedText)
  }

  // MARK: - Committing

  private mutating func commit(_ target: String,
                               trimToWord: Bool = false) -> [String] {
    let finalTarget = trimToWord ? Self.wordSafePrefix(target) : target
    guard finalTarget.count > committedText.count,
          finalTarget.hasPrefix(committedText) else { return [] }
    let suffix = String(finalTarget.dropFirst(committedText.count))
    committedText = finalTarget
    candidate = finalTarget
    candidateSince = nil
    stableUpdates = 0
    utteranceStartedAt = lastUpdateAt
    return suffix.isEmpty ? [] : [suffix]
  }

  /// A stability or lag commit must not cut a Latin/Korean word in half: hold
  /// the trailing partial token for the next update or the final result. Text
  /// without whitespace (Chinese, Japanese) has no such boundary and keeps the
  /// character-level cut.
  private static func wordSafePrefix(_ target: String) -> String {
    if !target.contains(where: { $0.isWhitespace }) {
      // A long Latin token with no space is still one word; committing it would
      // split the word. CJK has no word spaces and keeps character-level cuts.
      return target.contains(where: { $0.isASCII && $0.isLetter }) ? "" : target
    }
    guard let last = target.last, !last.isWhitespace,
          !isSentenceBoundary(last), last != ".",
          let space = target.lastIndex(where: { $0.isWhitespace }) else {
      return target
    }
    return String(target[..<space])
  }

  private mutating func commitFinal(_ text: String, now: Date) -> [String] {
    var result: [String] = []
    if text.hasPrefix(committedText) {
      if text.count > committedText.count {
        result.append(String(text.dropFirst(committedText.count)))
        committedText = text
      }
    } else {
      let common = Self.commonPrefix(committedText, text)
      if common.count > committedText.count {
        result.append(String(common.dropFirst(committedText.count)))
        committedText = common
      }
    }
    return result.filter { !$0.isEmpty }
  }

  // MARK: - Text helpers

  private func speechText(_ text: String) -> String {
    SpeechTextNormalizer.normalize(text)
  }

  static func commonPrefix(_ lhs: String, _ rhs: String) -> String {
    var result = ""
    var left = lhs.startIndex
    var right = rhs.startIndex
    while left < lhs.endIndex, right < rhs.endIndex,
          lhs[left] == rhs[right] {
      result.append(lhs[left])
      left = lhs.index(after: left)
      right = rhs.index(after: right)
    }
    return result
  }

  static func isSentenceBoundary(_ character: Character) -> Bool {
    "。！？!?；;".contains(character)
  }

  /// A Latin period counts only when it ends a sentence: the next character is
  /// whitespace or the end, and the previous character is not a digit, so
  /// "3.14" never commits in the middle.
  private static func isPeriodBoundary(_ text: String, at index: String.Index) -> Bool {
    guard text[index] == "." else { return false }
    let previous = index > text.startIndex
      ? text[text.index(before: index)] : nil
    if let previous, previous.isNumber { return false }
    let next = text.index(after: index)
    return next == text.endIndex || text[next].isWhitespace
  }

  private static func lastSentenceBoundary(in text: String) -> String? {
    var result: String.Index?
    for index in text.indices {
      if isSentenceBoundary(text[index])
          || isPeriodBoundary(text, at: index) {
        result = index
      }
    }
    guard let result else { return nil }
    return String(text[...result])
  }
}
