//
//  KeyBindingConfigStore.swift
//  uniplayer
//
//  Shared key-binding configuration data and operations used by both the
//  current settings window and the legacy preferences window.
//

import Cocoa

enum KeyBindingConfigStore {

  static let defaultConfigMap: KeyValuePairs<String, String> = [
    "UniPlayer Default": "uniplayer-default-input",
    "mpv Default": "input",
    "VLC Default": "vlc-default-input",
    "Movist Default": "movist-default-input",
    "Movist v2 Default": "movist-v2-default-input",
  ]

  static let fallbackDefault = "UniPlayer Default"

  static let defaultConfigs: [String: String] = {
    var configs: [String: String] = [:]
    for (key, value) in defaultConfigMap {
      configs[key] = Bundle.main.path(forResource: value, ofType: "conf", inDirectory: "config")!
    }
    return configs
  }()

  static var userConfigs: [String: String] {
    do {
      let files = try FileManager.default.contentsOfDirectory(
        at: Utility.userInputConfDirURL,
        includingPropertiesForKeys: nil)
      let configFiles = files.filter { $0.pathExtension == "conf" }
      return Dictionary(uniqueKeysWithValues: configFiles.map {
        ($0.deletingPathExtension().lastPathComponent, $0.path)
      })
    } catch {
      Logger.fatal("Cannot get user config file!")
    }
  }

  static var configNames: [String] {
    defaultConfigMap.map { $0.key } + userConfigs.keys.sorted()
  }

  static let configNameValidator: Utility.InputValidator<String> = { input in
    if input.isEmpty {
      return .valueIsEmpty
    }
    if userConfigs[input] != nil || defaultConfigs[input] != nil {
      return .valueAlreadyExists
    }
    return .ok
  }

  static func isDefaultConfig(_ name: String) -> Bool {
    defaultConfigs[name] != nil
  }

  static func filePath(forConfig config: String, window: NSWindow?, showAlert: Bool = true) -> String? {
    let path = defaultConfigs[config] ?? userConfigs[config]
    if path == nil, showAlert {
      Utility.showAlert("error_finding_file", arguments: ["config"], sheetWindow: window)
    }
    return path
  }

  /// The path a new configuration should be created at, or `nil` when a file
  /// with that name already exists.
  static func newConfigPath(forName filename: String, window: NSWindow?) -> String? {
    let filePath = Utility.userInputConfDirURL.appendingPathComponent(filename + ".conf").path
    if FileManager.default.fileExists(atPath: filePath) {
      Utility.quickAskPanel("config.file_existing", sheetWindow: window) { result in
        if result == .alertFirstButtonReturn {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
        }
      }
      return nil
    }
    return filePath
  }

  static func save(_ mappings: [KeyMapping], to path: String, window: NSWindow?) {
    for mapping in mappings {
      mapping.rawKey = KeyCodeHelper.escapeReservedMpvKeys(mapping.rawKey)
    }
    do {
      try KeyMapping.generateInputConf(from: mappings).write(
        toFile: path, atomically: true, encoding: .utf8)
    } catch {
      Utility.showAlert("config.cannot_write", sheetWindow: window)
    }
  }

  static func showKeyBindingPanel(
    key: String = "",
    action: String = "",
    window: NSWindow?,
    ok: @escaping (String, String) -> Void
  ) {
    let panel = NSAlert()
    let keyRecordViewController = KeyRecordViewController()
    keyRecordViewController.keyCode = key
    keyRecordViewController.action = action
    panel.messageText = NSLocalizedString("keymapping.title", comment: "Key Mapping")
    panel.informativeText = NSLocalizedString("keymapping.message", comment: "Press any key to record.")
    panel.accessoryView = keyRecordViewController.view
    panel.window.initialFirstResponder = keyRecordViewController.keyRecordView
    let okButton = panel.addButton(withTitle: NSLocalizedString("general.ok", comment: "OK"))
    okButton.cell!.bind(.enabled, to: keyRecordViewController, withKeyPath: "ready", options: nil)
    panel.addButton(withTitle: NSLocalizedString("general.cancel", comment: "Cancel"))
    panel.beginSheetModal(for: window!) { respond in
      if respond == .alertFirstButtonReturn {
        let rawKey = KeyCodeHelper.escapeReservedMpvKeys(keyRecordViewController.keyCode)
        ok(rawKey, keyRecordViewController.action)
      }
    }
  }
}
