//
//  AssistantTools.swift
//  uniplayer
//
//  The typed tool surface. Providers may emit a tool call, but only the names
//  and arguments declared here are accepted. A tool that changes playback
//  (seek) is executed only after the inspector asks the user.
//

import AppKit

struct AssistantToolDefinition {
  let name: String
  let description: String
  let parameters: [String: Any]
}

enum AssistantToolName: String, CaseIterable {
  case seek
  case summarizeRange
  case translateSubtitle
  case explainSelection
  case findRelatedItems

  var isStateChanging: Bool {
    self == .seek
  }

  var definition: AssistantToolDefinition {
    switch self {
    case .seek:
      return AssistantToolDefinition(
        name: rawValue,
        description: "Seek the video to an absolute position in seconds. Requires user confirmation.",
        parameters: [
          "type": "object",
          "properties": [
            "seconds": ["type": "number", "description": "Absolute position in seconds from the start."],
            "reason": ["type": "string", "description": "Why this position is useful."],
          ],
          "required": ["seconds"],
        ])
    case .summarizeRange:
      return AssistantToolDefinition(
        name: rawValue,
        description: "Summarize what happens between two positions using the known playback metadata.",
        parameters: [
          "type": "object",
          "properties": [
            "start": ["type": "number", "description": "Start position in seconds."],
            "end": ["type": "number", "description": "End position in seconds."],
          ],
          "required": ["start", "end"],
        ])
    case .translateSubtitle:
      return AssistantToolDefinition(
        name: rawValue,
        description: "Translate the subtitle line currently on screen.",
        parameters: [
          "type": "object",
          "properties": [
            "targetLanguage": ["type": "string", "description": "Language to translate into."],
          ],
          "required": [],
        ])
    case .explainSelection:
      return AssistantToolDefinition(
        name: rawValue,
        description: "Explain a selection the user supplied.",
        parameters: [
          "type": "object",
          "properties": [
            "text": ["type": "string", "description": "The selected text."],
          ],
          "required": ["text"],
        ])
    case .findRelatedItems:
      return AssistantToolDefinition(
        name: rawValue,
        description: "Find related items in the user's library history.",
        parameters: [
          "type": "object",
          "properties": [
            "query": ["type": "string", "description": "Words to match against library titles."],
          ],
          "required": ["query"],
        ])
    }
  }
}

enum AssistantToolArguments: Equatable {
  case seek(seconds: Double, reason: String?)
  case summarizeRange(start: Double, end: Double)
  case translateSubtitle(targetLanguage: String?)
  case explainSelection(text: String)
  case findRelatedItems(query: String)
}

struct AssistantTypedToolCall: Equatable {
  let id: String
  let tool: AssistantToolName
  let arguments: AssistantToolArguments

  var requiresConfirmation: Bool { tool.isStateChanging }
}

enum AssistantToolError: Error, Equatable, LocalizedError {
  case unknownTool(String)
  case invalidArguments(tool: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .unknownTool(let name):
      return String(format: NSLocalizedString("The assistant asked for an unknown tool: %@", comment: "Assistant tool error"), name)
    case .invalidArguments(let tool, let reason):
      return String(format: NSLocalizedString("Invalid arguments for %@: %@", comment: "Assistant tool error"), tool, reason)
    }
  }
}

/// Turns a provider tool call into a typed call, rejecting anything not
/// declared above.
enum AssistantToolParser {

  static func parse(_ call: AssistantToolCall) throws -> AssistantTypedToolCall {
    guard let tool = AssistantToolName(rawValue: call.name) else {
      throw AssistantToolError.unknownTool(call.name)
    }
    let json = try argumentsObject(call.argumentsJSON)
    switch tool {
    case .seek:
      let seconds = try number(json, "seconds", tool: tool)
      return AssistantTypedToolCall(
        id: call.id, tool: tool,
        arguments: .seek(seconds: seconds, reason: string(json, "reason")))
    case .summarizeRange:
      let start = try number(json, "start", tool: tool)
      let end = try number(json, "end", tool: tool)
      guard end >= start else {
        throw AssistantToolError.invalidArguments(tool: tool.rawValue, reason: "end is before start")
      }
      return AssistantTypedToolCall(
        id: call.id, tool: tool, arguments: .summarizeRange(start: start, end: end))
    case .translateSubtitle:
      return AssistantTypedToolCall(
        id: call.id, tool: tool,
        arguments: .translateSubtitle(targetLanguage: string(json, "targetLanguage")))
    case .explainSelection:
      guard let text = string(json, "text"), !text.isEmpty else {
        throw AssistantToolError.invalidArguments(tool: tool.rawValue, reason: "text is missing")
      }
      return AssistantTypedToolCall(
        id: call.id, tool: tool, arguments: .explainSelection(text: text))
    case .findRelatedItems:
      guard let query = string(json, "query"), !query.isEmpty else {
        throw AssistantToolError.invalidArguments(tool: tool.rawValue, reason: "query is missing")
      }
      return AssistantTypedToolCall(
        id: call.id, tool: tool, arguments: .findRelatedItems(query: query))
    }
  }

  private static func argumentsObject(_ json: String) throws -> [String: Any] {
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    guard let data = trimmed.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AssistantToolError.invalidArguments(tool: "arguments", reason: "not a JSON object")
    }
    return object
  }

  /// The longest position a tool may request. A week is far beyond any real
  /// media file and keeps `VideoTime`'s integer conversion safe.
  static let maximumSeconds: Double = 7 * 24 * 60 * 60

  private static func number(_ json: [String: Any], _ key: String,
                             tool: AssistantToolName) throws -> Double {
    guard let raw = json[key] else {
      throw AssistantToolError.invalidArguments(tool: tool.rawValue, reason: "\(key) is missing")
    }
    // JSONSerialization bridges booleans to NSNumber; treat them as invalid.
    if CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID() {
      throw AssistantToolError.invalidArguments(tool: tool.rawValue, reason: "\(key) is not a number")
    }
    let value: Double
    if let number = raw as? NSNumber {
      value = number.doubleValue
    } else {
      throw AssistantToolError.invalidArguments(tool: tool.rawValue, reason: "\(key) is not a number")
    }
    guard value.isFinite, value >= 0, value <= maximumSeconds else {
      throw AssistantToolError.invalidArguments(
        tool: tool.rawValue, reason: "\(key) is outside 0...\(Int(maximumSeconds)) seconds")
    }
    return value
  }

  private static func string(_ json: [String: Any], _ key: String) -> String? {
    guard let value = json[key] as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// What a tool needs from the app. Kept narrow so tests can use a stub.
protocol AssistantToolExecuting: AnyObject {
  /// - Returns: `false` when playback cannot seek, so the tool can report a
  ///   failure instead of claiming it moved.
  @discardableResult
  func seek(to seconds: Double) -> Bool
  func currentSubtitle() -> String?
  func relatedItems(matching query: String) -> [String]
  func rangeDescription(start: Double, end: Double) -> String
}

/// Executes a typed call and returns the text handed back to the model.
enum AssistantToolExecutor {

  static func execute(_ call: AssistantTypedToolCall,
                      executor: AssistantToolExecuting) -> String {
    switch call.arguments {
    case .seek(let seconds, let reason):
      let target = VideoTime(seconds).stringRepresentation
      guard executor.seek(to: seconds) else {
        return String(format: NSLocalizedString("Could not seek to %@: playback is not active.", comment: "Assistant tool result"), target)
      }
      if let reason {
        return String(format: NSLocalizedString("Moved playback to %@: %@", comment: "Assistant tool result"), target, reason)
      }
      return String(format: NSLocalizedString("Moved playback to %@.", comment: "Assistant tool result"), target)
    case .summarizeRange(let start, let end):
      return executor.rangeDescription(start: start, end: end)
    case .translateSubtitle(let language):
      guard let subtitle = executor.currentSubtitle(), !subtitle.isEmpty else {
        return NSLocalizedString("There is no subtitle line on screen.", comment: "Assistant tool result")
      }
      if let language {
        return String(format: NSLocalizedString("Current subtitle (translate into %@): %@", comment: "Assistant tool result"), language, subtitle)
      }
      return String(format: NSLocalizedString("Current subtitle: %@", comment: "Assistant tool result"), subtitle)
    case .explainSelection(let text):
      return text
    case .findRelatedItems(let query):
      let items = executor.relatedItems(matching: query)
      if items.isEmpty {
        return String(format: NSLocalizedString("No library items match “%@”.", comment: "Assistant tool result"), query)
      }
      return items.joined(separator: "\n")
    }
  }
}

/// The live executor: playback goes through `PlayerCore`, library lookups go
/// through the playback history the library already reads.
final class PlayerAssistantToolExecutor: AssistantToolExecuting {
  private unowned let player: PlayerCore

  init(player: PlayerCore) {
    self.player = player
  }

  @discardableResult
  func seek(to seconds: Double) -> Bool {
    guard player.info.state.active, player.info.currentURL != nil else {
      return false
    }
    var succeeded = false
    // `checkError: true` would call Logger.fatal on a failed seek and kill the
    // app; the tool reports the failure to the assistant instead.
    player.mpv.command(
      .seek, args: ["\(seconds)", "absolute+exact"], checkError: false
    ) { returnValue in
      succeeded = returnValue >= 0
    }
    return succeeded
  }

  func currentSubtitle() -> String? {
    player.mpv.getString(MPVProperty.subText)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func relatedItems(matching query: String) -> [String] {
    let term = query.lowercased()
    let historyTitles = HistoryController.shared.history.compactMap { entry -> String? in
      let title = entry.title ?? entry.name
      return title.lowercased().contains(term) ? title : nil
    }
    let recentTitles = NSDocumentController.shared.recentDocumentURLs.compactMap { url -> String? in
      let name = url.deletingPathExtension().lastPathComponent
      return name.lowercased().contains(term) ? name : nil
    }
    return Array(Set(historyTitles + recentTitles)).sorted().prefix(10).map { $0 }
  }

  func rangeDescription(start: Double, end: Double) -> String {
    let startText = VideoTime(start).stringRepresentation
    let endText = VideoTime(end).stringRepresentation
    let duration = max(0, end - start)
    return String(
      format: NSLocalizedString("Range %@–%@ (%@ seconds). No transcript is stored; use the subtitle line and metadata available in context.",
                                comment: "Assistant tool result"),
      startText, endText, String(format: "%.0f", duration))
  }
}
