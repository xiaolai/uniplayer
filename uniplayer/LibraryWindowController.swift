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

/// Hosts the titlebar controls at the sidepane's trailing edge.
///
/// A titlebar accessory's leading position is up to AppKit; the hosting view
/// is sized from that position so the controls end just inside the fixed
/// sidepane, and start beside the traffic lights when the sidepane is hidden.
private final class LibraryTitlebarHost: NSView {
  private let hosting: NSHostingView<LibraryTitlebarControls>

  init(chrome: LibraryChrome) {
    hosting = NSHostingView(rootView: LibraryTitlebarControls(chrome: chrome))
    super.init(frame: .zero)
    hosting.autoresizingMask = []
    addSubview(hosting)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: Tokens.Size.sidebarWidth, height: Tokens.Size.n52)
  }

  override func layout() {
    super.layout()
    let leadingInset = convert(NSPoint.zero, to: nil).x
    let width = max(0, Tokens.Size.sidebarWidth - leadingInset - Tokens.Space.n8)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

final class LibraryWindowController: NSWindowController {

  weak var player: PlayerCore!
  private(set) var loaded = false
  private var commandDragMonitor: Any?
  private var sidebarShortcutMonitor: Any?
  private var titlebarAccessory: NSTitlebarAccessoryViewController?
  private let chrome = LibraryChrome()

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

    let hostingView = NSHostingView(rootView: LibraryRootView(player: player, chrome: chrome))
    window.contentView = hostingView

    // An empty unified toolbar gives the window the current titlebar metrics:
    // the traffic lights and the accessory share one centered row.
    let toolbar = NSToolbar(identifier: "UniPlayerLibraryChrome")
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
    toolbar.showsBaselineSeparator = false
    window.toolbar = toolbar

    let controls = LibraryTitlebarHost(chrome: chrome)
    controls.frame = NSRect(origin: .zero,
                            size: NSSize(width: Tokens.Size.sidebarWidth, height: Tokens.Size.n52))
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = controls
    accessory.layoutAttribute = .left
    window.addTitlebarAccessoryViewController(accessory)
    titlebarAccessory = accessory

    self.window = window
    self.loaded = true
    commandDragMonitor = window.installCommandDragMonitor()
    sidebarShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.window === self.window,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .control],
            event.charactersIgnoringModifiers?.lowercased() == "s" else {
        return event
      }
      self.chrome.toggleSidebar()
      return nil
    }
  }

  deinit {
    if let commandDragMonitor {
      NSEvent.removeMonitor(commandDragMonitor)
    }
    if let sidebarShortcutMonitor {
      NSEvent.removeMonitor(sidebarShortcutMonitor)
    }
  }

  @IBAction func toggleSidebar(_ sender: Any?) {
    chrome.toggleSidebar()
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
