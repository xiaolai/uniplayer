//
//  SettingsMode.swift
//  uniplayer
//
//  Two curated presentations of the same preferences. The mode changes which
//  pages and rows are shown; it never changes a preference value.
//

import Foundation

enum SettingsMode: String, CaseIterable {
  case simple
  case advanced

  static let defaultsKey = "settings.mode.v1"

  static var current: SettingsMode {
    get { SettingsMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .advanced }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
  }

  var title: String {
    switch self {
    case .simple: return NSLocalizedString("Simple", comment: "Settings mode")
    case .advanced: return NSLocalizedString("preference.advanced", comment: "Advanced")
    }
  }

  /// The last page is remembered per mode so switching back restores the page
  /// the reader was using, not the page from the other mode.
  var lastPageKey: String { "settings.lastPane.\(rawValue).v1" }
}


struct SettingsSidebarGroup {
  let title: String
  let identifiers: [String]
}

/// The one place that decides which pages appear, and in what order, for each
/// mode. The window and the tests both read this table.
enum SettingsSidebarLayout {
  static func groups(for mode: SettingsMode) -> [SettingsSidebarGroup] {
    let playback = SettingsSidebarGroup(
      title: NSLocalizedString("Playback", comment: "Settings group"),
      identifiers: ["general", "ui", "video", "audio", "subtitles"])
    let intelligence = SettingsSidebarGroup(
      title: NSLocalizedString("Intelligence", comment: "Settings group"),
      identifiers: ["liveTranslation", "assistant"])
    guard mode == .advanced else { return [playback, intelligence] }
    return [
      playback,
      intelligence,
      SettingsSidebarGroup(
        title: NSLocalizedString("Connections", comment: "Settings group"),
        identifiers: ["network", "control", "key.bindings"]),
      SettingsSidebarGroup(
        title: NSLocalizedString("System", comment: "Settings group"),
        identifiers: ["plugin", "utilities", "advanced"]),
    ]
  }
}
