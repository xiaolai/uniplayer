//
//  LibraryMetadata.swift
//  uniplayer
//
//  What a file name can honestly say about a video. This is deliberately a
//  parser, not a scraper: a title, a year, a season and episode, and a quality
//  token are recoverable from the name; anything else needs a metadata service.
//

import Foundation

struct LibraryMetadata: Hashable {
  let title: String
  let year: Int?
  let season: Int?
  let episode: Int?
  let quality: String?

  var episodeCode: String? {
    guard let season, let episode else { return nil }
    return String(format: "S%02dE%02d", season, episode)
  }

  /// A compact line for the detail page, with only the facts that exist.
  var detailLine: String {
    [year.map(String.init), episodeCode, quality]
      .compactMap { $0 }
      .joined(separator: " · ")
  }

  static func parse(fileName: String) -> LibraryMetadata {
    let base = (fileName as NSString).deletingPathExtension
    let normalized = base
      .replacingOccurrences(of: ".", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "  ", with: " ")
      .trimmingCharacters(in: .whitespaces)

    let seasonEpisode = firstMatch(
      #"(?i)\bS(\d{1,2})\s*E(\d{1,3})\b"#, in: normalized)
    let crossed = firstMatch(
      #"(?i)\b(\d{1,2})x(\d{2,3})\b"#, in: normalized)
    let spelled = firstMatch(
      #"(?i)\bSeason\s*(\d{1,2})\s*Episode\s*(\d{1,3})\b"#, in: normalized)

    let season = integer(seasonEpisode, 1) ?? integer(spelled, 1) ?? integer(crossed, 1)
    let episode = integer(seasonEpisode, 2) ?? integer(spelled, 2) ?? integer(crossed, 2)

    let qualityMatch = firstMatch(
      #"(?i)\b(2160p|1080p|720p|480p|4K|UHD)\b"#, in: normalized)
    let quality = qualityMatch?.first

    let yearMatch = firstMatch(#"\b(19\d{2}|20\d{2})\b"#, in: normalized)
    let year = yearMatch?.first.flatMap(Int.init)

    // The title is everything before the first token that is not part of it.
    var cut = normalized.count
    for pattern in [
      #"(?i)\bS\d{1,2}\s*E\d{1,3}\b"#,
      #"(?i)\b\d{1,2}x\d{2,3}\b"#,
      #"(?i)\bSeason\s*\d{1,2}\s*Episode\s*\d{1,3}\b"#,
      #"\b(19\d{2}|20\d{2})\b"#,
      #"(?i)\b(2160p|1080p|720p|480p|4K|UHD)\b"#,
      #"(?i)\b(WEB[- ]?DL|WEBRip|BluRay|BDRip|BRRip|HDTV|DVDRip|Remux)\b"#,
      #"(?i)\b(x264|x265|H\.?264|H\.?265|HEVC|AV1|AAC|AC3|DTS|DDP?5\.1)\b"#
    ] {
      if let range = normalized.range(of: pattern, options: .regularExpression) {
        cut = min(cut, normalized.distance(from: normalized.startIndex, to: range.lowerBound))
      }
    }

    var title = String(normalized.prefix(cut))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let dash = title.range(of: #"\s+-\s*$"#, options: .regularExpression) {
      title.removeSubrange(dash)
    }
    title = title.trimmingCharacters(in: CharacterSet(charactersIn: " -–—[]()"))

    // A name that starts with the episode marker carries its title after it.
    if title.isEmpty {
      for pattern in [
        #"(?i)\bSeason\s*\d{1,2}\s*Episode\s*\d{1,3}\b"#,
        #"(?i)\bS\d{1,2}\s*E\d{1,3}\b"#,
        #"(?i)\b\d{1,2}x\d{2,3}\b"#
      ] {
        guard let range = normalized.range(of: pattern, options: .regularExpression) else { continue }
        let suffix = String(normalized[range.upperBound...])
          .trimmingCharacters(in: CharacterSet(charactersIn: " -–—[]()"))
        if !suffix.isEmpty {
          title = suffix
          break
        }
      }
    }

    return LibraryMetadata(
      title: title.isEmpty ? base : title,
      year: year,
      season: season,
      episode: episode,
      quality: quality)
  }

  private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    var groups: [String] = []
    for index in 0..<match.numberOfRanges {
      if let group = Range(match.range(at: index), in: text) {
        groups.append(String(text[group]))
      } else {
        groups.append("")
      }
    }
    return groups
  }

  private static func integer(_ groups: [String]?, _ index: Int) -> Int? {
    guard let groups, groups.indices.contains(index), !groups[index].isEmpty else { return nil }
    return Int(groups[index])
  }
}
