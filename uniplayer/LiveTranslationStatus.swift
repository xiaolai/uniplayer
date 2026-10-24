//
//  LiveTranslationStatus.swift
//  uniplayer
//
//  One honest state for menus and the inline player. Every unavailable state
//  has a named cause and an actionable destination; nothing reports a silent
//  "all good".
//

import Foundation

enum LiveTranslationAvailabilityState: Equatable {
  case off
  case subtitlePrecedence
  case resolving
  case chooseLanguage
  case checkingLanguage
  case otherPlayerActive
  case nothingToTranslate
  case noWatchedLanguages
  case unsupportedLanguage(String)
  case speechModelMissing(String)
  case permissionDenied
  case permissionSuspected
  case paused
  case transcriptionFailure(String)
  case fileAudioFallback(String)
  case captionFailure(String)
  case translating
  case translatingViaAI
}

struct LiveTranslationStatusInput {
  let enabled: Bool
  let textSubtitleActive: Bool
  let isPlaying: Bool
  let resolution: LiveTranslationLanguageResolution?
  let isTentativeLanguage: Bool
  let captureIsFile: Bool
  let anotherPlayerPlaying: Bool
  let permission: LiveTranslationAudioPermission.State
  let transcriptionFailure: String?
  let fileAudioFallback: String?
  let captionFailure: String?
  let usesAIProvider: Bool
}

enum LiveTranslationStatus {
  static func state(_ input: LiveTranslationStatusInput) -> LiveTranslationAvailabilityState {
    guard input.enabled else { return .off }
    if input.textSubtitleActive { return .subtitlePrecedence }

    guard let resolution = input.resolution else { return .resolving }
    switch resolution {
    case .needsChoice:
      if let failure = input.transcriptionFailure, !failure.isEmpty {
        return .transcriptionFailure(failure)
      }
      if let failure = input.captionFailure, !failure.isEmpty {
        return .captionFailure(failure)
      }
      if !input.captureIsFile, input.permission == .denied {
        return .permissionDenied
      }
      if input.anotherPlayerPlaying { return .otherPlayerActive }
      if input.isTentativeLanguage {
        return input.isPlaying ? .checkingLanguage : .paused
      }
      return .chooseLanguage    case .skip:
      return .nothingToTranslate
    case .unsupported(.noWatchedLanguages):
      return .noWatchedLanguages
    case .unsupported(.speechModelUnavailable(let language)):
      return .speechModelMissing(language.displayName)
    case .unsupported(.unrecognizedTag(let tag)):
      return .unsupportedLanguage(tag)
    case .resolved:
      break
    }

    if !input.isPlaying { return .paused }
    if input.anotherPlayerPlaying { return .otherPlayerActive }
    if let failure = input.transcriptionFailure, !failure.isEmpty {
      return .transcriptionFailure(failure)
    }
    if let failure = input.captionFailure, !failure.isEmpty {
      return .captionFailure(failure)
    }
    // A working fallback explains the permission state; show it before the
    // global permission guess so a muted or local-file run is not mislabeled.
    if let notice = input.fileAudioFallback, !notice.isEmpty {
      return .fileAudioFallback(notice)
    }
    // A file-backed session does not use system audio, so an old tap's
    // permission guess is irrelevant to it.
    if !input.captureIsFile {
      if input.permission == .denied { return .permissionDenied }
      if input.permission == .suspected { return .permissionSuspected }
    }
    return input.usesAIProvider ? .translatingViaAI : .translating
  }

  static func text(_ state: LiveTranslationAvailabilityState,
                   target: LiveTranslationLanguage) -> String {
    switch state {
    case .off:
      return NSLocalizedString(
        "Live translation is off", comment: "Live translation status")
    case .subtitlePrecedence:
      return NSLocalizedString(
        "A text subtitle track takes precedence",
        comment: "Live translation status")
    case .resolving:
      return NSLocalizedString(
        "Resolving the spoken language…", comment: "Live translation status")
    case .chooseLanguage:
      return NSLocalizedString(
        "Choose the spoken language", comment: "Live translation status")
    case .checkingLanguage:
      return NSLocalizedString(
        "Checking the spoken language…", comment: "Live translation status")
    case .otherPlayerActive:
      return NSLocalizedString(
        "Pause or close the other player to translate this one",
        comment: "Live translation status")
    case .nothingToTranslate:
      return NSLocalizedString(
        "Nothing to translate", comment: "Live translation status")
    case .noWatchedLanguages:
      return NSLocalizedString(
        "Choose languages to watch in Settings",
        comment: "Live translation status")
    case .unsupportedLanguage(let tag):
      return String(format: NSLocalizedString(
        "%@ is not supported", comment: "Live translation status"), tag)
    case .speechModelMissing(let language):
      return String(format: NSLocalizedString(
        "The %@ speech model is not installed",
        comment: "Live translation status"), language)
    case .permissionDenied:
      return NSLocalizedString(
        "System audio access is denied", comment: "Live translation status")
    case .permissionSuspected:
      return NSLocalizedString(
        "System audio may be blocked. Allow Screen & System Audio Recording in System Settings.",
        comment: "Live translation status")
    case .paused:
      return NSLocalizedString(
        "Paused", comment: "Live translation status")
    case .transcriptionFailure(let message):
      return message
    case .fileAudioFallback(let message):
      return message
    case .captionFailure(let message):
      return message
    case .translating:
      return String(format: NSLocalizedString(
        "Translating into %@", comment: "Live translation status"),
        target.displayName)
    case .translatingViaAI:
      return String(format: NSLocalizedString(
        "Translating into %@ with the AI provider",
        comment: "Live translation status"), target.displayName)
    }
  }

  /// A visible text subtitle in either the primary or the secondary slot takes
  /// precedence; drawing a live caption over either would overlap text.
  static func textSubtitleActive(for player: PlayerCore) -> Bool {
    if let subtitle = player.info.currentTrack(.sub),
       subtitle.id != 0, !subtitle.isImage {
      return true
    }
    if player.info.isSecondSubVisible,
       let secondary = player.info.currentTrack(.secondSub),
       secondary.id != 0, !secondary.isImage {
      return true
    }
    return false
  }

  static func state(for player: PlayerCore) -> LiveTranslationAvailabilityState {
    return state(LiveTranslationStatusInput(
      enabled: LiveTranslationPreferences.enabled,
      textSubtitleActive: textSubtitleActive(for: player),
      isPlaying: player.info.state == .playing,
      resolution: player.liveTranslationLanguage.resolution,
      isTentativeLanguage: player.liveTranslationLanguage.isTentative,
      captureIsFile: player.liveTranslationTranscription.usesFileAudio,
      anotherPlayerPlaying: player.liveTranslationTranscription.blockedByAnotherPlayer,
      permission: LiveTranslationAudioPermission.shared.state,
      transcriptionFailure: player.liveTranslationTranscription.lastFailure,
      fileAudioFallback: player.liveTranslationTranscription.fallbackNotice,
      captionFailure: player.liveTranslationCaptions.lastFailure,
      usesAIProvider: player.liveTranslationCaptions.isUsingAIProvider))
  }

  static func opensSettings(_ state: LiveTranslationAvailabilityState) -> Bool {
    switch state {
    case .noWatchedLanguages, .speechModelMissing, .unsupportedLanguage,
         .transcriptionFailure, .fileAudioFallback:
      return true
    case .captionFailure(let message):
      return !message.isEmpty
    default:
      return false
    }
  }
}
