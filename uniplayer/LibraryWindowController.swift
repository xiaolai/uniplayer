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
import WebKit

/// Shared hosting view for the library's titlebar accessories. Subclasses
/// decide their intrinsic size and how the hosted content fills it.
private class LibraryTitlebarHosting<Content: View>: NSView {
  let hosting: NSHostingView<Content>

  init(rootView: Content) {
    hosting = NSHostingView(rootView: rootView)
    super.init(frame: .zero)
    hosting.autoresizingMask = []
    addSubview(hosting)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

/// Hosts the leading controls at the sidepane's trailing edge.
///
/// A titlebar accessory's leading position is up to AppKit; the hosting view
/// is sized from that position so the controls end just inside the fixed
/// sidepane, and start beside the traffic lights when the sidepane is hidden.
private final class LibraryTitlebarHost: LibraryTitlebarHosting<LibraryTitlebarControls> {
  init(chrome: LibraryChrome) {
    super.init(rootView: LibraryTitlebarControls(chrome: chrome))
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
}

/// Hosts the trailing inspector button. The accessory gets the standard
/// titlebar height, so the button centers inside it.
private final class LibraryInspectorTitlebarHost:
  LibraryTitlebarHosting<InspectorTitlebarControls> {
  init(chrome: LibraryChrome) {
    super.init(rootView: InspectorTitlebarControls(chrome: chrome))
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: Tokens.Size.n52, height: Tokens.Size.n52)
  }

  override func layout() {
    super.layout()
    hosting.frame = bounds
  }
}

final class LibraryWindowController: NSWindowController, NSWindowDelegate {

  /// macOS virtual key code for Escape.
  private static let escapeKeyCode: UInt16 = 53

  weak var player: PlayerCore!
  private(set) var loaded = false
  private var commandDragMonitor: Any?
  private var sidebarShortcutMonitor: Any?
  private var inlineKeyMonitor: Any?
  private var menuActionHandler: MainMenuActionHandler?
  private var titlebarAccessory: NSTitlebarAccessoryViewController?
  private var inspectorAccessory: NSTitlebarAccessoryViewController?
  private let chrome: LibraryChrome

  private var savedColumnVisibility: NavigationSplitViewVisibility?
  private var savedInspectorPresented: Bool?
  /// Panes are saved once, when the first immersive mode starts, and restored
  /// once, when the last one ends.
  private var panesSaved = false
  private(set) var isFocusMode = false

  /// The surface host this window owns. The player window's "Open in Library"
  /// command presents into it.
  var inlineHost: InlinePlayerSurfaceHost { chrome.inlineHost }

  var isWindowFullScreen: Bool {
    window?.styleMask.contains(.fullScreen) ?? false
  }

  init(playerCore: PlayerCore, chrome: LibraryChrome = LibraryChrome()) {
    self.player = playerCore
    self.chrome = chrome
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
    let window = makeWindow()
    window.contentView = NSHostingView(rootView: LibraryRootView(player: player, chrome: chrome))
    installToolbar(in: window)
    installTitlebarAccessories(in: window)
    window.delegate = self
    installMenuHandler(in: window)

    self.window = window
    self.loaded = true
    installInputMonitors(in: window)
    wireChromeActions(window: window)
  }

  private func makeWindow() -> CommonWindow {
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
    return window
  }

  private func installToolbar(in window: NSWindow) {
    // An empty unified toolbar gives the window the current titlebar metrics:
    // the traffic lights and the accessory share one centered row.
    let toolbar = NSToolbar(identifier: "UniPlayerLibraryChrome")
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
    toolbar.showsBaselineSeparator = false
    window.toolbar = toolbar
  }

  private func installTitlebarAccessories(in window: NSWindow) {
    let controls = LibraryTitlebarHost(chrome: chrome)
    controls.frame = NSRect(origin: .zero,
                            size: NSSize(width: Tokens.Size.sidebarWidth, height: Tokens.Size.n52))
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = controls
    accessory.layoutAttribute = .left
    window.addTitlebarAccessoryViewController(accessory)
    titlebarAccessory = accessory

    let inspectorControls = LibraryInspectorTitlebarHost(chrome: chrome)
    inspectorControls.frame = NSRect(
      origin: .zero,
      size: NSSize(width: Tokens.Size.n52, height: Tokens.Size.n52))
    let inspectorAccessory = NSTitlebarAccessoryViewController()
    inspectorAccessory.view = inspectorControls
    inspectorAccessory.layoutAttribute = .right
    window.addTitlebarAccessoryViewController(inspectorAccessory)
    self.inspectorAccessory = inspectorAccessory
  }

  private func installMenuHandler(in window: NSWindow) {
    // Playback menu items are dispatched through the key window's responder
    // chain. The library needs its own handler so that, while inline, the
    // same menu items act on the one player.
    let handler = MainMenuActionHandler(playerCore: player)
    handler.nextResponder = window.nextResponder
    window.nextResponder = handler
    menuActionHandler = handler
  }

  private func installInputMonitors(in window: NSWindow) {
    commandDragMonitor = window.installCommandDragMonitor()
    sidebarShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.window === self.window else { return event }
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard let character = event.charactersIgnoringModifiers?.lowercased() else {
        return event
      }
      if modifiers == [.command, .control], character == "s" {
        self.chrome.toggleSidebar()
        return nil
      }
      if modifiers == [.command, .option], character == "i" {
        self.toggleInspector()
        return nil
      }
      if modifiers == [.command, .shift], character == "f" {
        self.toggleFocusMode()
        return nil
      }
      return event
    }
    inlineKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.window === self.window else { return event }
      return self.handleInlineKeyDown(event)
    }
  }

  private func wireChromeActions(window: NSWindow) {
    chrome.toggleFullscreen = { [weak self] in
      self?.toggleWindowFullScreen()
    }
    chrome.toggleInspector = { [weak self] in
      self?.toggleInspector()
    }
    chrome.openInNewWindow = { [weak self] in
      self?.openInNewWindow()
    }
    chrome.isFullscreen = { [weak window] in
      window?.styleMask.contains(.fullScreen) ?? false
    }
  }

  deinit {
    if let commandDragMonitor {
      NSEvent.removeMonitor(commandDragMonitor)
    }
    if let sidebarShortcutMonitor {
      NSEvent.removeMonitor(sidebarShortcutMonitor)
    }
    if let inlineKeyMonitor {
      NSEvent.removeMonitor(inlineKeyMonitor)
    }
  }

  @IBAction func toggleSidebar(_ sender: Any?) {
    chrome.toggleSidebar()
  }

  // MARK: - Inline keyboard

  /// Forwards playback keys to the inline player while leaving text entry and
  /// Command shortcuts to the library.
  private func handleInlineKeyDown(_ event: NSEvent) -> NSEvent? {
    guard player.isInline else { return event }
    chrome.registerInlineActivity?()

    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.command) {
      return event
    }
    // Editors, web content and focused controls own their keys, Escape
    // included.
    if isEditingText {
      return event
    }
    if event.keyCode == Self.escapeKeyCode {
      if isFocusMode && !(window?.styleMask.contains(.fullScreen) ?? false) {
        toggleFocusMode()
        return nil
      }
      return event
    }

    let keyCode = KeyCodeHelper.mpvKeyCode(from: event)
    let normalized = KeyCodeHelper.normalizeMpv(keyCode)
    guard let binding = PlayerCore.keyBindings[normalized] else { return event }
    return player.handleKeyBinding(binding) ? nil : event
  }

  private var isEditingText: Bool {
    guard let responder = window?.firstResponder else { return false }
    if responder is NSTextView || responder is NSTextField {
      return true
    }
    // A channel page owns its own keyboard handling; forwarding its letters
    // and arrows to mpv would break every field on the page. The same applies
    // to the sidebar list and any focused control: arrows must navigate and
    // Space must activate, not seek and pause.
    var view = responder as? NSView
    while let current = view {
      if current is WKWebView || current is NSTableView
          || current is NSOutlineView || current is NSControl {
        return true
      }
      view = current.superview
    }
    return false
  }

  // MARK: - Inspector

  func toggleInspector() {
    // The inspector is hidden in fullscreen; a titlebar click on the accessory
    // must not bring it back over the video.
    if window?.styleMask.contains(.fullScreen) == true { return }
    chrome.inspectorPresented.toggle()
  }

  @objc func menuToggleInspector(_ sender: Any?) {
    toggleInspector()
  }

  // MARK: - Fullscreen and focus

  @objc func menuToggleFullScreen(_ sender: Any?) {
    toggleWindowFullScreen()
  }

  func toggleWindowFullScreen() {
    guard let window else { return }
    window.toggleFullScreen(nil)
  }

  @objc func menuToggleFocusMode(_ sender: Any?) {
    toggleFocusMode()
  }

  @objc func menuSwitchToMiniPlayer(_ sender: Any?) {
    // The menu item is a toggle; the library does not know which window was
    // key when the mini player took over, so decide from the player state.
    if player.isInMiniPlayer {
      player.switchBackFromMiniPlayer()
    } else {
      player.switchToMiniPlayer()
    }
  }

  func toggleFocusMode() {
    guard let window else { return }
    if isFocusMode {
      exitFocusMode()
      window.makeFirstResponder(chrome.inlineHost)
    } else {
      enterFocusMode()
      window.makeFirstResponder(chrome.inlineHost)
    }
  }

  private func enterFocusMode() {
    guard !isFocusMode else { return }
    isFocusMode = true
    savePanes()
    chrome.columnVisibility = .detailOnly
    chrome.inspectorPresented = false
    updateImmersiveState()
  }

  private func exitFocusMode() {
    guard isFocusMode else { return }
    isFocusMode = false
    // Fullscreen may still be immersive; only restore when it is not.
    if !(window?.styleMask.contains(.fullScreen) ?? false) {
      restorePanes()
    }
    updateImmersiveState()
  }

  private func updateImmersiveState() {
    chrome.isImmersive = isFocusMode || (window?.styleMask.contains(.fullScreen) ?? false)
  }

  private func savePanes() {
    guard !panesSaved else { return }
    savedColumnVisibility = chrome.columnVisibility
    savedInspectorPresented = chrome.inspectorPresented
    panesSaved = true
  }

  private func restorePanes() {
    guard panesSaved else { return }
    if let savedColumnVisibility {
      chrome.columnVisibility = savedColumnVisibility
    }
    if let savedInspectorPresented {
      chrome.inspectorPresented = savedInspectorPresented
    }
    savedColumnVisibility = nil
    savedInspectorPresented = nil
    panesSaved = false
  }

  // MARK: - Inline window actions

  func openInNewWindow() {
    guard player.isInline else { return }
    player.endInlinePresentation(showWindow: true)
  }

  // MARK: - NSWindowDelegate

  func windowWillEnterFullScreen(_ notification: Notification) {
    savePanes()
    chrome.columnVisibility = .detailOnly
    chrome.inspectorPresented = false
    chrome.isImmersive = true
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    updateImmersiveState()
    // Focus mode may still hold the panes.
    if !isFocusMode {
      restorePanes()
    }
  }

  func windowDidChangeScreen(_ notification: Notification) {
    guard player.isInline else { return }
    // The surface now renders on the library window's display.
    player.mainWindow.videoView.updateDisplayLink()
    player.mainWindow.videoView.refreshEdrMode()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    if player != nil {
      PlayerCore.lastActive = player
    }
  }

  func windowWillClose(_ notification: Notification) {
    if player.isInline {
      // Closing the library releases the surface and stops its audio.
      player.stop()
      player.endInlinePresentation(showWindow: false)
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
