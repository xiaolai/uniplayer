//
//  PlaybackContext.swift
//  uniplayer
//
//  What the AI inspector may know about playback. The type is a plain value so
//  it is deterministic and testable, and the builder is the only place that
//  decides what a local path looks like in a request. Nothing reaches a model
//  until the user sends, and a full path needs an explicit opt-in.
//

import Foundation

/// A frozen copy of the player state a context is built from.
struct PlayerSnapshot: Equatable {
  let title: String?
  let url: URL?
  let isNetwork: Bool
  let position: Double?
  let duration: Double?
  let speed: Double
  let audioTrack: String?
  let subtitleTrack: String?
  let subtitleLine: String?

  static func capture(from player: PlayerCore) -> PlayerSnapshot {
    let info = player.info
    return PlayerSnapshot(
      title: info.currentURL?.lastPathComponent,
      url: info.currentURL,
      isNetwork: info.isNetworkResource,
      position: info.videoPosition?.second,
      duration: info.videoDuration?.second,
      speed: info.playSpeed,
      audioTrack: info.currentTrack(.audio)?.readableTitle,
      subtitleTrack: info.currentTrack(.sub)?.readableTitle,
      subtitleLine: player.mpv.getString(MPVProperty.subText)?
        .trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

/// The explicit context the inspector shows before a request.
struct PlaybackContext: Equatable {
  struct LibrarySummary: Equatable {
    let title: String
    let folder: String
    let detailLine: String
  }

  let title: String?
  /// A redacted source: a file name, or a network host and path without query.
  let source: String?
  /// Present only when the user opted in for this request.
  let filePath: String?
  let position: Double?
  let duration: Double?
  let speed: Double
  let audioTrack: String?
  let subtitleTrack: String?
  let subtitleLine: String?
  let selection: String?
  let library: LibrarySummary?

  var timestamp: String? {
    guard let position else { return nil }
    return VideoTime(position).stringRepresentation
  }

  /// The "what will be sent" disclosure, in the order the model sees it.
  var disclosure: String {
    var lines: [String] = []
    if let title { lines.append("Title: \(title)") }
    if let source { lines.append("Source: \(source)") }
    if let filePath { lines.append("Path: \(filePath)") }
    if let position, let duration {
      lines.append("Position: \(VideoTime(position).stringRepresentation) of \(VideoTime(duration).stringRepresentation)")
    } else if let position {
      lines.append("Position: \(VideoTime(position).stringRepresentation)")
    }
    lines.append(String(format: "Speed: %.3g×", speed))
    if let audioTrack { lines.append("Audio: \(audioTrack)") }
    if let subtitleTrack { lines.append("Subtitles: \(subtitleTrack)") }
    if let subtitleLine { lines.append("Current subtitle: \(subtitleLine)") }
    if let selection { lines.append("Selection: \(selection)") }
    if let library {
      var line = "Library: \(library.title) — \(library.folder)"
      if !library.detailLine.isEmpty {
        line += " (\(library.detailLine))"
      }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }
}

/// The one privacy rule for turning a URL into a source string: file URLs
/// become the file name, and network URLs lose their query and fragment.
enum SourceRedaction {
  static func source(url: URL?, isNetwork: Bool) -> String? {
    guard let url else { return nil }
    if url.isFileURL || !isNetwork {
      return url.lastPathComponent.nilIfEmpty
    }
    guard let host = url.host else {
      return url.lastPathComponent.nilIfEmpty
    }
    return host + url.path
  }
}

/// A channel page's explicit context. It exists only after the user acts: the
/// page is never scraped automatically.
struct ChannelPageContext: Equatable {
  let title: String
  let url: URL
  let selection: String?

  var source: String {
    SourceRedaction.source(url: url, isNetwork: !url.isFileURL)
      ?? url.lastPathComponent
  }

  var disclosure: String {
    var lines = ["Page: \(title)", "Source: \(source)"]
    if let selection, !selection.isEmpty {
      lines.append("Selection: \(selection)")
    }
    return lines.joined(separator: "\n")
  }
}

/// Removes a previously approved local path from retained text, including the
/// JSON-escaped form used inside tool-call arguments.
enum AssistantRedaction {
  static func scrub(_ text: String, path: String, replacement: String) -> String {
    guard !path.isEmpty else { return text }
    let escaped = path
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "/", with: "\\/")
    return text
      .replacingOccurrences(of: path, with: replacement)
      .replacingOccurrences(of: escaped, with: replacement)
  }
}

/// Builds a context from values, never from a live player, so tests can pin
/// every field.
enum PlaybackContextBuilder {

  struct Options {
    var selection: String?
    var libraryItem: LibraryItem?
    /// Off by default. The full path is the one field users must ask for.
    var includeFilePath = false

    init(selection: String? = nil, libraryItem: LibraryItem? = nil,
         includeFilePath: Bool = false) {
      self.selection = selection
      self.libraryItem = libraryItem
      self.includeFilePath = includeFilePath
    }
  }

  static func make(snapshot: PlayerSnapshot, options: Options) -> PlaybackContext {
    let library = options.libraryItem.map {
      PlaybackContext.LibrarySummary(
        title: $0.title,
        folder: $0.subtitle,
        detailLine: $0.metadata.detailLine)
    }
    return PlaybackContext(
      title: options.libraryItem?.title ?? snapshot.title,
      source: redactedSource(url: snapshot.url, isNetwork: snapshot.isNetwork),
      filePath: options.includeFilePath ? snapshot.url?.path : nil,
      position: snapshot.position,
      duration: snapshot.duration,
      speed: snapshot.speed,
      audioTrack: snapshot.audioTrack?.nilIfEmpty,
      subtitleTrack: snapshot.subtitleTrack?.nilIfEmpty,
      subtitleLine: snapshot.subtitleLine?.nilIfEmpty,
      selection: options.selection?.nilIfEmpty,
      library: library)
  }

  /// File URLs become the file name. Network URLs become host + path, with
  /// the query and fragment dropped because they can carry tokens.
  static func redactedSource(url: URL?, isNetwork: Bool) -> String? {
    SourceRedaction.source(url: url, isNetwork: isNetwork)
  }
}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
