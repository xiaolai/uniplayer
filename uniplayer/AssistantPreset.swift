//
//  AssistantPreset.swift
//  uniplayer
//
//  The small set of questions that make the inspector useful while watching.
//  A preset is only offered when the context needed to answer it exists, so
//  the button never promises a transcript the app does not have.
//

import Foundation

enum AssistantPreset: String, CaseIterable, Identifiable {
  case whatsHappening
  case whoIsThis
  case explainReference
  case translateLine
  case recap
  case reviews
  case worthContinuing
  case findSimilar
  case pageSummary
  case pageSelection

  var id: String { rawValue }

  var title: String {
    switch self {
    case .whatsHappening:
      return NSLocalizedString("What’s happening?", comment: "Assistant preset")
    case .whoIsThis:
      return NSLocalizedString("Who is this?", comment: "Assistant preset")
    case .explainReference:
      return NSLocalizedString("Explain this reference", comment: "Assistant preset")
    case .translateLine:
      return NSLocalizedString("Translate this line", comment: "Assistant preset")
    case .recap:
      return NSLocalizedString("Recap what just happened", comment: "Assistant preset")
    case .reviews:
      return NSLocalizedString("Reviews & discussion", comment: "Assistant preset")
    case .worthContinuing:
      return NSLocalizedString("Is it worth continuing?", comment: "Assistant preset")
    case .findSimilar:
      return NSLocalizedString("Find similar in library", comment: "Assistant preset")
    case .pageSummary:
      return NSLocalizedString("Summarize this page", comment: "Assistant preset")
    case .pageSelection:
      return NSLocalizedString("Explain the selection", comment: "Assistant preset")
    }
  }

  var symbol: String {
    switch self {
    case .whatsHappening, .recap: return "text.bubble"
    case .whoIsThis, .explainReference: return "person.crop.circle"
    case .translateLine: return "character.bubble"
    case .reviews, .worthContinuing: return "globe"
    case .findSimilar: return "rectangle.stack"
    case .pageSummary: return "doc.text.magnifyingglass"
    case .pageSelection: return "text.cursor"
    }
  }

  var usesResearch: Bool {
    self == .reviews || self == .worthContinuing
  }

  var prompt: String {
    switch self {
    case .whatsHappening:
      return NSLocalizedString(
        "What’s happening in the current scene? Use the recent dialogue and playback position; if the context does not explain it, say what is missing.",
        comment: "Assistant preset prompt")
    case .whoIsThis:
      return NSLocalizedString(
        "Who is the person being discussed in the current line or recent dialogue? Use only the attached context and say when the context does not identify them.",
        comment: "Assistant preset prompt")
    case .explainReference:
      return NSLocalizedString(
        "Explain the reference or allusion in the current line or recent dialogue. Distinguish what the context supports from background knowledge.",
        comment: "Assistant preset prompt")
    case .translateLine:
      return String(
        format: NSLocalizedString(
          "Translate the current subtitle line into %@. Keep the meaning and tone.",
          comment: "Assistant preset prompt"),
        SubtitleTranslationSettings.targetLanguage())
    case .recap:
      return NSLocalizedString(
        "Recap what just happened using the recent dialogue and the current playback position. Do not invent events you cannot see.",
        comment: "Assistant preset prompt")
    case .reviews:
      return NSLocalizedString(
        "What do people think about this title? Summarize the attached web research and cite the sources. Avoid spoilers beyond my current playback position; if a source discusses later events, do not reveal them.",
        comment: "Assistant preset prompt")
    case .worthContinuing:
      return NSLocalizedString(
        "Based on the attached reviews and discussion, is this worth continuing? Separate general reception from spoiler territory and state what remains uncertain.",
        comment: "Assistant preset prompt")
    case .findSimilar:
      return NSLocalizedString(
        "Find similar items in my library history that I might want to watch next.",
        comment: "Assistant preset prompt")
    case .pageSummary:
      return NSLocalizedString(
        "Summarize what this page is about using only its title, source and selected text.",
        comment: "Assistant preset prompt")
    case .pageSelection:
      return NSLocalizedString(
        "Explain the selected text on this page.",
        comment: "Assistant preset prompt")
    }
  }

  func isAvailable(player: PlaybackContext?, channel: ChannelPageContext?) -> Bool {
    // The channel context replaces the player context in the outgoing
    // disclosure, so a player preset must not be offered while it is active.
    if let channel {
      switch self {
      case .pageSummary:
        return true
      case .pageSelection:
        return channel.selection?.isEmpty == false
      default:
        return false
      }
    }
    guard let player else { return false }
    switch self {
    case .whatsHappening, .recap:
      return player.subtitleLine != nil || !player.recentDialogue.isEmpty
    case .whoIsThis, .explainReference:
      return player.subtitleLine != nil || player.selection != nil
        || !player.recentDialogue.isEmpty
    case .translateLine:
      return player.subtitleLine != nil
    case .reviews, .worthContinuing, .findSimilar:
      return player.title?.isEmpty == false
    case .pageSummary, .pageSelection:
      return false
    }
  }
}
