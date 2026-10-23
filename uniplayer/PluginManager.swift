//
//  SettingsPluginUIUtils.swift
//  uniplayer
//
//  Created by Hechen Li on 2026-04-17.
//  Copyright © 2026 lhc. All rights reserved.
//

enum PluginInstallErrorMessage {
  static func message(for error: Error) -> String {
    guard let error = error as? JavascriptPlugin.PluginError else { return error.localizedDescription }
    switch error {
    case .fileNotFound: return NSLocalizedString("plugin.install_error.file_not_found", comment: "")
    case .invalidURL: return NSLocalizedString("plugin.install_error.invalid_url", comment: "")
    case .cannotDownload:
      return NSLocalizedString("The plugin could not be downloaded. Check the URL and your connection, then try again.", comment: "Plugin recovery")
    case .cannotUnpackage:
      return NSLocalizedString("The plugin package could not be extracted. Download a fresh copy or choose another package.", comment: "Plugin recovery")
    case .cannotLoadPlugin: return NSLocalizedString("plugin.install_error.cannot_load", comment: "")
    }
  }
}

class PluginManager {
  enum Result {
    case installed, reinstalled, cancelled, noUpdate
  }

  private let window: NSWindow

  private var installationHandler: ((Result) -> Void)?

  init(window: NSWindow) {
    self.window = window
  }

  @MainActor
  func showPermissionsSheet(forPlugin plugin: JavascriptPlugin, previousPlugin: JavascriptPlugin? = nil) async -> Bool {
    let alert = NSAlert()
    let permissionListView = PrefPluginPermissionListView()
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: Tokens.Size.n500, height: Tokens.Size.n300))
    permissionListView.translatesAutoresizingMaskIntoConstraints = false
    alert.messageText = NSLocalizedString("alert.title_warning", comment: "Warning")
    alert.informativeText = NSLocalizedString(previousPlugin == nil ? "alert.plugin_permission" : "alert.plugin_permission_added", comment: "")
    alert.alertStyle = .warning
    alert.accessoryView = scrollView
    scrollView.drawsBackground = false
    scrollView.documentView = permissionListView
    Utility.quickConstraints(["H:|-0-[v]-0-|", "V:|-0-[v]"], ["v": permissionListView])
    alert.addButton(withTitle: NSLocalizedString("plugin.install", comment: "Install"))
    alert.addButton(withTitle: NSLocalizedString("general.cancel", comment: "Cancel"))
    permissionListView.setPlugin(plugin, onlyShowAddedFrom: previousPlugin)
    alert.layout()
    let height = permissionListView.frame.height
    if height < 300 {
      scrollView.frame.size.height = height
      alert.layout()
    }
    return await alert.beginSheetModal(for: self.window) == .alertFirstButtonReturn
  }

  @MainActor
  func update(_ plugin: JavascriptPlugin) async -> (Result, JavascriptPlugin?) {
    do {
      // check if new update exists
      guard let version = try await plugin.checkNewVersion() else {
        await Dialogs.alert("plugin_no_update", style: .informational).show(in: window)
        return (.noUpdate, nil)
      }

      // ask if the user wants to install
      guard await Dialogs.ask("plugin_update_found",
                              titleArgs: [plugin.name],
                              messageArgs: [version, plugin.version]).show(in: window) else {
        return (.cancelled, nil)
      }

      // install update off the main actor; unpacking and network work must not
      // block the consent UI.
      guard let newPlugin = try await Task.detached(priority: .userInitiated, operation: {
        try plugin.updated()
      }).value else {
        return (.cancelled, nil)
      }

      // Alert the user if the update adds a permission or widens the network
      // scope. A wider domain list is a new capability even when the
      // network-request permission itself is unchanged.
      let newPermissions = newPlugin.permissions.subtracting(plugin.permissions)
      let oldDomains = Set(plugin.domainList)
      let newDomains = Set(newPlugin.domainList)
      let domainsExpanded = newPlugin.permissions.contains(.networkRequest)
        && !oldDomains.contains("*")
        && !newDomains.isSubset(of: oldDomains)
      var permissionCleared = newPermissions.isEmpty && !domainsExpanded
      if !permissionCleared {
        permissionCleared = await showPermissionsSheet(
          forPlugin: newPlugin,
          previousPlugin: domainsExpanded ? nil : plugin)
      }
      if permissionCleared {
        if let pos = plugin.remove() {
          JavascriptPlugin.plugins.insert(newPlugin, at: pos)
        }
        newPlugin.normalizePath()
        newPlugin.reloadGlobalInstance()
        PlayerCore.reloadPluginForAll(newPlugin, forced: true)
        return (.installed, newPlugin)
      }
      return (.cancelled, nil)
    } catch let error {
      handleInstallationError(error)
      return (.cancelled, nil)
    }
  }

  @MainActor
  func handleInstallationError(_ error: Error) {
    let message = PluginInstallErrorMessage.message(for: error)
    // Keep process stderr out of the alert. A subprocess diagnostic can be
    // thousands of lines; the recovery message stays readable and bounded.
    Logger.log("Plugin installation failed: \(message)", level: .error)
    if Thread.isMainThread {
      Utility.showAlert("plugin.install_error", arguments: [message], sheetWindow: window)
    } else {
      DispatchQueue.main.sync {
        Utility.showAlert("plugin.install_error", arguments: [message], sheetWindow: window)
      }
    }
  }

  @MainActor
  private func install(_ plugin: JavascriptPlugin) async -> Result {
    if !plugin.permissions.isEmpty {
      guard await showPermissionsSheet(forPlugin: plugin) else {
        plugin.remove()
        return .cancelled
      }
    }
    // check whether a duplicate plugin exists, if yes, replace
    if let pos = JavascriptPlugin.plugins.firstIndex(where: { $0.identifier == plugin.identifier }) {
      guard await Dialogs.ask("plugin_reinstall", titleArgs: [plugin.name]).show(in: window) else {
        plugin.remove()
        return .cancelled
      }
      // uninstall the old plugins
      let oldPlugin = JavascriptPlugin.plugins[pos]
      oldPlugin.enabled = false
      oldPlugin.remove()
      // install the new plugin
      plugin.normalizePath()
      JavascriptPlugin.plugins.insert(plugin, at: pos)
      plugin.enabled = true
      return .reinstalled
    } else {
      plugin.normalizePath()
      JavascriptPlugin.plugins.append(plugin)
      plugin.enabled = true
      return .installed
    }
  }

  @MainActor
  func install(gitHubString string: String? = nil, localPackageURL url: URL? = nil, handler: ((Result) -> Void)? = nil) async {
    do {
      let plugin = try await Task.detached(priority: .userInitiated) {
        if let string {
          return try JavascriptPlugin.create(fromGitURL: string)
        } else if let url {
          return try JavascriptPlugin.create(fromPackageURL: url)
        } else {
          fatalError("PluginManager.install: a source must be provided.")
        }
      }.value
      let res = await install(plugin)
      handler?(res)
    } catch let error {
      handleInstallationError(error)
      handler?(.cancelled)
    }
  }

  @MainActor
  func uninstall(_ plugin: JavascriptPlugin) async -> Bool {
    guard await Dialogs.ask("plugin_uninstall", titleArgs: [plugin.name]).show(in: window) else {
      return false
    }
    plugin.enabled = false
    plugin.remove()
    return true
  }
}
