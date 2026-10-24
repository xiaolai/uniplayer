//
//  LiveTranslationVerifier.swift
//  uniplayer
//
//  Deterministic checks that run on every caption, plus a repair gate that
//  only spends an AI call on flagged material. Ordinary lines never leave the
//  Mac and never invoke a second model.
//

import Foundation

enum CaptionVerificationFlag: String, CaseIterable, Equatable, Hashable {
  case lowConfidence
  case numberMismatch
  case unitMismatch
  case dateMismatch
  case negationDropped
  case acronymMismatch
  case glossaryMismatch
  case backTranslationMismatch
}

struct CaptionVerification: Equatable {
  var flags: Set<CaptionVerificationFlag> = []

  var requiresRepair: Bool { !flags.isEmpty }
  var hasDeterministicFlag: Bool {
    flags.contains { $0 != .lowConfidence }
  }
}

protocol CaptionVerifying {
  func setLanguages(source: String?, target: String?)
  func verify(source: String, target: String,
              confidence: Double?,
              glossary: [LiveTranslationGlossaryTerm]) -> CaptionVerification
}

extension CaptionVerifying {
  func setLanguages(source: String?, target: String?) {}
}

final class CaptionVerifier: CaptionVerifying {
  var confidenceThreshold: Double = 0.5
  private var decimalCommaSource = false
  private var decimalCommaTarget = false

  func setLanguages(source: String?, target: String?) {
    let commaLanguages: Set<String> = ["fr", "it"]
    decimalCommaSource = commaLanguages.contains(source ?? "")
    decimalCommaTarget = commaLanguages.contains(target ?? "")
  }

  private static let negationCues: [String] = [
    "not", "no", "never", "none", "nobody", "nothing", "neither", "nor",
    "don't", "doesn't", "didn't", "isn't", "aren't", "won't", "can't",
    "cannot", "without",
    "ne", "pas", "jamais", "rien", "aucun", "sans", "non",
    "mai", "niente", "nessuno", "senza",
    "不", "没", "無", "无", "别", "未", "없", "않", "아니", "ない", "ません",
  ]

  private static let unitSymbols = [
    "%", "‰", "°C", "°F", "$", "€", "£", "¥",
  ]

  func verify(source: String, target: String,
              confidence: Double?,
              glossary: [LiveTranslationGlossaryTerm]) -> CaptionVerification {
    var result = CaptionVerification()

    if let confidence, confidence < confidenceThreshold {
      result.flags.insert(.lowConfidence)
    }

    let sourceWithoutDates = Self.removingDates(from: source)
    let sourceNumbers = Self.numberTokens(
      in: sourceWithoutDates, decimalComma: decimalCommaSource)
    let targetNumbers = Set(Self.numberTokens(
      in: target, decimalComma: decimalCommaTarget))
    if sourceNumbers.contains(where: { !targetNumbers.contains($0) }) {
      result.flags.insert(.numberMismatch)
    }

    let targetDates = Self.dateTriples(in: target)
    var usedTargetDates = Set<Int>()
    for candidates in Self.sourceDateCandidates(in: source) {
      guard let first = candidates.first else { continue }
      if let index = targetDates.indices.first(where: {
        !usedTargetDates.contains($0) && candidates.contains(targetDates[$0])
      }) {
        usedTargetDates.insert(index)
        continue
      }
      if targetDates.isEmpty {
        // A month-name target has no numeric date to compare; year and day are
        // the strongest available check. Compare normalized values because
        // target number tokens carry a numeric form (e.g. "2026.0").
        let yearText = Self.normalizeNumericToken(String(first.year))
          ?? String(first.year)
        let dayText = Self.normalizeNumericToken(String(first.day))
          ?? String(first.day)
        if !targetNumbers.contains(yearText)
            || !targetNumbers.contains(dayText) {
          result.flags.insert(.dateMismatch)
        }
      } else {
        result.flags.insert(.dateMismatch)
      }
    }

    let sourceLower = source.lowercased()
    let targetLower = target.lowercased()
    if Self.unitSymbols.contains(where: {
      sourceLower.contains($0.lowercased()) && !targetLower.contains($0.lowercased())
    }) {
      result.flags.insert(.unitMismatch)
    }

    let sourceNegated = Self.containsNegation(sourceLower)
    let targetNegated = Self.containsNegation(targetLower)
    if sourceNegated && !targetNegated {
      result.flags.insert(.negationDropped)
    }

    let sourceAcronyms = Self.acronyms(in: source)
    let targetAcronyms = Set(Self.acronyms(in: target))
    if sourceAcronyms.contains(where: { !targetAcronyms.contains($0) }) {
      result.flags.insert(.acronymMismatch)
    }

    for term in glossary {
      let termSource = term.source.lowercased()
      guard !termSource.isEmpty, sourceLower.contains(termSource) else { continue }
      let expected = term.target.lowercased()
      if !expected.isEmpty && !targetLower.contains(expected) {
        result.flags.insert(.glossaryMismatch)
      }
    }

    return result
  }

  static func numbers(in text: String) -> [String] {
    numberTokens(in: text, decimalComma: false)
  }

  /// Arabic digits, English number words and simple Chinese numerals are
  /// normalized to the same numeric value so a correct "3" → "三" is not
  /// flagged. Signs and decimal-comma conventions are preserved as values.
  static func numberTokens(in text: String,
                           decimalComma: Bool = false) -> [String] {
    // Merge digit groups separated by a space or a thin/non-breaking space:
    // French writes 1 234,5 for 1234.5. Repeat for 1 234 567.
    var prepared = text
    let groupingPattern = "(\\d)[\u{00A0}\u{202F} ](\\d{3})(?!\\d)"
    for _ in 0..<2 {
      prepared = prepared.replacingOccurrences(
        of: groupingPattern, with: "$1$2", options: .regularExpression)
    }
    var result: [String] = []
    for match in matches(#"[-−+]?\d[\d.,]*"#, in: prepared) {
      result.append(contentsOf: numericTokens(
        from: match, decimalComma: decimalComma))
    }
    result += englishNumberTokens(in: text).compactMap {
      normalizeNumericToken($0, decimalComma: decimalComma)
    }
    for match in matchesWithRanges(#"[零一二两三四五六七八九十百]+"#, in: text) {
      guard !isNonNumericChinese(match.text, in: text, range: match.range),
            let value = chineseNumber(match.text),
            let normalized = normalizeNumericToken(
              String(value), decimalComma: decimalComma) else { continue }
      result.append(normalized)
    }
    return result
  }

  /// A comma-separated list is several quantities, not one number with
  /// thousands separators. In English/Chinese, only all-3-digit groups are
  /// grouping; in French/Italian a comma is the decimal separator.
  static func numericTokens(from raw: String,
                            decimalComma: Bool = false) -> [String] {
    var token = raw.replacingOccurrences(of: "−", with: "-")
    if token.hasPrefix("-") || token.hasPrefix("+") {
      token.removeFirst()
    }
    if decimalComma {
      if token.contains(","), !token.contains(".") {
        let parts = token.split(
          separator: ",", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 2 {
          return parts.compactMap {
            normalizeNumericToken($0, decimalComma: true)
          }
        }
      }
      return [normalizeNumericToken(raw, decimalComma: true)].compactMap { $0 }
    }
    if token.contains(","), !token.contains(".") {
      let parts = token.split(
        separator: ",", omittingEmptySubsequences: false).map(String.init)
      if parts.count > 2,
         !parts.dropFirst().allSatisfy({ $0.count == 3 }) {
        return parts.compactMap {
          normalizeNumericToken($0, decimalComma: false)
        }
      }
    }
    return [normalizeNumericToken(raw)].compactMap { $0 }
  }

  static func normalizeNumericToken(_ raw: String,
                                    decimalComma: Bool = false) -> String? {
    var token = raw.replacingOccurrences(of: "−", with: "-")
    var sign = ""
    if token.hasPrefix("-") || token.hasPrefix("+") {
      sign = String(token.first!)
      token.removeFirst()
    }
    token = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
    guard !token.isEmpty else { return nil }

    if decimalComma {
      // French/Italian: dot is grouping, comma is the decimal separator.
      token = token.replacingOccurrences(of: ".", with: "")
      token = token.replacingOccurrences(of: ",", with: ".")
    } else {
      let hasComma = token.contains(",")
      let hasDot = token.contains(".")
      if hasComma && hasDot {
        let lastComma = token.lastIndex(of: ",")!
        let lastDot = token.lastIndex(of: ".")!
        if lastComma > lastDot {
          token = token.replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
        } else {
          token = token.replacingOccurrences(of: ",", with: "")
        }
      } else if hasComma {
        let parts = token.split(separator: ",", omittingEmptySubsequences: false)
        if parts.count == 2, let fraction = parts.last,
           (1...2).contains(fraction.count) {
          token = parts[0] + "." + fraction
        } else {
          token = token.replacingOccurrences(of: ",", with: "")
        }
      }
    }

    if let value = Double(sign + token) {
      return String(value)
    }
    return sign + token
  }

  struct DateTriple: Equatable {
    let year: Int
    let month: Int
    let day: Int
  }

  /// Accepts year-first and day/month/year numeric forms. An ambiguous
  /// day/month order yields both candidates for one date, so a correct US or
  /// European date matches if either reading agrees, while a changed month
  /// matches neither.
  static func dateTriples(in text: String) -> [DateTriple] {
    sourceDateCandidates(in: text).flatMap { $0 }
  }

  /// The candidate readings of each date occurrence, kept grouped by
  /// occurrence. The verifier requires one reading per source date to match.
  static func sourceDateCandidates(in text: String) -> [[DateTriple]] {
    var result: [[DateTriple]] = []
    let yearFirst = #"(?<!\d)(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})日?"#
    for match in groups(yearFirst, in: text) {
      guard match.count == 3,
            let year = Int(match[0]), let month = Int(match[1]),
            let day = Int(match[2]),
            (1...12).contains(month), (1...31).contains(day) else { continue }
      result.append([DateTriple(year: year, month: month, day: day)])
    }
    let yearLast = #"(?<!\d)(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})(?!\d)"#
    for match in groups(yearLast, in: text) {
      guard match.count == 3,
            let first = Int(match[0]), let second = Int(match[1]),
            let year = Int(match[2]) else { continue }
      var candidates: [DateTriple] = []
      if (1...12).contains(first), (1...31).contains(second) {
        candidates.append(
          DateTriple(year: year, month: first, day: second))
      }
      if (1...12).contains(second), (1...31).contains(first),
         second != first {
        candidates.append(
          DateTriple(year: year, month: second, day: first))
      }
      if !candidates.isEmpty { result.append(candidates) }
    }
    return result
  }

  static func removingDates(from text: String) -> String {
    let pattern = #"(?:\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}日?|\d{1,2}[-/.]\d{1,2}[-/.]\d{4})"#
    return text.replacingOccurrences(
      of: pattern, with: " ", options: .regularExpression)
  }

  /// Chinese numerals appear inside ordinary words. These compounds are the
  /// common ones a speech sentence produces; treating them as numbers would
  /// flag a correct line and spend a repair call on it. The list deliberately
  /// excludes measure-word uses such as 一块 (money) and 十分钟 (time), which
  /// are real quantities.
  private static let nonNumericSuffixes: [Character: Set<Character>] = [
    "一": Set("起样直定般边些下点切共旦向会路时心并经致流览"),
    "百": Set("分"),
  ]

  private static func isNonNumericChinese(
    _ run: String, in text: String, range: Range<String.Index>
  ) -> Bool {
    guard run.count == 1, let numeral = run.first,
          let suffixes = nonNumericSuffixes[numeral] else { return false }
    let next = range.upperBound
    guard next < text.endIndex else { return false }
    return suffixes.contains(text[next])
  }

  private static let englishNumberWords: [String: Int] = [
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
    "nineteen": 19, "twenty": 20,
  ]

  private static func englishNumberTokens(in text: String) -> [String] {
    let pattern = #"\b("# + englishNumberWords.keys.sorted().joined(separator: "|") + #")\b"#
    return matches(pattern, in: text.lowercased()).compactMap {
      englishNumberWords[$0].map(String.init)
    }
  }

  private static let chineseDigits: [Character: Int] = [
    "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
    "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
  ]

  /// Parses the common Chinese numerals a spoken sentence produces (0–99 plus
  /// hundreds up to 999). Returns nil for runs that are not a number, such as
  /// the "一" in "一起" when followed by more than a digit.
  static func chineseNumber(_ text: String) -> Int? {
    guard !text.isEmpty else { return nil }
    if let digit = chineseDigits[text.first!], text.count == 1 {
      return digit
    }
    if text.hasPrefix("零") {
      return chineseNumber(String(text.dropFirst()))
    }
    if text == "十" { return 10 }
    if text.hasPrefix("十") {
      guard let rest = singleDigit(text.dropFirst()) else { return nil }
      return 10 + rest
    }
    if text.contains("百") {
      let parts = text.split(separator: "百", maxSplits: 1,
                             omittingEmptySubsequences: false)
      guard let hundreds = singleDigit(parts[0]) else { return nil }
      var value = hundreds * 100
      let remainder = String(parts.count > 1 ? parts[1] : "")
      if remainder.isEmpty { return value }
      guard let rest = chineseNumber(remainder) else { return nil }
      value += rest
      return value
    }
    if text.contains("十") {
      let parts = text.split(separator: "十", maxSplits: 1,
                             omittingEmptySubsequences: false)
      guard let tens = singleDigit(parts[0]) else { return nil }
      let ones = parts.count > 1 ? singleDigit(parts[1]) ?? 0 : 0
      return tens * 10 + ones
    }
    return nil
  }

  private static func singleDigit(_ text: Substring) -> Int? {
    guard text.count == 1, let character = text.first else { return nil }
    return chineseDigits[character]
  }

  static func acronyms(in text: String) -> [String] {
    matches(#"\b[A-Z]{2,6}"#, in: text)
  }

  private static func containsNegation(_ text: String) -> Bool {
    negationCues.contains { cue in
      if cue.unicodeScalars.allSatisfy({ $0.value < 0x3000 }) {
        return text.range(
          of: "\\b\(cue)\\b", options: .regularExpression) != nil
      }
      return text.contains(cue)
    }
  }

  private static func matches(_ pattern: String, in text: String) -> [String] {
    matchesWithRanges(pattern, in: text).map(\.text)
  }

  private static func matchesWithRanges(
    _ pattern: String, in text: String
  ) -> [(text: String, range: Range<String.Index>)] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      guard let range = Range(match.range, in: text) else { return nil }
      return (String(text[range]), range)
    }
  }

  private static func groups(_ pattern: String, in text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      guard match.numberOfRanges > 1 else { return nil }
      return (1..<match.numberOfRanges).compactMap { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) }
      }
    }
  }
}

/// Compares a back-translated final line with the source. It is a trigger, not
/// a gate: it only runs on final segments when repair is enabled.
struct BackTranslationComparison {
  func flags(source: String, backTranslated: String) -> Set<CaptionVerificationFlag> {
    var result: Set<CaptionVerificationFlag> = []
    let sourceNumbers = Set(CaptionVerifier.numbers(in: source))
    let backNumbers = Set(CaptionVerifier.numbers(in: backTranslated))
    if sourceNumbers.contains(where: { !backNumbers.contains($0) }) {
      result.insert(.backTranslationMismatch)
    }
    let sourceAcronyms = Set(CaptionVerifier.acronyms(in: source))
    if sourceAcronyms.contains(where: {
      !backTranslated.uppercased().contains($0)
    }) {
      result.insert(.backTranslationMismatch)
    }
    return result
  }
}

protocol LiveTranslationRepairing: AnyObject {
  func repair(source: String, candidate: String,
              glossary: [LiveTranslationGlossaryTerm],
              targetLanguage: String) async throws -> String
}

/// Bounds repair attempts so a noisy line cannot turn into a model call per
/// caption.
final class LiveTranslationRepairBudget {
  private let maximumAttempts: Int
  private let window: TimeInterval
  private var attempts: [Date] = []

  init(maximumAttempts: Int = 6, window: TimeInterval = 60) {
    self.maximumAttempts = maximumAttempts
    self.window = window
  }

  func allow(now: Date = Date()) -> Bool {
    attempts.removeAll { now.timeIntervalSince($0) >= window }
    guard attempts.count < maximumAttempts else { return false }
    attempts.append(now)
    return true
  }
}

/// The decision layer between the deterministic verifier and the AI repairer.
final class LiveTranslationRepairCoordinator {
  private let verifier: CaptionVerifying
  private let repairer: LiveTranslationRepairing?
  private let budget: LiveTranslationRepairBudget
  private let isEnabled: () -> Bool

  init(verifier: CaptionVerifying,
       repairer: LiveTranslationRepairing?,
       budget: LiveTranslationRepairBudget = LiveTranslationRepairBudget(),
       isEnabled: @escaping () -> Bool) {
    self.verifier = verifier
    self.repairer = repairer
    self.budget = budget
    self.isEnabled = isEnabled
  }

  func verification(source: String, target: String, confidence: Double?,
                    glossary: [LiveTranslationGlossaryTerm]) -> CaptionVerification {
    verifier.verify(
      source: source, target: target,
      confidence: confidence, glossary: glossary)
  }

  /// Returns a corrected target line, or nil when the line is clean, repair is
  /// off, only a non-final confidence flag is present, or the budget is spent.
  func repairIfNeeded(source: String, target: String, confidence: Double?,
                      isFinal: Bool,
                      glossary: [LiveTranslationGlossaryTerm],
                      targetLanguage: String) async -> String? {
    let result = verification(
      source: source, target: target,
      confidence: confidence, glossary: glossary)
    guard result.requiresRepair else { return nil }
    guard isFinal || result.hasDeterministicFlag else { return nil }
    guard isEnabled(), let repairer else { return nil }
    guard budget.allow() else { return nil }

    do {
      let corrected = try await repairer.repair(
        source: source, candidate: target,
        glossary: glossary, targetLanguage: targetLanguage)
      let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed != target else { return nil }
      return trimmed
    } catch {
      Logger.log("Live translation repair failed: \(error.localizedDescription)",
                 level: .debug)
      return nil
    }
  }
}
