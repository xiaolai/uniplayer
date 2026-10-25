//
//  DialogueBuffer.swift
//  uniplayer
//
//  A small, bounded window of recently displayed subtitle lines. The assistant
//  gets dialogue the user actually saw, never a transcript of the whole file,
//  and the buffer is reset for each new file.
//

import Foundation

struct DialogueLine: Equatable {
  let position: Double
  let text: String

  var timestamp: String {
    VideoTime(position).stringRepresentation
  }
}

struct DialogueBuffer: Equatable {
  static let maxCharacters = 1_500
  static let maxLines = 40

  private(set) var lines: [DialogueLine] = []
  private(set) var characterCount = 0
  /// The full text of the last non-empty event. Kept separately because the
  /// stored line is clipped, and because an empty event ends a duplicate run.
  private var lastText: String?

  mutating func append(text: String, position: Double) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      lastText = nil
      return
    }
    // mpv can report the same displayed line more than once. Keeping the
    // duplicate would spend the character budget without adding information.
    guard lastText != trimmed else { return }
    lastText = trimmed

    let clipped = String(trimmed.prefix(Self.maxCharacters))
    let safePosition = position.isFinite ? max(0, position) : 0
    lines.append(DialogueLine(position: safePosition, text: clipped))
    characterCount += clipped.count

    while characterCount > Self.maxCharacters || lines.count > Self.maxLines {
      characterCount -= lines.removeFirst().text.count
    }
  }

  mutating func reset() {
    lines.removeAll()
    characterCount = 0
    lastText = nil
  }

  /// A hidden subtitle ends a duplicate run without discarding what was
  /// already visible.
  mutating func interrupt() {
    lastText = nil
  }

  /// Dialogue from the scene around the current position. Seeking can leave
  /// older lines, including ones from after a backward seek, in the buffer.
  func recent(endingAt position: Double?, window: TimeInterval = 180) -> [DialogueLine] {
    guard let position, position.isFinite else { return lines }
    return lines.filter {
      $0.position <= position + 0.5 && $0.position >= position - window
    }
  }

  var formatted: String {
    lines.map { "[\($0.timestamp)] \($0.text)" }.joined(separator: "\n")
  }
}
