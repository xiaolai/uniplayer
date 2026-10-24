//
//  SubtitleCue.swift
//  uniplayer
//
//  Reads text subtitle files so AI translation can run ahead of playback.
//  Only the cue text and timing are kept; styling is deliberately discarded so
//  the translated line is rendered with the user's own subtitle style.
//

import Foundation

/// One timed subtitle line.
struct SubtitleCue: Equatable {
  var start: Double
  var end: Double
  var text: String

  /// The text used to look up a cached translation.
  ///
  /// Line breaks and repeated spaces do not change a translation, so they are
  /// collapsed for the cache key while the request keeps the original layout.
  var cacheText: String {
    text.split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
  }

  func contains(_ time: Double, delay: Double, speed: Double) -> Bool {
    let adjusted = (time - delay) / max(speed, 0.1)
    return adjusted >= start && adjusted < end
  }
}

extension Array where Element == SubtitleCue {
  /// The index of the cue on screen at the given playback time.
  ///
  /// Cue lists are sorted by start time. Overlap is legal in subtitle files, so
  /// the last cue that started and has not ended wins.
  func activeCueIndex(at time: Double, delay: Double = 0, speed: Double = 1) -> Int? {
    let adjusted = (time - delay) / Swift.max(speed, 0.1)
    var low = 0
    var high = count
    while low < high {
      let middle = (low + high) / 2
      if self[middle].start <= adjusted {
        low = middle + 1
      } else {
        high = middle
      }
    }
    var index = low - 1
    while index >= 0 {
      let cue = self[index]
      if cue.end > adjusted {
        return index
      }
      // A cue far in the past cannot contain the time; stop the backward scan.
      if adjusted - cue.end > 10 {
        break
      }
      index -= 1
    }
    return nil
  }

  func activeCue(at time: Double, delay: Double = 0, speed: Double = 1) -> SubtitleCue? {
    guard let index = activeCueIndex(at: time, delay: delay, speed: speed) else { return nil }
    return self[index]
  }
}

/// Parses SRT, WebVTT and ASS/SSA text subtitles.
///
/// Anything that cannot be read as text returns `nil`; the caller then falls
/// back to translating the line mpv currently reports.
enum SubtitleCueParser {

  /// Parses subtitle data.
  /// - Parameter encodingName: The mpv subtitle codepage when it is not `auto`.
  static func cues(from data: Data, encodingName: String? = nil) -> [SubtitleCue]? {
    guard let text = decode(data, encodingName: encodingName) else { return nil }
    return cues(from: text)
  }

  static func cues(from text: String) -> [SubtitleCue]? {
    var text = text
    if text.first == "\u{FEFF}" { text.removeFirst() }
    let lower = text.lowercased()
    if lower.contains("[events]"), lower.contains("dialogue:") || lower.contains("format:") {
      return parseASS(text)
    }
    if text.contains("-->") {
      return parseSRTorVTT(text)
    }
    return nil
  }

  // MARK: - Encoding

  static func decode(_ data: Data, encodingName: String? = nil) -> String? {
    if data.isEmpty { return nil }
    // A user-selected codepage wins over detection; mpv already uses it to
    // decode the same file for playback.
    if let encodingName, encodingName != "auto",
       let encoding = stringEncoding(for: encodingName),
       let text = String(data: data, encoding: encoding) {
      return normalizeDecoded(text)
    }
    if let text = String(data: data, encoding: .utf8) {
      return normalizeDecoded(text)
    }
    if data.starts(with: [0xFF, 0xFE]),
       let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
      return normalizeDecoded(text)
    }
    if data.starts(with: [0xFE, 0xFF]),
       let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
      return normalizeDecoded(text)
    }
    // Legacy single-byte encodings never fail to decode, so they are last.
    if let text = String(data: data, encoding: .windowsCP1252) {
      return normalizeDecoded(text)
    }
    return String(data: data, encoding: .isoLatin1).map(normalizeDecoded)
  }

  private static func normalizeDecoded(_ text: String) -> String {
    var text = text
    if text.first == "\u{FEFF}" { text.removeFirst() }
    return text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
  }

  private static func stringEncoding(for name: String) -> String.Encoding? {
    let candidates = [name, name.replacingOccurrences(of: "-", with: "_"),
                      name.replacingOccurrences(of: "_", with: "-")]
    for candidate in candidates {
      let cf = CFStringConvertIANACharSetNameToEncoding(candidate as CFString)
      if cf != kCFStringEncodingInvalidId {
        let ns = CFStringConvertEncodingToNSStringEncoding(cf)
        return String.Encoding(rawValue: ns)
      }
    }
    return nil
  }

  // MARK: - SRT and WebVTT

  private static func parseSRTorVTT(_ text: String) -> [SubtitleCue]? {
    let lines = text.components(separatedBy: "\n")
    var cues: [SubtitleCue] = []
    var index = 0
    while index < lines.count {
      while index < lines.count, parseTimecodeRange(lines[index]) == nil {
        index += 1
      }
      guard index < lines.count, let (start, end) = parseTimecodeRange(lines[index]) else {
        break
      }
      index += 1
      var body: [String] = []
      while index < lines.count {
        let line = lines[index]
        if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
        if parseTimecodeRange(line) != nil { break }
        body.append(line)
        index += 1
      }
      let cleaned = cleanMarkup(body.joined(separator: "\n"))
      if !cleaned.isEmpty, end > start {
        cues.append(SubtitleCue(start: start, end: end, text: cleaned))
      }
    }
    // The active-cue lookup relies on start order; some files are not sorted.
    cues.sort { $0.start < $1.start }
    return cues.isEmpty ? nil : cues
  }

  /// Parses `00:00:01,000 --> 00:00:03,500` and the WebVTT variant.
  private static func parseTimecodeRange(_ line: String) -> (Double, Double)? {
    guard let arrow = line.range(of: "-->") else { return nil }
    let startField = line[..<arrow.lowerBound]
    let endField = line[arrow.upperBound...]
    guard let start = parseTimestamp(startField),
          let end = parseTimestamp(endField) else { return nil }
    return (start, end)
  }

  private static func parseTimestamp(_ raw: Substring) -> Double? {
    let token = raw.trimmingCharacters(in: .whitespaces)
      .split(whereSeparator: { $0 == " " || $0 == "\t" })
      .first.map(String.init) ?? ""
    let normalized = token.replacingOccurrences(of: ",", with: ".")
    let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2 || parts.count == 3 else { return nil }
    let secondsPartIndex = parts.count - 1
    let secondsParts = parts[secondsPartIndex].split(separator: ".", omittingEmptySubsequences: false)
    guard secondsParts.count <= 2,
          let seconds = Double(secondsParts[0]),
          let minutes = Double(parts[secondsPartIndex - 1]) else { return nil }
    let hours = parts.count == 3 ? Double(parts[0]) : 0
    guard let hours, hours >= 0, minutes >= 0, seconds >= 0 else { return nil }
    var fraction = 0.0
    if secondsParts.count == 2 {
      let digits = String(secondsParts[1])
      guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
            let value = Double(digits) else { return nil }
      fraction = value / pow(10, Double(digits.count))
    }
    return hours * 3600 + minutes * 60 + seconds + fraction
  }

  // MARK: - ASS and SSA

  private static let defaultASSFields =
    ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]

  private static func parseASS(_ text: String) -> [SubtitleCue]? {
    var inEvents = false
    var fields = defaultASSFields
    var cues: [SubtitleCue] = []
    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") {
        inEvents = trimmed.lowercased() == "[events]"
        continue
      }
      guard inEvents else { continue }
      let lower = trimmed.lowercased()
      if lower.hasPrefix("format:") {
        fields = trimmed.dropFirst("format:".count)
          .split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        continue
      }
      guard lower.hasPrefix("dialogue:"),
            let startIndex = fields.firstIndex(of: "start"),
            let endIndex = fields.firstIndex(of: "end"),
            let textIndex = fields.firstIndex(of: "text") else { continue }
      let payload = String(trimmed.dropFirst("dialogue:".count))
        .trimmingCharacters(in: .whitespaces)
      let parts = payload.split(separator: ",", maxSplits: max(fields.count - 1, 0),
                                omittingEmptySubsequences: false)
      guard parts.count == fields.count,
            let start = parseASSTimestamp(String(parts[startIndex])),
            let end = parseASSTimestamp(String(parts[endIndex])) else { continue }
      let rawText = String(parts[textIndex])
      // Drawing events contain coordinates, not language.
      if rawText.range(of: #"\\p[1-9]"#, options: .regularExpression) != nil { continue }
      let cleaned = cleanASS(rawText)
      if !cleaned.isEmpty, end > start {
        cues.append(SubtitleCue(start: start, end: end, text: cleaned))
      }
    }
    cues.sort { $0.start < $1.start }
    return cues.isEmpty ? nil : cues
  }

  private static func parseASSTimestamp(_ raw: String) -> Double? {
    let parts = raw.trimmingCharacters(in: .whitespaces)
      .split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let hours = Double(parts[0]),
          let minutes = Double(parts[1]) else { return nil }
    let secondsParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
    guard secondsParts.count <= 2, let seconds = Double(secondsParts[0]),
          hours >= 0, minutes >= 0, seconds >= 0 else { return nil }
    var fraction = 0.0
    if secondsParts.count == 2 {
      let digits = String(secondsParts[1])
      guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
            let value = Double(digits) else { return nil }
      // ASS uses centiseconds: `.5` is 500 ms, `.05` is 50 ms.
      fraction = value / pow(10, Double(digits.count))
    }
    return hours * 3600 + minutes * 60 + seconds + fraction
  }

  // MARK: - Text cleanup

  private static func cleanASS(_ raw: String) -> String {
    var text = raw.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\N"#, with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\n"#, with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\h"#, with: " ", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func cleanMarkup(_ raw: String) -> String {
    var text = raw.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
    for (entity, replacement) in [
      ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
      ("&#39;", "'"), ("&nbsp;", " "),
    ] {
      text = text.replacingOccurrences(of: entity, with: replacement)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
