//
//  LibraryWindowController.swift
//  uniplayer
//
//  The window that shows the library. It owns the standard window chrome and a
//  real toolbar; the content is SwiftUI, and the only thing crossing the
//  boundary is PlayerCore opening a URL.
//

import AppKit
import SwiftUI

final class LibraryWindowController: NSWindowController {

  weak var player: PlayerCore!
  private(set) var loaded = false
  private var commandDragMonitor: Any?

  init(playerCore: PlayerCore) {
    self.player = playerCore
    super.init(window: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func showWindow(_ sender: Any?) {
    if !loaded {
      createWindow()
    }
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(nil)
  }

  private func createWindow() {
    let window = CommonWindow(
      contentRect: NSRect(origin: .zero, size: Tokens.Window.defaultSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false,
      usesUnifiedToolbar: true)

    window.title = "UniPlayer"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.toolbarStyle = .unified
    window.minSize = Tokens.Window.minimumSize
    window.isMovableByWindowBackground = true
    window.backgroundColor = Tokens.Palette.canvas.nsColor
    window.appearance = NSAppearance(uniplayerTheme: Preference.enum(for: .themeMaterial))

    if !window.setFrameUsingName("UniPlayerLibraryWindow") {
      window.center()
    }
    window.setFrameAutosaveName("UniPlayerLibraryWindow")

    let hostingView = NSHostingView(rootView: LibraryRootView(player: player))
    window.contentView = hostingView

    self.window = window
    self.loaded = true
    commandDragMonitor = window.installCommandDragMonitor()
  }

  deinit {
    if let commandDragMonitor {
      NSEvent.removeMonitor(commandDragMonitor)
    }
  }

  /// Called when history or recent documents have changed.
  func reloadData() {
    NotificationCenter.default.post(name: .libraryShouldReload, object: nil)
  }

  /// Kept for the launch path; the model reads the same stores on reload.
  func loadLastPlaybackInfo() {
    reloadData()
  }
}
