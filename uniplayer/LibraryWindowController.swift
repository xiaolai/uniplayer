//
//  LibraryWindowController.swift
//  uniplayer
//
//  The window that shows the library. It owns the standard window chrome and a
//  real toolbar; the content is SwiftUI. LibraryChrome bridges window actions
//  and presentation state while PlayerCore retains playback ownership.
//

import AppKit
import SwiftUI
import WebKit

final class LibraryWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation, NSSearchFieldDelegate {

  /// macOS virtual key code for Escape.
  private static let escapeKeyCode: UInt16 = 53

  weak var player: PlayerCore!
  private(set) var loaded = false
  private var commandDragMonitor: Any?
  private var sidebarShortcutMonitor: Any?
  private var inlineKeyMonitor: Any?
  private var menuActionHandler: MainMenuActionHandler?
  private var videoFullscreenWindow: NSWindow?
  private var savedPresentationOptions: NSApplication.PresentationOptions?
  var isVideoFullscreen: Bool { chrome.videoFullscreenPresented }
  private var adjustingPaneFrame = false
  private var fullscreenPanes: (NavigationSplitViewVisibility, Bool, Bool, Bool)?
  private let chrome: LibraryChrome
  private let toolbarIdentifier: NSToolbar.Identifier
  private let savesToolbarConfiguration: Bool
  private var temporarySearchItem = false
  private var searchToolbarAutosavesConfiguration = false
  private static let sidebarItem = NSToolbarItem.Identifier("library.sidebar")
  private static let sidebarBoundary = NSToolbarItem.Identifier("library.sidebarBoundary")
  /// AppKit renders one native platter per run of adjacent items; its fixed
  /// space is the supported way to start the next button group.
  private static let groupSeparator = NSToolbarItem.Identifier.space
  private lazy var sidebarSpacer = LibraryTitlebarSpacer()
  private(set) lazy var searchToolbarItem: NSSearchToolbarItem = {
    let item = NSSearchToolbarItem(itemIdentifier: .init("library.search"))
    item.label = NSLocalizedString("Search Library", comment: "Library toolbar")
    item.paletteLabel = item.label
    item.toolTip = item.label
    item.preferredWidthForSearchField = Tokens.Size.searchFieldWidth
    item.resignsFirstResponderWithCancel = false
    let field = LibraryToolbarSearchField()
    field.placeholderString = NSLocalizedString("Search titles and folders", comment: "Library search")
    field.setAccessibilityLabel(item.label)
    field.setAccessibilityIdentifier("library.titlebarSearch")
    field.sendsSearchStringImmediately = true
    field.delegate = self
    field.onFocus = { [weak self] in
      guard let self, !self.chrome.searchPresented else { return }
      self.chrome.searchLibrary?()
    }
    // AppKit owns the field's control metrics, font, bezel and focus ring.
    item.searchField = field
    return item
  }()

  private var savedColumnVisibility: NavigationSplitViewVisibility?
  private var savedInspectorPresented: Bool?
  /// Panes are saved once, when the first immersive mode starts, and restored
  /// once, when the last one ends.
  private var panesSaved = false
  private(set) var isFocusMode = false

  /// The surface host this window owns. The player window's "Open in Library"
  /// command presents into it.
  var inlineHost: InlinePlayerSurfaceHost { chrome.inlineHost }

  var supportsFocusMode: Bool { player.isInline || chrome.channelSelected }

  var isWindowFullScreen: Bool {
    fullscreenPanes != nil || (window?.styleMask.contains(.fullScreen) ?? false)
  }

  init(playerCore: PlayerCore, chrome: LibraryChrome = LibraryChrome(),
       toolbarIdentifier: NSToolbar.Identifier = "UniPlayerLibraryToolbar",
       savesToolbarConfiguration: Bool = true) {
    self.player = playerCore
    self.chrome = chrome
    self.toolbarIdentifier = toolbarIdentifier
    self.savesToolbarConfiguration = savesToolbarConfiguration
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
    updateSidebarToolbarLayout()
  }

  private func createWindow() {
    let window = makeWindow()
    let hosting = NSHostingView(rootView: LibraryRootView(player: player, chrome: chrome))
    // The window owns its minimum size; expanding inspector content must
    // scroll rather than propagate an unbounded minimum to the window.
    hosting.sizingOptions = []
    window.contentView = hosting
    installToolbar(in: window)
    window.addTitlebarAccessoryViewController(sidebarSpacer)
    updateMinimumSize(window)
    window.delegate = self
    // Assigning the controller sets NSWindow's responder chain. Insert our
    // playback/menu responder afterwards so AppKit doesn't replace it.
    self.window = window
    installMenuHandler(in: window)

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
    window.isMovableByWindowBackground = false
    window.backgroundColor = Tokens.Palette.canvas.nsColor
    window.appearance = NSAppearance(uniplayerTheme: Preference.enum(for: .themeMaterial))
    if !window.setFrameUsingName("UniPlayerLibraryWindow") {
      window.center()
    }
    window.setFrameAutosaveName("UniPlayerLibraryWindow")
    return window
  }

  private func installToolbar(in window: NSWindow) {
    let toolbar = NSToolbar(identifier: toolbarIdentifier)
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = true
    toolbar.autosavesConfiguration = savesToolbarConfiguration
    window.toolbar = toolbar
    if !toolbar.items.contains(where: { $0.itemIdentifier.rawValue == "library.navigation" }) {
      toolbar.insertItem(withItemIdentifier: .init("library.navigation"), at: toolbar.items.count)
    }
    normalizeToolbarStructure(in: toolbar)
  }

  /// Keep the sidebar toggle and its own native group first without resetting
  /// the user's content actions.
  func normalizeToolbarStructure(in toolbar: NSToolbar) {
    let structural: [NSToolbarItem.Identifier] = [Self.sidebarItem, Self.sidebarBoundary]
    // Retired toolbar items: the structural leading space and the Add Source
    // button, which duplicated the File and Sources menu actions.
    var identifiers = toolbar.itemIdentifiers.filter {
      $0.rawValue != "library.sidebarLeadingSpace" && $0.rawValue != "library.add"
        && !structural.contains($0)
    }
    while identifiers.first == Self.groupSeparator { identifiers.removeFirst() }
    identifiers.insert(contentsOf: structural + [Self.groupSeparator], at: 0)
    // Layouts saved before the groups existed run Back, Forward, Open File and
    // Open URL together in one platter.
    if let forward = identifiers.firstIndex(of: .init("library.forward")),
       identifiers.indices.contains(forward + 1),
       identifiers[forward + 1] == .init("library.file") {
      identifiers.insert(Self.groupSeparator, at: forward + 1)
    }
    let autosaves = toolbar.autosavesConfiguration
    toolbar.autosavesConfiguration = false
    toolbar.itemIdentifiers = identifiers
    toolbar.autosavesConfiguration = autosaves
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [Self.sidebarItem, Self.sidebarBoundary, Self.groupSeparator,
     .init("library.back"), .init("library.forward"), Self.groupSeparator,
     .init("library.file"), .init("library.url"),
     .flexibleSpace, .init("library.search"),
     .init("library.navigation"), .init("library.inspector")]
  }

  func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
    [Self.sidebarItem, Self.sidebarBoundary, Self.groupSeparator]
  }

  func toolbar(_ toolbar: NSToolbar, itemIdentifier: NSToolbarItem.Identifier, canBeInsertedAt index: Int) -> Bool {
    index == NSNotFound || index >= toolbarImmovableItemIdentifiers(toolbar).count
  }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
               willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    if id.rawValue == "library.search" { return searchToolbarItem }
    if id == Self.sidebarBoundary {
      // Zero width: the item exists only to mark the sidebar's trailing edge.
      let item = NSToolbarItem(itemIdentifier: id)
      let marker = LibraryToolbarLayoutSpace()
      marker.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([marker.widthAnchor.constraint(equalToConstant: Tokens.Space.n0),
                                   marker.heightAnchor.constraint(equalToConstant: Tokens.Space.n1)])
      item.view = marker
      item.visibilityPriority = .high
      return item
    }
    let definitions: [String: (String, String, Selector)] = [
      "library.back": ("Back", "chevron.left", #selector(navigateBack(_:))),
      "library.forward": ("Forward", "chevron.right", #selector(navigateForward(_:))),
      "library.sidebar": ("Show or Hide Sidebar", "sidebar.left", #selector(toggleSidebar(_:))),
      "library.file": ("Open File…", "folder", #selector(toolbarOpenFile(_:))),
      "library.url": ("Open URL…", "link", #selector(toolbarOpenURL(_:))),
      "library.navigation": ("Channel Navigation", "safari", #selector(toggleChannelNavigation(_:))),
      "library.inspector": ("AI Assistant", "sidebar.right", #selector(menuToggleInspector(_:))),
    ]
    guard let (label, symbol, action) = definitions[id.rawValue] else { return nil }
    let item = NSToolbarItem(itemIdentifier: id)
    item.label = NSLocalizedString(label, comment: "Library toolbar")
    item.paletteLabel = item.label
    item.toolTip = item.label
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
    item.target = self
    item.action = action
    return item
  }

  /// Measure the actual native toolbar layout rather than assuming button sizes
  /// or traffic-light insets. The zero-width boundary marks the sidebar's
  /// trailing edge; the transparent titlebar strip moves the toggle group there
  /// without stretching the toggle's own platter.
  private func updateSidebarToolbarLayout() {
    guard let toolbar = window?.toolbar,
          let boundary = toolbar.items.first(where: { $0.itemIdentifier == Self.sidebarBoundary }),
          let marker = boundary.view else { return }
    if chrome.columnVisibility == .detailOnly {
      sidebarSpacer.width = Tokens.Space.n0
      return
    }
    guard marker.window != nil, boundary.isVisible else { return }
    let correction = chrome.sidebarWidth - marker.convert(marker.bounds, to: nil).minX
    guard abs(correction) > Tokens.Size.n0_5 else { return }
    sidebarSpacer.width += correction
  }

  @objc private func navigateBack(_ sender: Any?) { chrome.navigateBack?() }
  @objc private func navigateForward(_ sender: Any?) { chrome.navigateForward?() }

  private func updatePlaybackToolbar() {
    window?.toolbar?.validateVisibleItems()
  }

  @objc private func toggleChannelNavigation(_ sender: Any?) {
    guard chrome.channelSelected else { return }
    chrome.channelNavigationPresented.toggle()
  }

  func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
    switch item.itemIdentifier.rawValue {
    case "library.back": return chrome.canNavigateBack || chrome.playbackPresented
    case "library.forward": return chrome.canNavigateForward
    case "library.navigation": return chrome.channelSelected
    default: return true
    }
  }

  @objc private func toolbarOpenFile(_ sender: Any?) { chrome.openFile?() }
  @objc private func toolbarOpenURL(_ sender: Any?) { chrome.openURL?() }
  @objc func menuSearchLibrary(_ sender: Any?) {
    chrome.searchLibrary?()
    searchToolbarItem.beginSearchInteraction()
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField,
          field === searchToolbarItem.searchField else { return }
    if !chrome.searchPresented { chrome.searchLibrary?() }
    chrome.searchTextChanged?(field.stringValue)
  }

  private func updateSearchText() {
    let text = chrome.searchText?() ?? ""
    if searchToolbarItem.searchField.stringValue != text {
      searchToolbarItem.searchField.stringValue = text
    }
  }

  private func updateSearchPresentation() {
    if chrome.searchPresented {
      if let toolbar = window?.toolbar,
         !toolbar.items.contains(where: { $0.itemIdentifier == searchToolbarItem.itemIdentifier }) {
        temporarySearchItem = true
        searchToolbarAutosavesConfiguration = toolbar.autosavesConfiguration
        toolbar.autosavesConfiguration = false
        toolbar.insertItem(withItemIdentifier: searchToolbarItem.itemIdentifier, at: toolbar.items.count)
      }
      updateSearchText()
      searchToolbarItem.beginSearchInteraction()
    } else {
      searchToolbarItem.endSearchInteraction()
      if temporarySearchItem, let toolbar = window?.toolbar {
        if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == searchToolbarItem.itemIdentifier }) {
          toolbar.removeItem(at: index)
        }
        toolbar.autosavesConfiguration = searchToolbarAutosavesConfiguration
      }
      temporarySearchItem = false
    }
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
        self.toggleSidebar(nil)
        return nil
      }
      if modifiers == [.command, .option], character == "i" {
        self.toggleInspector()
        return nil
      }
      if modifiers == [.command, .shift], character == "f", self.supportsFocusMode {
        self.toggleFocusMode()
        return nil
      }
      if modifiers == [.command], character == "[" {
        self.chrome.navigateBack?()
        return nil
      }
      if modifiers == [.command], character == "]" {
        self.chrome.navigateForward?()
        return nil
      }
      if !self.isTextEditor(in: event.window), modifiers == [.command] {
        switch event.keyCode {
        case 126:
          NotificationCenter.default.post(name: .mediaSourcesGoUpRequested,
                                          object: self.window)
          return nil
        case 125:
          NotificationCenter.default.post(name: .mediaSourcesOpenSelectionRequested,
                                          object: self.window)
          return nil
        default:
          break
        }
      }
      return event
    }
    inlineKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.window === self.window || event.window === self.videoFullscreenWindow else { return event }
      if event.window === self.videoFullscreenWindow {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == Self.escapeKeyCode
            || (modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "w") {
          self.exitVideoFullscreen()
          return nil
        }
      }
      return self.handleInlineKeyDown(event)
    }
  }

  private func wireChromeActions(window: NSWindow) {
    chrome.sidebarLayoutChanged = { [weak self] in
      DispatchQueue.main.async { self?.updateSidebarToolbarLayout() }
    }
    chrome.playbackChromeChanged = { [weak self] in self?.updatePlaybackToolbar() }
    chrome.searchPresentationChanged = { [weak self] in self?.updateSearchPresentation() }
    chrome.searchQueryChanged = { [weak self] in self?.updateSearchText() }
    chrome.pinPane = { [weak self] left in self?.pinPane(left: left) }
    chrome.resizePane = { [weak self] left, width in self?.resizePane(left: left, width: width) }
    chrome.toggleFullscreen = { [weak self] in
      self?.toggleVideoFullscreen()
    }
    chrome.exitVideoFullscreen = { [weak self] in self?.exitVideoFullscreen() }
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
    setPane(left: true, visible: chrome.columnVisibility == .detailOnly)
  }

  private func updateMinimumSize(_ window: NSWindow) {
    let left = chrome.columnVisibility != .detailOnly && chrome.leftDocked ? chrome.sidebarWidth : 0
    let right = chrome.inspectorPresented && chrome.rightDocked ? chrome.inspectorWidth : 0
    let screenWidth = window.screen?.visibleFrame.width ?? window.frame.width
    let fullscreen = isWindowFullScreen
    chrome.canDockLeft = !fullscreen && window.frame.width + chrome.sidebarWidth <= screenWidth
    chrome.canDockRight = !fullscreen && window.frame.width + chrome.inspectorWidth <= screenWidth
    window.minSize = NSSize(width: LibraryLayout.minimumWidth(left: left, right: right),
                            height: Tokens.Window.minimumSize.height)
  }

  private func setPane(left: Bool, visible: Bool) {
    guard let window else { return }
    let currentlyVisible = left ? chrome.columnVisibility != .detailOnly : chrome.inspectorPresented
    guard visible != currentlyVisible else { return }
    let docked = left ? chrome.leftDocked : chrome.rightDocked
    let width = left ? chrome.sidebarWidth : chrome.inspectorWidth
    let fullscreen = isWindowFullScreen
    let screen = window.screen?.visibleFrame ?? window.frame
    let delta = visible ? width : (docked ? -width : 0)
    let target = fullscreen ? nil : LibraryLayout.paneFrame(frame: window.frame, screen: screen, delta: delta, left: left)
    let willDock = visible && target != nil
    adjustingPaneFrame = true
    if left { chrome.leftDocked = willDock; chrome.columnVisibility = visible ? .all : .detailOnly }
    else { chrome.rightDocked = willDock; chrome.inspectorPresented = visible }
    updateMinimumSize(window)
    if let target { window.setFrame(target, display: true) }
    updateMinimumSize(window)
    adjustingPaneFrame = false
  }

  private func pinPane(left: Bool) {
    guard let window, !window.styleMask.contains(.fullScreen),
          !(left ? chrome.leftDocked : chrome.rightDocked) else { return }
    let width = left ? chrome.sidebarWidth : chrome.inspectorWidth
    guard let frame = LibraryLayout.paneFrame(frame: window.frame,
      screen: window.screen?.visibleFrame ?? window.frame, delta: width, left: left) else { return }
    adjustingPaneFrame = true
    if left { chrome.leftDocked = true } else { chrome.rightDocked = true }
    window.setFrame(frame, display: true)
    updateMinimumSize(window)
    adjustingPaneFrame = false
  }

  private func resizePane(left: Bool, width: CGFloat) {
    guard let window else { return }
    let width = LibraryLayout.boundedPaneWidth(width, left: left)
    let old = left ? chrome.sidebarWidth : chrome.inspectorWidth
    let docked = left ? chrome.leftDocked : chrome.rightDocked
    let target = LibraryLayout.paneFrame(frame: window.frame,
      screen: window.screen?.visibleFrame ?? window.frame, delta: width - old, left: left)
    if docked && target == nil { return }
    adjustingPaneFrame = true
    if left { chrome.sidebarWidth = width } else { chrome.inspectorWidth = width }
    UserDefaults.standard.set(width, forKey: left ? "library.outwardSidebarWidth.v1" : "library.outwardInspectorWidth.v1")
    updateMinimumSize(window)
    if docked, let target { window.setFrame(target, display: true) }
    updateMinimumSize(window)
    adjustingPaneFrame = false
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
    if isEditingText(in: event.window) {
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

  private func isTextEditor(in eventWindow: NSWindow?) -> Bool {
    guard let responder = eventWindow?.firstResponder else { return false }
    return responder is NSTextView || responder is NSTextField
  }

  private func isEditingText(in eventWindow: NSWindow?) -> Bool {
    guard let responder = eventWindow?.firstResponder else { return false }
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
    setPane(left: false, visible: !chrome.inspectorPresented)
  }

  @objc func menuToggleInspector(_ sender: Any?) {
    toggleInspector()
  }

  // MARK: - Video-only fullscreen

  /// A separate borderless presentation borrows the existing inline host.
  /// The library's frame, panes and native fullscreen state are untouched.
  func toggleVideoFullscreen() {
    if chrome.videoFullscreenPresented { exitVideoFullscreen(); return }
    guard player.isInline, player.info.state.active,
          let screen = chrome.inlineHost.window?.screen ?? window?.screen else { return }
    chrome.videoFullscreenPresented = true
    DispatchQueue.main.async { [weak self] in
      guard let self, self.chrome.videoFullscreenPresented,
            let content = self.chrome.makeVideoFullscreenContent?() else {
        self?.chrome.videoFullscreenPresented = false
        return
      }
      let videoWindow = VideoFullscreenWindow(contentRect: screen.frame, styleMask: [.borderless, .closable],
        backing: .buffered, defer: false)
      videoWindow.title = NSLocalizedString("Video Fullscreen", comment: "Video-only window")
      videoWindow.backgroundColor = Tokens.Palette.black.nsColor
      videoWindow.appearance = self.window?.appearance
      videoWindow.isReleasedWhenClosed = false
      videoWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      videoWindow.onExit = { [weak self] in self?.exitVideoFullscreen() }
      let hosting = NSHostingView(rootView: content)
      hosting.sizingOptions = []
      videoWindow.contentView = hosting
      self.videoFullscreenWindow = videoWindow
      self.installMenuHandler(in: videoWindow)
      self.savedPresentationOptions = NSApp.presentationOptions
      NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
      videoWindow.makeKeyAndOrderFront(nil)
      videoWindow.makeFirstResponder(self.chrome.inlineHost)
      self.chrome.registerInlineActivity?()
      self.player.mainWindow.videoView.updateDisplayLink()
      self.player.mainWindow.videoView.refreshEdrMode()
    }
  }

  func exitVideoFullscreen() {
    guard chrome.videoFullscreenPresented || videoFullscreenWindow != nil else { return }
    videoFullscreenWindow?.orderOut(nil)
    videoFullscreenWindow?.contentView = nil
    videoFullscreenWindow = nil
    if let savedPresentationOptions { NSApp.presentationOptions = savedPresentationOptions }
    savedPresentationOptions = nil
    chrome.videoFullscreenPresented = false
    window?.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.window?.makeFirstResponder(self.chrome.inlineHost)
      self.player.mainWindow.videoView.updateDisplayLink()
      self.player.mainWindow.videoView.refreshEdrMode()
    }
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
    setPane(left: false, visible: false)
    setPane(left: true, visible: false)
    updateImmersiveState()
  }

  private func exitFocusMode() {
    guard isFocusMode else { return }
    isFocusMode = false
    // Fullscreen may still be immersive; only restore when it is not.
    if !isWindowFullScreen {
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
      setPane(left: true, visible: savedColumnVisibility != .detailOnly)
    }
    if let savedInspectorPresented {
      setPane(left: false, visible: savedInspectorPresented)
    }
    savedColumnVisibility = nil
    savedInspectorPresented = nil
    panesSaved = false
  }

  // MARK: - Inline window actions

  func openInNewWindow() {
    exitVideoFullscreen()
    guard player.isInline else { return }
    player.endInlinePresentation(showWindow: true)
  }

  // MARK: - NSWindowDelegate

  func windowDidUpdate(_ notification: Notification) {
    updateSidebarToolbarLayout()
  }

  func windowWillEnterFullScreen(_ notification: Notification) {
    fullscreenPanes = (chrome.columnVisibility, chrome.inspectorPresented, chrome.leftDocked, chrome.rightDocked)
    // Fullscreen cannot expand outwards: visible panes float above the content.
    chrome.leftDocked = false
    chrome.rightDocked = false
    chrome.isImmersive = true
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    updateImmersiveState()
    if let saved = fullscreenPanes {
      chrome.columnVisibility = saved.0
      chrome.inspectorPresented = saved.1
      chrome.leftDocked = saved.2
      chrome.rightDocked = saved.3
    }
    fullscreenPanes = nil
    // The fullscreen snapshot predates any Focus toggles made in that Space.
    // Reconcile the current intent after AppKit restores the ordinary frame.
    if isFocusMode {
      setPane(left: false, visible: false)
      setPane(left: true, visible: false)
    } else {
      restorePanes()
    }
    if let window { updateMinimumSize(window) }
  }

  func windowDidResize(_ notification: Notification) {
    guard !adjustingPaneFrame, let window else { return }
    updateMinimumSize(window)
    // Accessibility/programmatic resizing can bypass NSWindow.minSize, which
    // otherwise constrains ordinary edge dragging. Enforce the same floor.
    var frame = window.frame
    let top = frame.maxY
    frame.size.width = max(frame.width, window.minSize.width)
    frame.size.height = max(frame.height, window.minSize.height)
    frame.origin.y = top - frame.height
    guard frame != window.frame else { return }
    adjustingPaneFrame = true
    window.setFrame(frame, display: true)
    adjustingPaneFrame = false
  }

  func windowDidChangeScreen(_ notification: Notification) {
    if let window { updateMinimumSize(window) }
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
    exitVideoFullscreen()
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

/// Structural space must leave ordinary titlebar dragging to AppKit.
private final class LibraryToolbarLayoutSpace: NSView {
  override var mouseDownCanMoveWindow: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A transparent leading titlebar strip that offsets the toolbar so the sidebar
/// toggle sits above the sidebar's trailing edge. It is deliberately outside the
/// toolbar: a toolbar spacer would join, and visually stretch, the toggle's
/// native button group.
private final class LibraryTitlebarSpacer: NSTitlebarAccessoryViewController {
  private let strip = LibraryToolbarLayoutSpace(frame: .zero)

  var width: CGFloat {
    get { strip.frame.width }
    set { strip.setFrameSize(NSSize(width: max(Tokens.Space.n0, newValue), height: strip.frame.height)) }
  }

  init() {
    super.init(nibName: nil, bundle: nil)
    layoutAttribute = .left
    view = strip
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

private final class LibraryToolbarSearchField: NSSearchField {
  var onFocus: (() -> Void)?
  override func becomeFirstResponder() -> Bool {
    let focused = super.becomeFirstResponder()
    if focused { onFocus?() }
    return focused
  }
}

/// The playback fullscreen surface has no library chrome or draggable titlebar.
private final class VideoFullscreenWindow: NSWindow {
  var onExit: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
  override func performClose(_ sender: Any?) { onExit?() }
}
