//
//  LibraryView.swift
//  uniplayer
//
//  The library shell: a real sidebar, a Home with a hero and shelves, a grid,
//  search and the playlist empty state. Everything here reads LibraryModel and
//  opens files through it; nothing reaches into mpv.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct LibraryTextScaleKey: EnvironmentKey { static let defaultValue = 1.0 }
extension EnvironmentValues {
  var libraryTextScale: Double {
    get { self[LibraryTextScaleKey.self] }
    set { self[LibraryTextScaleKey.self] = newValue }
  }
}

private func L(_ key: String) -> String {
  NSLocalizedString(key, comment: "")
}

private func LF(_ key: String, _ arguments: CVarArg...) -> String {
  String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}

enum LibrarySidebarItem: Hashable {
  case section(LibrarySection)
  case channel(String)
  case source(UUID)
  case collection(UUID)
}

enum LibrarySection: String, CaseIterable, Identifiable {
  case home
  case search
  case continueWatching
  case recent
  case all
  case favorites

  var id: String { rawValue }

  var title: String {
    switch self {
    case .home: return L("Home")
    case .search: return L("Search")
    case .continueWatching: return L("Continue Watching")
    case .recent: return L("Recently Played")
    case .all: return L("All Videos")
    case .favorites: return L("Favorites")
    }
  }

  var symbol: String {
    switch self {
    case .home: return "house"
    case .search: return "magnifyingglass"
    case .continueWatching: return "play.circle"
    case .recent: return "clock"
    case .all: return "rectangle.stack"
    case .favorites: return "star"
    }
  }
}

// MARK: - Chrome

/// The library window's column state and the actions its toolbar invokes.
final class LibraryChrome: ObservableObject {
  @Published var columnVisibility: NavigationSplitViewVisibility = .all
  @Published var inspectorPresented = false
  @Published var leftDocked = true
  @Published var rightDocked = true
  @Published var canDockLeft = false
  @Published var canDockRight = false
  var pinPane: ((Bool) -> Void)?
  @Published var sidebarWidth = LibraryLayout.boundedPaneWidth(
    UserDefaults.standard.object(forKey: "library.outwardSidebarWidth.v1") as? Double ?? Tokens.Library.outwardSidebarWidth, left: true)
  @Published var inspectorWidth = LibraryLayout.boundedPaneWidth(
    UserDefaults.standard.object(forKey: "library.outwardInspectorWidth.v1") as? Double ?? Tokens.Inspector.idealWidth, left: false)
  @Published var playbackPresented = false {
    didSet { if playbackPresented != oldValue { playbackChromeChanged?() } }
  }
  var playbackChromeChanged: (() -> Void)?
  var backFromPlayback: (() -> Void)?
  @Published var canNavigateBack = false
  @Published var canNavigateForward = false
  var navigateBack: (() -> Void)?
  var navigateForward: (() -> Void)?
  var addSource: (() -> Void)?
  @Published var channelSelected = false
  @Published var channelNavigationPresented = false
  var resizePane: ((Bool, CGFloat) -> Void)?

  /// True while the library window is in macOS fullscreen or Focus mode.
  @Published var isImmersive = false
  @Published var videoFullscreenPresented = false
  var makeVideoFullscreenContent: (() -> AnyView?)?
  var exitVideoFullscreen: (() -> Void)?
  /// The one inline surface host for this window, created with the window and
  /// kept for its whole lifetime.
  let inlineHost = InlinePlayerSurfaceHost()
  var openFile: (() -> Void)?
  var openURL: (() -> Void)?
  var searchLibrary: (() -> Void)?
  var toggleFullscreen: (() -> Void)?
  var openInNewWindow: (() -> Void)?
  var toggleInspector: (() -> Void)?
  /// Wakes the inline controls on a key press.
  var registerInlineActivity: (() -> Void)?
  /// Reports the library window's fullscreen state.
  var isFullscreen: (() -> Bool)?

  func toggleSidebar() {
    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
  }
}

// MARK: - Root

struct LibraryRootView: View {
  @Environment(\.libraryTextScale) private var textScale
  private let open: (URL) -> Void
  private let openMany: ([URL]) -> Void
  /// Unowned: the window that hosts this view is owned by `PlayerCore`.
  private unowned let player: PlayerCore

  @StateObject private var model: LibraryModel
  @StateObject private var inlinePlayer: InlinePlayerModel
  @StateObject private var assistant: AssistantViewModel
  @ObservedObject private var chrome: LibraryChrome
  @ObservedObject private var channels = ChannelStore.shared
  @ObservedObject private var mediaSources = MediaSourcesEnvironment.shared
  @StateObject private var browser = ChannelBrowserModel()
  @State private var selection: LibrarySidebarItem? = .section(.home)
  @AppStorage("interface.textScale.v1") private var preferredTextScale = 1.0
  @State private var searchID = UUID()
  @State private var selectedItem: LibraryItem?
  @State private var catalogDetailID: UUID?
  @State private var sourcePropertiesID: UUID?
  @State private var retainedBrowser: SourceBrowserModel?
  /// The catalog the retained browser was built against. A startup retry
  /// replaces the catalog; reusing the model would keep the closed one.
  @State private var retainedBrowserCatalog: MediaCatalog?
  @State private var playbackRequestID = UUID()
  @State private var sourceError: String?
  @State private var playbackLease: SourceAccessLease?
  @State private var dropTargeted = false
  @State private var channelEditor: ChannelEditorSheet.Mode?
  @State private var channelPendingDeletion: Channel?

  init(player: PlayerCore, chrome: LibraryChrome) {
    // Weak on purpose: PlayerCore owns the window that owns this view.
    let host = chrome.inlineHost
    let open: (URL) -> Void = { [weak player] url in
      DispatchQueue.main.async {
        guard let player else { return }
        player.presentInline(in: host)
        player.openURL(url)
      }
    }
    let openMany: ([URL]) -> Void = { [weak player] urls in
      guard !urls.isEmpty else { return }
      DispatchQueue.main.async {
        guard let player else { return }
        player.presentInline(in: host)
        _ = player.openURLs(urls)
      }
    }
    self.open = open
    self.openMany = openMany
    self.player = player
    self.chrome = chrome
    let model = LibraryModel(open: open)
    _model = StateObject(wrappedValue: model)
    _inlinePlayer = StateObject(wrappedValue: InlinePlayerModel(player: player))
    _assistant = StateObject(wrappedValue: AssistantViewModel(
      toolExecutor: PlayerAssistantToolExecutor(player: player)))
    chrome.openFile = { [weak model] in
      model?.openFilePanel()
    }
    chrome.openURL = {
      AppDelegate.shared.openURL(NSApp)
    }
  }

  var body: some View {
    HStack(spacing: Tokens.Space.n0) {
      if chrome.columnVisibility != .detailOnly && chrome.leftDocked {
        sidebarPane
      }
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.canvas.color)
      if chrome.inspectorPresented && chrome.rightDocked {
        inspectorPane
      }
    }
    .overlay(alignment: .leading) {
      if chrome.columnVisibility != .detailOnly && !chrome.leftDocked { sidebarPane }
    }
    .overlay(alignment: .trailing) {
      if chrome.inspectorPresented && !chrome.rightDocked { inspectorPane }
    }
    .overlay(alignment: .top) {
      WindowDragRegion().frame(height: Tokens.Library.titlebarHeight)
    }
    .ignoresSafeArea(.container, edges: .top)
    .environmentObject(model)
    .environment(\.libraryTextScale, preferredTextScale)
    .tint(Tokens.Palette.accent.color)
    .background(Tokens.Palette.canvas.color)
    .overlay {
      if dropTargeted {
        DropOverlay()
      }
    }
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
      handleDrop(providers)
    }
    .onAppear { viewDidAppear() }
    .onReceive(NotificationCenter.default.publisher(for: .mediaSourcesAddRequested)) { _ in
      handleAddRequest()
    }
    .onReceive(NotificationCenter.default.publisher(for: .mediaSourcesShowRequested)) { _ in
      handleShowSources()
    }
    .onReceive(NotificationCenter.default.publisher(for: .mediaSourcesEnabledDidChange)) { _ in
      handleSourcesEnabledChange()
    }
    .alert(L("Source Error"), isPresented: Binding(
      get: { sourceError != nil },
      set: { if !$0 { sourceError = nil } })) {
      Button(L("OK")) { sourceError = nil }
    } message: {
      Text(sourceError ?? "")
    }
    .alert(L("Media Library Error"), isPresented: Binding(
      get: { mediaSources.startupError != nil },
      set: { if !$0 { mediaSources.dismissStartupError() } })) {
      Button(L("Try Again")) { mediaSources.retryStartup() }
      Button(L("Show Library Folder")) { showMediaLibraryFolder() }
      Button(L("Close"), role: .cancel) { mediaSources.dismissStartupError() }
    } message: {
      Text(mediaSources.startupError ?? "")
    }
    .onChange(of: chrome.videoFullscreenPresented) { _, _ in handleVideoFullscreenChange() }
    .onChange(of: selectedItem?.url) { _, _ in updatePlaybackChrome() }
    .onChange(of: selectedItem?.id) { _, _ in updateNavigationChrome() }
    .onChange(of: catalogDetailID) { _, _ in updateNavigationChrome() }
    .onChange(of: sourcePropertiesID) { _, _ in updateNavigationChrome() }
    .onChange(of: selection) { _, value in
      if case .channel = value { chrome.channelSelected = true }
      else { chrome.channelSelected = false; chrome.channelNavigationPresented = false }
      handleSelectionChange()
    }
    .onChange(of: inlinePlayer.isActive) { _, active in
      handleInlineActiveChange(active)
      if !active { chrome.exitVideoFullscreen?() }
    }
    .onChange(of: inlinePlayer.currentURL) { _, url in
      handleInlineURLChange(url)
    }
    .sheet(item: $channelEditor) { mode in
      ChannelEditorSheet(store: channels, mode: mode) { channel in
        selection = .channel(channel.id)
      }
    }
    .alert(L("Delete Channel?"), isPresented: isDeletingChannel) {
      Button(L("Delete"), role: .destructive) {
        if let channel = channelPendingDeletion {
          deleteChannel(channel)
        }
      }
      Button(L("Cancel"), role: .cancel) {}
    } message: {
      Text(channelPendingDeletion?.name ?? "")
    }
  }


  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    let lock = NSLock()
    var urls = Array<URL?>(repeating: nil, count: providers.count)
    let group = DispatchGroup()
    for (index, provider) in providers.enumerated() {
      group.enter()
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        if let url, url.isFileURL {
          lock.lock()
          urls[index] = url
          lock.unlock()
        }
        group.leave()
      }
    }
    group.notify(queue: .main) {
      lock.lock()
      let resolved = urls.compactMap { $0 }
      lock.unlock()
      if resolved.count == 1 {
        open(resolved[0])
      } else {
        openMany(resolved)
      }
    }
    return true
  }

  private func viewDidAppear() {
    mediaSources.startIfEnabled()
    if mediaSources.consumeAddRequest() { presentAddSource() }
    model.reload()
    configureCallbacks()
    inlinePlayer.refresh()
    handleInlineActiveChange(inlinePlayer.isActive)
  }

  private func handleAddRequest() {
    if mediaSources.consumeAddRequest() { presentAddSource() }
  }

  private func handleShowSources() {
    if let root = mediaSources.coordinator?.roots.first {
      selection = .source(root.id)
    } else {
      presentAddSource()
    }
  }

  private func handleSourcesEnabledChange() {
    if MediaSourcesFeature.isEnabled {
      mediaSources.startIfEnabled()
    } else {
      mediaSources.stop()
      // The retained browser holds the closed catalog and its old coordinator;
      // reusing it after a re-enable would skip the fresh initial load.
      retainedBrowser = nil
      retainedBrowserCatalog = nil
      if case .source = selection ?? .section(.home) {
        selection = .section(.home)
      } else if case .collection = selection ?? .section(.home) {
        selection = .section(.home)
      }
    }
  }

  private func handleVideoFullscreenChange() {
    inlinePlayer.refresh()
    inlinePlayer.registerActivity()
  }

  private func showMediaLibraryFolder() {
    NSWorkspace.shared.open(Utility.appSupportDirUrl
      .appendingPathComponent("MediaLibrary", isDirectory: true))
  }

  private var sidebarPane: some View {
    VStack(spacing: Tokens.Space.n0) {
      if !chrome.leftDocked { floatingPaneHeader(left: true) }
      sidebar
    }
      .padding(.top, Tokens.Library.titlebarHeight)
      .frame(width: chrome.sidebarWidth)
      .frame(maxHeight: .infinity)
      .background(LibrarySidebarMaterial())
      .overlay(alignment: .trailing) {
        PaneResizeHandle(width: chrome.sidebarWidth) { chrome.resizePane?(true, $0) }
      }
  }

  private var inspectorPane: some View {
    VStack(spacing: Tokens.Space.n0) {
      if !chrome.rightDocked { floatingPaneHeader(left: false) }
      AIInspectorView(model: assistant)
    }
      .padding(.top, Tokens.Library.titlebarHeight)
      .frame(width: chrome.inspectorWidth)
      .frame(maxHeight: .infinity)
      .background(Tokens.Palette.canvas.color)
      .overlay(alignment: .leading) {
        PaneResizeHandle(width: chrome.inspectorWidth, direction: -1) { chrome.resizePane?(false, $0) }
      }
  }

  private func floatingPaneHeader(left: Bool) -> some View {
    HStack {
      Text(L(left ? "Floating Sidebar" : "Floating Inspector"))
        .font(Tokens.Typography.caption.font)
      Spacer()
      Button { chrome.pinPane?(left) } label: {
        Label(L(left ? "Pin Sidebar" : "Pin Inspector"), systemImage: "pin")
      }
      .disabled(left ? !chrome.canDockLeft : !chrome.canDockRight)
      .help(L("Pin when there is enough screen space"))
    }
    .padding(Tokens.Space.n8)
  }

  private func updatePlaybackChrome() {
    chrome.playbackPresented = inlinePlayer.isActive
      && (selectedItem?.url == inlinePlayer.currentURL || catalogDetailID != nil)
  }

  private func updateNavigationChrome() {
    chrome.canNavigateBack = catalogDetailID != nil || sourcePropertiesID != nil
      || selectedItem != nil
    chrome.canNavigateForward = false
    // Restore the detail-route back behavior after a source browser has
    // borrowed the toolbar's navigation slots.
    chrome.navigateBack = {
      if catalogDetailID != nil {
        catalogDetailID = nil
      } else if sourcePropertiesID != nil {
        sourcePropertiesID = nil
      } else if selectedItem != nil {
        selectedItem = nil
      } else {
        chrome.backFromPlayback?()
      }
      updateNavigationChrome()
    }
    chrome.navigateForward = {
      updateNavigationChrome()
    }
  }

  /// Wires the models to the window controller's actions. Called once when
  /// the view appears; all captures are weak or unowned by construction.
  private func configureCallbacks() {
    chrome.makeVideoFullscreenContent = {
      if catalogDetailID != nil, inlinePlayer.isActive {
        return AnyView(
          ZStack {
            Tokens.Palette.black.color
            InlinePlayerView(host: chrome.inlineHost)
            InlinePlayerChrome(model: inlinePlayer)
          }
          .background(Tokens.Palette.black.color))
      }
      guard let selectedItem else { return nil }
      return AnyView(DetailView(
        item: model.allItems.first(where: { $0.id == selectedItem.id }) ?? selectedItem,
        inlinePlayer: inlinePlayer, host: chrome.inlineHost,
        play: { model.open(selectedItem) },
        openInNewWindow: { inlinePlayer.onOpenInNewWindow?() },
        back: {}, immersive: true, pausesOnDisappear: false)
        .environmentObject(model)
        .environment(\.libraryTextScale, preferredTextScale))
    }
    chrome.backFromPlayback = {
      selectedItem = nil
      catalogDetailID = nil
      sourcePropertiesID = nil
    }
    chrome.addSource = {
      guard let coordinator = MediaSourcesEnvironment.shared.coordinator else { return }
      AddSourceSupport.present(coordinator: coordinator, window: NSApp.keyWindow,
                               onCreated: { root in
        selection = .source(root.id)
        catalogDetailID = nil
        sourcePropertiesID = nil
      }, onError: { sourceError = $0 })
    }
    // Navigation closures are owned by updateNavigationChrome().
    updateNavigationChrome()

    inlinePlayer.onToggleFullscreen = { [weak chrome] in
      chrome?.toggleFullscreen?()
    }
    inlinePlayer.onOpenInNewWindow = { [weak chrome] in
      chrome?.openInNewWindow?()
    }
    let detailSelection = $selectedItem
    let sidebarSelection = $selection
    let searchIdentity = $searchID
    chrome.searchLibrary = {
      detailSelection.wrappedValue = nil
      sidebarSelection.wrappedValue = .section(.search)
      searchIdentity.wrappedValue = UUID()
    }
    chrome.registerInlineActivity = { [weak inlinePlayer] in
      inlinePlayer?.registerActivity()
    }
    chrome.inlineHost.onActivity = { [weak inlinePlayer] in
      inlinePlayer?.registerActivity()
    }
    inlinePlayer.fullscreenProvider = { [weak chrome] in
      chrome?.videoFullscreenPresented ?? false
    }
    chrome.inlineHost.onDoubleClick = { [weak inlinePlayer] in
      inlinePlayer?.toggleFullscreen()
    }
    assistant.playerContextProvider = { [weak player] includeFilePath in
      guard let player, player.isInline, player.info.state.active else { return nil }
      let snapshot = PlayerSnapshot.capture(from: player)
      return PlaybackContextBuilder.make(
        snapshot: snapshot,
        options: .init(includeFilePath: includeFilePath))
    }
    assistant.currentMediaID = { [weak player] in
      player?.info.currentURL?.absoluteString
    }
    assistant.onSeek = { [weak player, weak inlinePlayer] seconds in
      // Seek only when a file is loaded; seeking an idle mpv core is fatal.
      guard let player, player.info.state.loaded else { return }
      player.seek(absoluteSecond: seconds)
      inlinePlayer?.refresh()
      inlinePlayer?.registerActivity()
    }
    assistant.onToolPlaybackChanged = { [weak inlinePlayer] in
      inlinePlayer?.refresh()
      inlinePlayer?.registerActivity()
    }
  }

  private func handleSelectionChange() {
    // Navigating away pauses the inline player and keeps its position; the
    // detail keeps it paused until the user explicitly resumes.
    inlinePlayer.pauseForNavigation()
    playbackRequestID = UUID()
    selectedItem = nil
    catalogDetailID = nil
    sourcePropertiesID = nil
    assistant.setChannelContext(nil)
    assistant.refreshContext()
    updateNavigationChrome()
  }

  private func handleInlineActiveChange(_ active: Bool) {
    if !active {
      playbackLease = nil
      // A catalog open may still be resolving. Stopping playback must cancel
      // that intent, or the late completion would restart it.
      playbackRequestID = UUID()
    }
    // Playback started from a drop, the URL panel or the hero: make sure a
    // detail exists, or the surface would render into no visible view.
    if active, let url = inlinePlayer.currentURL {
      if catalogDetailID == nil {
        if selectedItem?.url != url {
          selectedItem = libraryItem(for: url)
        }
      }
      // Playback replaced whatever page was showing, so a channel page's
      // context is no longer what the user is looking at.
      assistant.setChannelContext(nil)
    }
    updatePlaybackChrome()
    assistant.refreshContext()
  }

  private func handleInlineURLChange(_ url: URL?) {
    if inlinePlayer.isActive, let url {
      if let detailID = catalogDetailID {
        reconcileDetailIfNeeded(playing: url, detailID: detailID)
      } else if selectedItem?.url != url {
        selectedItem = libraryItem(for: url)
      }
    }
    updatePlaybackChrome()
    assistant.refreshContext()
  }

  /// A new URL can arrive while a catalog detail is open (drop, URL panel,
  /// playlist advance). The detail and its lease belong to the item opened
  /// here; when the new locator maps to another row, switch to the playing
  /// item's page so the inline surface stays mounted, and release the lease.
  private func reconcileDetailIfNeeded(playing url: URL, detailID: UUID) {
    guard let catalog = mediaSources.catalog else { return }
    Task { @MainActor in
      let kind = url.isFileURL ? "filePath" : "url"
      let value = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
      let owner = try? await catalog.resolveAlias(kind: kind, value: value)
      guard inlinePlayer.currentURL == url, catalogDetailID == detailID else { return }
      if let owner {
        let target = (try? await catalog.resolveRedirect(id: owner)) ?? owner
        let detail = (try? await catalog.resolveRedirect(id: detailID)) ?? detailID
        guard inlinePlayer.currentURL == url, catalogDetailID == detailID else { return }
        if target == detail { return }
      }
      guard inlinePlayer.currentURL == url, catalogDetailID == detailID else { return }
      catalogDetailID = nil
      playbackLease = nil
      selectedItem = libraryItem(for: url)
      updatePlaybackChrome()
    }
  }

  private var isDeletingChannel: Binding<Bool> {
    Binding(
      get: { channelPendingDeletion != nil },
      set: { if !$0 { channelPendingDeletion = nil } })
  }

  private func deleteChannel(_ channel: Channel) {
    if case .channel(let id) = selection, id == channel.id {
      selection = .section(.home)
    }
    channels.remove(id: channel.id)
    channelPendingDeletion = nil
  }

  private var sidebar: some View {
    List(selection: $selection) {
      Section {
        sidebarLabel(LibrarySection.home.title, symbol: LibrarySection.home.symbol)
          .tag(LibrarySidebarItem.section(.home))
        sidebarLabel(LibrarySection.search.title, symbol: LibrarySection.search.symbol)
          .tag(LibrarySidebarItem.section(.search))
      }
      Section {
        sidebarLabel(LibrarySection.continueWatching.title, symbol: LibrarySection.continueWatching.symbol)
          .tag(LibrarySidebarItem.section(.continueWatching))
        sidebarLabel(LibrarySection.recent.title, symbol: LibrarySection.recent.symbol)
          .tag(LibrarySidebarItem.section(.recent))
        sidebarLabel(LibrarySection.all.title, symbol: LibrarySection.all.symbol)
          .tag(LibrarySidebarItem.section(.all))
        if mediaSources.isRunning {
          sidebarLabel(LibrarySection.favorites.title, symbol: LibrarySection.favorites.symbol)
            .tag(LibrarySidebarItem.section(.favorites))
        }
      } header: {
        Text(L("Library")).font(Tokens.Typography.captionStrong.scaledFont(preferredTextScale))
      }
      if let coordinator = mediaSources.coordinator {
        Section {
          ForEach(coordinator.roots) { root in
            sidebarLabel(root.displayName, symbol: root.kind.symbolName)
              .tag(LibrarySidebarItem.source(root.id))
              .contextMenu {
                Button(L("Source Settings…")) { sourcePropertiesID = root.id }
              }
          }
          Button {
            presentAddSource()
          } label: {
            sidebarLabel(L("Add Source…"), symbol: "plus")
          }
          .buttonStyle(.plain)
        } header: {
          Text(L("Sources")).font(Tokens.Typography.captionStrong.scaledFont(preferredTextScale))
        }
        if !coordinator.collections.isEmpty {
          Section {
            ForEach(coordinator.collections) { collection in
              sidebarLabel(collection.name, symbol: "rectangle.stack")
                .tag(LibrarySidebarItem.collection(collection.id))
            }
          } header: {
            Text(L("Collections")).font(Tokens.Typography.captionStrong.scaledFont(preferredTextScale))
          }
        }
      }
      Section {
        ForEach(channels.channels) { channel in
          sidebarLabel(channel.name, symbol: channel.symbol)
            .tag(LibrarySidebarItem.channel(channel.id))
            .contextMenu {
              Button(L("Edit Channel…")) {
                channelEditor = .edit(channel)
              }
              Button(L("Delete Channel"), role: .destructive) {
                channelPendingDeletion = channel
              }
            }
        }
        Button {
          channelEditor = .add
        } label: {
          sidebarLabel(L("Add Channel…"), symbol: "plus")
        }
        .buttonStyle(.plain)
      } header: {
        Text(L("Channels")).font(Tokens.Typography.captionStrong.scaledFont(preferredTextScale))
      }
    }
    .listStyle(.sidebar)
    .environment(\.defaultMinListRowHeight, Tokens.Size.n30 * preferredTextScale)
    .font(Tokens.Typography.body.scaledFont(preferredTextScale))
    .scrollContentBackground(.hidden)

  }

  private func sidebarLabel(_ title: String, symbol: String) -> some View {
    HStack(spacing: Tokens.Space.n8) {
      Image(systemName: symbol)
        .accessibilityHidden(true)
        .font(Tokens.Typography.body.scaledFont(preferredTextScale))
        .frame(width: Tokens.Size.n20 * preferredTextScale)
      Text(title)
        .font(Tokens.Typography.body.scaledFont(preferredTextScale))
        .lineLimit(1)
    }
    .frame(minHeight: Tokens.Size.n30 * preferredTextScale)
    .help(title)
  }

  @ViewBuilder
  private var detail: some View {
    if let mediaID = catalogDetailID,
       let catalog = mediaSources.catalog,
       let coordinator = mediaSources.coordinator {
      CatalogDetailView(
        mediaID: mediaID,
        catalog: catalog,
        coordinator: coordinator,
        inlinePlayer: inlinePlayer,
        host: chrome.inlineHost,
        onPlay: { intent in openCatalogMedia(mediaID, intent: intent) },
        onBack: {
          catalogDetailID = nil
          selectedItem = nil
        },
        onRelink: { presentRelink($0) },
        onShowProperties: {
          catalogDetailID = nil
          sourcePropertiesID = $0
        },
        onShowInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        videoFullscreenPresented: chrome.videoFullscreenPresented)
    } else if let rootID = sourcePropertiesID, let coordinator = mediaSources.coordinator {
      SourcePropertiesView(
        coordinator: coordinator,
        rootID: rootID,
        onBack: {
          if coordinator.root(id: rootID) == nil {
            selection = .section(.home)
          }
          sourcePropertiesID = nil
        },
        onShowInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
    } else if let selectedItem {
      DetailView(
        item: model.allItems.first(where: { $0.id == selectedItem.id }) ?? selectedItem,
        inlinePlayer: inlinePlayer,
        host: chrome.inlineHost,
        play: { model.open(selectedItem) },
        openInNewWindow: {
          inlinePlayer.onOpenInNewWindow?()
        },
        back: { self.selectedItem = nil },
        immersive: chrome.isImmersive,
        coveredByVideoFullscreen: chrome.videoFullscreenPresented)
    } else {
      switch selection ?? .section(.home) {
      case .section(.home):
        HomeView(
          model: model,
          select: { selectedItem = $0 },
          play: { item in
            selectedItem = item
            open(item.url)
          },
          seeAll: { selection = .section($0) })
      case .section(.search):
        if let catalog = mediaSources.catalog {
          CatalogSearchView(catalog: catalog,
                            onOpenMedia: { mediaID, intent in
                              openCatalogMedia(mediaID, intent: intent)
                            })
            .id(searchID)
        } else {
          SearchView(model: model, select: { selectedItem = $0 }).id(searchID)
        }
      case .section(.continueWatching):
        LibraryGridView(
          title: LibrarySection.continueWatching.title,
          items: model.continueWatching,
          model: model,
          select: { selectedItem = $0 },
          emptyMessage: L("Open a video and it will appear here."),
          onBack: { selection = .section(.home) })
      case .section(.recent):
        LibraryGridView(
          title: LibrarySection.recent.title,
          items: model.recentlyAdded,
          model: model,
          select: { selectedItem = $0 },
          emptyMessage: L("Videos you open appear here. Files stay in their original folders."))
      case .section(.all):
        if let catalog = mediaSources.catalog {
          CatalogLibraryView(
            catalog: catalog,
            title: LibrarySection.all.title,
            onOpenMedia: { mediaID, intent in
              openCatalogMedia(mediaID, intent: intent)
            })
        } else {
          LibraryGridView(
            title: LibrarySection.all.title,
            items: model.allItems,
            model: model,
            select: { selectedItem = $0 },
            emptyMessage: L("Videos you open appear here. Files stay in their original folders."))
        }
      case .section(.favorites):
        if let catalog = mediaSources.catalog {
          FavoritesView(catalog: catalog,
                        onOpenMedia: { mediaID, intent in
                          openCatalogMedia(mediaID, intent: intent)
                        })
        } else {
          EmptyStateView(
            symbol: "star",
            title: L("Favorites"),
            message: L("Enable Media Sources to organize favorites."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      case .source(let id):
        if let catalog = mediaSources.catalog, let coordinator = mediaSources.coordinator {
          SourceBrowserView(
            rootID: id, coordinator: coordinator, catalog: catalog,
            chrome: chrome,
            existingModel: retainedBrowser?.rootID == id
              && retainedBrowserCatalog === catalog ? retainedBrowser : nil,
            onOpenMedia: { mediaID, intent in openCatalogMedia(mediaID, intent: intent) },
            onSelectSource: { sourceID in
              selection = .source(sourceID)
              catalogDetailID = nil
              sourcePropertiesID = nil
            },
            onSourceRemoved: {
              retainedBrowser = nil
              retainedBrowserCatalog = nil
              selection = .section(.home)
              catalogDetailID = nil
              sourcePropertiesID = nil
            },
            onShowProperties: {
              catalogDetailID = nil
              sourcePropertiesID = $0
            },
            onRelink: { presentRelink($0) },
            onShowInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            onModelReady: {
              retainedBrowser = $0
              retainedBrowserCatalog = catalog
            })
            .id(id)
        } else {
          EmptyStateView(
            symbol: "externaldrive",
            title: L("Source Unavailable"),
            message: L("Enable Media Sources to browse saved folders."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      case .collection(let id):
        if let catalog = mediaSources.catalog,
           let coordinator = mediaSources.coordinator,
           let collection = coordinator.collections.first(where: { $0.id == id }) {
          CollectionDetailView(
            collection: collection, catalog: catalog, coordinator: coordinator,
            onOpenMedia: { mediaID, intent in openCatalogMedia(mediaID, intent: intent) },
            onBack: { selection = .section(.home) })
        } else {
          EmptyStateView(
            symbol: "rectangle.stack",
            title: L("Collection Not Found"),
            message: L("It may have been removed."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      case .channel(let id):
        if let channel = channels.channel(id: id) {
          ChannelDetailView(chrome: chrome, browser: browser, channel: channel) { context in
            // The button's task can finish after the user navigated away.
            guard case .channel(let currentID) = selection, currentID == channel.id else {
              return
            }
            assistant.setChannelContext(context)
            if !chrome.inspectorPresented {
              chrome.toggleInspector?()
            }
          }
        } else {
          EmptyStateView(
            symbol: "globe",
            title: L("Channel not found"),
            message: L("It may have been removed."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.Palette.canvas.color)
        }
      }
    }
  }

  private func presentAddSource() {
    guard let coordinator = mediaSources.coordinator else { return }
    AddSourceSupport.present(
      coordinator: coordinator,
      window: NSApp.keyWindow,
      onCreated: { root in
        selection = .source(root.id)
        catalogDetailID = nil
        sourcePropertiesID = nil
      },
      onError: { sourceError = $0 })
  }

  private func openCatalogMedia(_ mediaID: UUID, intent: PlaybackIntent) {
    guard let catalog = mediaSources.catalog,
          let coordinator = mediaSources.coordinator else { return }
    let host = chrome.inlineHost
    let request = UUID()
    playbackRequestID = request
    Task { @MainActor [weak player] in
      guard let player else { return }
      do {
        guard let media = try await catalog.media(id: mediaID) else {
          throw MediaSourceError.notFound
        }
        let (url, lease) = try await coordinator.resolvePlaybackURL(mediaID: mediaID)
        guard playbackRequestID == request else { return }
        let plan = MediaPlaybackResolver.plan(
          for: media, url: url, intent: intent,
          resumePreference: Preference.bool(for: .resumeLastPosition))
        playbackLease = lease
        selectedItem = nil
        sourcePropertiesID = nil
        catalogDetailID = mediaID
        player.presentInline(in: host)
        player.open(plan: plan)
      } catch {
        guard playbackRequestID == request else { return }
        sourceError = (error as? MediaSourceError)?.userMessage
          ?? NSLocalizedString("This item could not be opened.", comment: "")
      }
    }
  }

  private func presentRelink(_ mediaID: UUID) {
    guard let coordinator = mediaSources.coordinator,
          let catalog = mediaSources.catalog else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = NSLocalizedString(
      "Choose the file at its new location. Its progress and organization are kept.",
      comment: "Relink")
    panel.prompt = NSLocalizedString("Relink", comment: "Relink")
    let handler: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        do {
          let resolved = try await coordinator.relink(mediaID: mediaID, to: url)
          catalogDetailID = resolved
          await model.reload()
        } catch MediaSourceError.possibleAlias(let existingID) {
          let existingName = (try? await catalog.media(id: existingID))?.name
            ?? NSLocalizedString("another item", comment: "Relink")
          let alert = NSAlert()
          alert.messageText = NSLocalizedString("Merge Items?", comment: "Relink")
          alert.informativeText = String(
            format: NSLocalizedString(
              "This file is already known as “%@”. Merging keeps the older item’s identity and combines progress and organization. This cannot be undone automatically if playback changes afterwards.",
              comment: "Relink"),
            existingName)
          alert.addButton(withTitle: NSLocalizedString("Merge", comment: "Relink"))
          alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Relink"))
          guard alert.runModal() == .alertFirstButtonReturn else { return }
          do {
            let merged = try await coordinator.relink(
              mediaID: mediaID, to: url, confirmMerge: true)
            catalogDetailID = merged
            await model.reload()
          } catch {
            // A confirmed merge can still be refused; do not swallow that.
            sourceError = (error as? MediaSourceError)?.userMessage
              ?? NSLocalizedString("The file could not be relinked.", comment: "")
          }
        } catch {
          sourceError = (error as? MediaSourceError)?.userMessage
            ?? NSLocalizedString("The file could not be relinked.", comment: "")
        }
      }
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: handler)
    } else {
      panel.begin(completionHandler: handler)
    }
  }

  /// A detail item for a URL the library has not indexed yet (a drop, or a URL
  /// opened from the toolbar). The metadata parser works on the file name.
  private func libraryItem(for url: URL) -> LibraryItem {    if let existing = model.allItems.first(where: { $0.url == url }) {
      return existing
    }
    let fileName = url.isFileURL ? url.lastPathComponent : (url.host ?? url.absoluteString)
    return LibraryItem(
      url: url,
      title: (fileName as NSString).deletingPathExtension,
      subtitle: url.isFileURL
        ? url.deletingLastPathComponent().lastPathComponent
        : (url.host ?? ""),
      metadata: .parse(fileName: fileName),
      duration: 0,
      progress: 0,
      added: Date(),
      isNetwork: !url.isFileURL)
  }


}

// MARK: - Home

private struct HomeView: View {
  @Environment(\.libraryTextScale) private var textScale
  @ObservedObject var model: LibraryModel
  let select: (LibraryItem) -> Void
  let play: (LibraryItem) -> Void
  let seeAll: (LibrarySection) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.n24) {
        HStack {
          Text(L("Home")).font(Tokens.Typography.pageTitle.scaledFont(textScale))
          Spacer()
        }
        Text(L("Your playback history, ready to resume."))
          .font(Tokens.Typography.body.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textSecondary.color)
        if !model.hasLoaded {
          LibraryLoadingState()
        }
        if let hero = model.hero {
          HeroView(item: hero) {
            play(hero)
          }
        }

        if !model.continueWatching.isEmpty {
          ContinueWatchingShelf(
            items: model.continueWatching,
            select: select,
            seeAll: { seeAll(.continueWatching) })
        }

        if !model.recentlyAdded.isEmpty {
          RecentlyAddedShelf(
            items: Array(model.recentlyAdded.prefix(12)),
            select: select,
            seeAll: { seeAll(.recent) })
        }

        if model.hasLoaded && model.allItems.isEmpty {
          EmptyStateView(
            symbol: "play.rectangle.on.rectangle",
            title: model.hiddenCount > 0 ? L("No visible videos") : L("No videos yet"),
            message: model.hiddenCount > 0 ? L("Restore hidden videos to show them in your library again.") :
              L("Videos you open appear here. Files stay in their original folders."),
            actionTitle: model.hiddenCount > 0 ? L("Restore Hidden Videos") : L("Open File…")) {
              if model.hiddenCount > 0 { model.restoreHiddenItems() } else { model.openFilePanel() }
            }
          .frame(minHeight: Tokens.Library.emptyStateMinimum)
        }
      }
      .padding(.horizontal, Tokens.Space.pageMargin)
      .padding(.top, Tokens.Space.n28)
      .padding(.bottom, Tokens.Space.pageBottom)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct HeroView: View {
  @Environment(\.libraryTextScale) private var textScale
  let item: LibraryItem
  let play: () -> Void

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Tokens.Palette.clear.color
      .frame(height: Tokens.Library.heroMaximumHeight * textScale)
      .overlay {
        ZStack(alignment: .bottomLeading) {
          PosterImage(url: item.url)

          LinearGradient(
            colors: [Tokens.Palette.clear.color, Tokens.Palette.heroGradientMid.color, Tokens.Palette.heroShade.color],
            startPoint: .top,
            endPoint: .bottom)

          VStack(alignment: .leading, spacing: Tokens.Library.heroSpacing) {
            Text(item.title)
              .font(Tokens.Typography.heroTitle.scaledFont(textScale))
              .lineLimit(2)

            HStack(spacing: Tokens.Space.n8) {
              Text(item.subtitle)
              if item.isResumable {
                Text("·")
                Text(item.progressText)
              } else if item.duration > 0 {
                Text("·")
                Text(item.durationText)
              }
            }
            .font(Tokens.Typography.heroBody.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.onMediaSecondary.color)

            Button(action: play) {
              Label(
                item.isResumable ? L("Resume") : L("Play"),
                systemImage: "play.fill")
                .font(Tokens.Typography.button.scaledFont(textScale))
                .padding(.horizontal, Tokens.Library.heroButtonHorizontal)
                .padding(.vertical, Tokens.Library.heroButtonVertical)
                .background(Tokens.Palette.white.color, in: Capsule())
                .foregroundStyle(Tokens.Palette.black.color)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.top, Tokens.Space.n4)
            .accessibilityLabel(item.isResumable ? L("Resume") : L("Play"))
            .help(item.isResumable ? L("Resume") : L("Play"))
          }
          .foregroundStyle(Tokens.Palette.onMedia.color)
          .padding(Tokens.Library.heroPadding)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous)
        .stroke(
          contrast == .increased ? Tokens.Palette.mediaBorderIncreased.color : Tokens.Palette.mediaBorder.color,
          lineWidth: contrast == .increased ? Tokens.Stroke.strong : Tokens.Stroke.hairline)
    }
    .shadow(color: Tokens.Shadow.hero.color.color, radius: Tokens.Shadow.hero.radius, x: Tokens.Shadow.hero.offset.width, y: Tokens.Shadow.hero.offset.height)
  }
}

private struct ContinueWatchingShelf: View {
  @Environment(\.libraryTextScale) private var textScale
  let items: [LibraryItem]
  let select: (LibraryItem) -> Void
  let seeAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Library.shelfHeaderSpacing) {
      HStack(alignment: .firstTextBaseline) {
        Text(L("Continue Watching"))
          .font(Tokens.Typography.sectionTitle.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textPrimary.color)
        Spacer()
        Button(L("See All"), action: seeAll)
          .frame(minHeight: Tokens.Size.n30)
          .buttonStyle(.plain)
          .font(Tokens.Typography.caption.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textSecondary.color)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: Tokens.Space.n16) {
          ForEach(items) { item in
            ContinueWatchingCard(item: item) {
              select(item)
            }
          }
        }
        .padding(.vertical, Tokens.Space.n2)
      }
    }
  }
}

private struct ContinueWatchingCard: View {
  @Environment(\.libraryTextScale) private var textScale
  let item: LibraryItem
  let play: () -> Void

  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @AppStorage(Preference.Key.disableAnimations.rawValue) private var disableAnimations = false
  @FocusState private var focused: Bool

  private var borderOpacity: Double {
    contrast == .increased ? Tokens.Opacity.n65 : (hovering ? Tokens.Opacity.n34 : Tokens.Opacity.n10)
  }

  var body: some View {
    Button(action: play) {
      ZStack(alignment: .bottomLeading) {
        PosterImage(url: item.url)

        LinearGradient(
          colors: [Tokens.Palette.clear.color, Tokens.Palette.cardShade.color],
          startPoint: .center,
          endPoint: .bottom)

        VStack(alignment: .leading, spacing: Tokens.Space.n6) {
          Text(item.title)
            .font(Tokens.Typography.cardTitle.scaledFont(textScale))
            .lineLimit(2)
          Text(item.progressText)
            .font(Tokens.Typography.caption.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.onMediaTertiary.color)
          ProgressBar(value: item.progress)
        }
        .padding(Tokens.Library.cardPadding)
        .foregroundStyle(Tokens.Palette.onMedia.color)
      }
      .frame(width: Tokens.Size.cardWidth, height: Tokens.Size.cardHeight)
      .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
          .stroke(
            Tokens.Palette.white.color.opacity(borderOpacity),
            lineWidth: contrast == .increased ? Tokens.Stroke.strong : Tokens.Stroke.hairline)
      }
      .overlay {
        RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
          .stroke(Tokens.Palette.accent.color, lineWidth: focused ? Tokens.Stroke.focus : Tokens.Stroke.none)
          .padding(-Tokens.Library.focusRingOutset)
      }
      .shadow(color: hovering ? Tokens.Shadow.cardHover.color.color : Tokens.Palette.clear.color, radius: Tokens.Shadow.cardHover.radius, x: Tokens.Shadow.cardHover.offset.width, y: Tokens.Shadow.cardHover.offset.height)
      .scaleEffect(hovering && !(reduceMotion || disableAnimations) ? Tokens.Library.hoverScale : 1)
      .animation(Tokens.Motion.swiftUI(Tokens.Motion.hover, reduceMotion: reduceMotion || disableAnimations), value: hovering)
    }
    .buttonStyle(.plain)
    .focusable()
    .focused($focused)
    .onHover { hovering = $0 }
    .accessibilityLabel(item.title)
    .help(item.title + "\n" + item.subtitle)
    .contextMenu { LibraryItemActions(item: item) }
    .accessibilityHint(L("Open details"))
  }
}

private struct RecentlyAddedShelf: View {
  @Environment(\.libraryTextScale) private var textScale
  let items: [LibraryItem]
  let select: (LibraryItem) -> Void
  let seeAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.n14) {
      HStack(alignment: .firstTextBaseline) {
        Text(L("Recently Played"))
          .font(Tokens.Typography.sectionTitle.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textPrimary.color)
        Spacer()
        Button(L("See All"), action: seeAll)
          .frame(minHeight: Tokens.Size.n30)
          .buttonStyle(.plain)
          .font(Tokens.Typography.caption.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textSecondary.color)
      }

      LibraryCardGrid(items: items, select: select)
    }
  }
}

// MARK: - Grid

private struct LibraryGridView: View {
  @Environment(\.libraryTextScale) private var textScale
  let title: String
  let items: [LibraryItem]
  @ObservedObject var model: LibraryModel
  let select: (LibraryItem) -> Void
  let emptyMessage: String
  var onBack: (() -> Void)?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.n20) {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.n10) {
          if let onBack {
            Button(action: onBack) {
              Image(systemName: "chevron.left")
                .font(Tokens.Typography.body.scaledFont(textScale))
              .frame(width: Tokens.Size.n30, height: Tokens.Size.n30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.Palette.textSecondary.color)
            .accessibilityLabel(L("Back"))
          }
          Text(title)
            .font(Tokens.Typography.pageTitle.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textPrimary.color)
          Spacer()
          Text("\(items.count)")
            .font(Tokens.Typography.caption.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textSecondary.color)
        }

        if !model.hasLoaded {
          LibraryLoadingState()
        } else if items.isEmpty {
          EmptyStateView(
            symbol: "play.rectangle.on.rectangle",
            title: model.hiddenCount > 0 ? L("No visible videos") : L("No videos yet"),
            message: model.hiddenCount > 0 ? L("Restore hidden videos to show them in your library again.") : emptyMessage,
            actionTitle: model.hiddenCount > 0 ? L("Restore Hidden Videos") : L("Open File…")) {
              if model.hiddenCount > 0 { model.restoreHiddenItems() } else { model.openFilePanel() }
            }
          .frame(minHeight: Tokens.Library.gridEmptyStateMinimum)
        } else {
          LibraryCollectionView(items: items, select: select)
        }
      }
      .padding(.horizontal, Tokens.Space.pageMargin)
      .padding(.top, Tokens.Space.n28)
      .padding(.bottom, Tokens.Space.pageBottom)
    }
  }
}

/// The one adaptive card grid used by shelves, sections and search.
private struct LibraryCardGrid: View {
  @Environment(\.libraryTextScale) private var textScale
  let items: [LibraryItem]
  let select: (LibraryItem) -> Void

  private let columns = [
    GridItem(.adaptive(minimum: Tokens.Size.gridMinimum, maximum: Tokens.Size.gridMaximum),
             spacing: Tokens.Library.cardGap)
  ]

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: Tokens.Library.gridRowGap) {
      ForEach(items) { item in
        LibraryCard(item: item) {
          select(item)
        }
      }
    }
  }
}

private struct LibraryCard: View {
  @Environment(\.libraryTextScale) private var textScale
  let item: LibraryItem
  let play: () -> Void

  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @AppStorage(Preference.Key.disableAnimations.rawValue) private var disableAnimations = false
  @FocusState private var focused: Bool

  private var borderOpacity: Double {
    contrast == .increased ? Tokens.Opacity.n65 : (hovering ? Tokens.Opacity.n28 : Tokens.Opacity.n08)
  }

  var body: some View {
    Button(action: play) {
      VStack(alignment: .leading, spacing: Tokens.Library.cardSpacing) {
        Tokens.Palette.clear.color
          .aspectRatio(Tokens.Aspect.video, contentMode: .fit)
          .overlay {
            PosterImage(url: item.url)
          }
          .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
              .stroke(
                Tokens.Palette.white.color.opacity(borderOpacity),
                lineWidth: contrast == .increased ? Tokens.Stroke.strong : Tokens.Stroke.hairline)
          }
          .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
              .stroke(Tokens.Palette.accent.color, lineWidth: focused ? Tokens.Stroke.focus : Tokens.Stroke.none)
              .padding(-Tokens.Space.n3)
          }
          .shadow(color: hovering ? Tokens.Shadow.card.color.color : Tokens.Palette.clear.color, radius: Tokens.Shadow.card.radius, x: Tokens.Shadow.card.offset.width, y: Tokens.Shadow.card.offset.height)

        Text(item.title)
          .font(Tokens.Typography.cardTitle.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textPrimary.color)
          .lineLimit(1)

        Text(item.isMissing ? L("File missing") : item.subtitle)
          .font(Tokens.Typography.caption.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textSecondary.color)
          .lineLimit(1)
      }
      .contentShape(Rectangle())
      .scaleEffect(hovering && !(reduceMotion || disableAnimations) ? Tokens.Library.cardHoverScale : 1)
      .animation(Tokens.Motion.swiftUI(Tokens.Motion.hover, reduceMotion: reduceMotion || disableAnimations), value: hovering)
    }
    .buttonStyle(.plain)
    .focusable()
    .focused($focused)
    .onHover { hovering = $0 }
    .accessibilityLabel(item.title)
    .help(item.title + "\n" + item.subtitle)
    .contextMenu { LibraryItemActions(item: item) }
    .accessibilityHint(L("Open details"))
  }
}

// MARK: - Search

private struct SearchView: View {
  @Environment(\.libraryTextScale) private var textScale
  @ObservedObject var model: LibraryModel
  let select: (LibraryItem) -> Void
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: Tokens.Space.n28) {
      NativeLibrarySearchField(query: $model.query)
        .frame(maxWidth: Tokens.Size.searchFieldWidth)
        .frame(height: Tokens.Size.n30)
        .padding(.horizontal, Tokens.Space.n16)
        .padding(.top, Tokens.Library.searchTop)

      if !model.hasLoaded {
        LibraryLoadingState()
      } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        EmptyStateView(
          symbol: "magnifyingglass",
          title: L("Search"),
          message: L("Find a video by its title or folder."))
          .frame(maxHeight: .infinity)
      } else if model.searchResults.isEmpty {
        EmptyStateView(
          symbol: "magnifyingglass",
          title: L("No Results"),
          message: LF("Nothing matches “%@”.", model.query),
          actionTitle: L("Clear Search")) { model.query = "" }
          .frame(maxHeight: .infinity)
      } else {
        ScrollView {
          LibraryCollectionView(items: model.searchResults, select: select)
            .padding(.horizontal, Tokens.Space.pageMargin)
            .padding(.bottom, Tokens.Space.pageBottom)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Tokens.Palette.canvas.color)
    .onAppear {
      focused = true
    }
  }
}

// MARK: - Detail

private struct DetailView: View {
  @Environment(\.libraryTextScale) private var textScale
  let item: LibraryItem
  @ObservedObject var inlinePlayer: InlinePlayerModel
  let host: InlinePlayerSurfaceHost
  let play: () -> Void
  let openInNewWindow: () -> Void
  let back: () -> Void
  /// Fullscreen or Focus mode: the surface fills the window and the page
  /// chrome, metadata and actions step out of the way.
  let immersive: Bool
  var coveredByVideoFullscreen = false
  var pausesOnDisappear = true

  @Environment(\.colorSchemeContrast) private var contrast
  @EnvironmentObject private var library: LibraryModel

  /// The live surface appears only when this detail's item is the file the
  /// inline player currently presents.
  private var isPlayingHere: Bool {
    guard inlinePlayer.isActive, let current = inlinePlayer.currentURL else { return false }
    return current == item.url
  }

  var body: some View {
    ZStack {
      if coveredByVideoFullscreen {
        Tokens.Palette.black.color
      } else if isPlayingHere {
        immersiveSurface
      } else {
        page
      }
    }
    // Lifecycle sits outside the branch: switching between the page and the
    // immersive layout must not pause and resume playback.
    .onAppear { inlinePlayer.refresh() }
    .onDisappear {
      if pausesOnDisappear { inlinePlayer.pauseForNavigation() }
    }
  }

  private var page: some View {
    GeometryReader { geometry in
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.n24) {
        Button(action: back) {
          Label(L("Back"), systemImage: "chevron.left")
            .font(Tokens.Typography.body.scaledFont(textScale))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.Palette.textSecondary.color)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel(L("Back"))
        .help(L("Back"))
        .frame(minHeight: Tokens.Size.n30)

        Group {
          if isPlayingHere { liveSurface } else { poster }
        }
        .frame(height: LibraryLayout.videoHeight(
          width: max(Tokens.Space.n0, geometry.size.width - Tokens.Space.pageMargin * 2),
          viewportHeight: geometry.size.height))

        ViewThatFits(in: .horizontal) {
          actionRow
          VStack(alignment: .leading, spacing: Tokens.Space.n12) { primaryAction; secondaryActions }
        }

        if item.isMissing {
          Label(L("File missing. Reconnect its drive or locate the video."), systemImage: "exclamationmark.triangle")
            .font(Tokens.Typography.body.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textSecondary.color)
        }
        metadata
      }
      .padding(.horizontal, Tokens.Space.pageMargin)
      .padding(.top, Tokens.Space.pageTop)
      .padding(.bottom, Tokens.Space.pageBottom)
    }
    .background(Tokens.Palette.canvas.color)
    }
  }

  private var actionRow: some View {
    HStack(alignment: .center, spacing: Tokens.Space.n16) {
      primaryAction.fixedSize()
      Spacer(minLength: Tokens.Space.n8)
      secondaryActions
    }
  }

  @ViewBuilder
  private var primaryAction: some View {
    if item.isMissing {
      Button(L("Locate File…")) { library.locate(item) }
        .buttonStyle(.borderedProminent)
    } else {

          if !isPlayingHere {
            Button(action: play) {
              Label(item.isResumable ? L("Resume") : L("Play"), systemImage: "play.fill")
                .font(Tokens.Typography.button.scaledFont(textScale))
                .padding(.horizontal, Tokens.Space.n20)
                .padding(.vertical, Tokens.Space.n10)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(item.isResumable ? L("Resume") : L("Play"))
            .help(item.isResumable ? L("Resume") : L("Play"))
          } else {
            Button(action: openInNewWindow) {
              Label(L("Open in New Window"), systemImage: "macwindow.on.rectangle")
                .font(Tokens.Typography.button.scaledFont(textScale))
                .padding(.horizontal, Tokens.Space.n20)
                .padding(.vertical, Tokens.Space.n10)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(L("Open in New Window"))
            .help(L("Open in New Window"))
          }

    }
  }

  private var secondaryActions: some View {
    HStack(spacing: Tokens.Space.n12) {
      if item.url.isFileURL && !item.isMissing {
        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
          .buttonStyle(.bordered)
          .fixedSize()
      }
      LibraryItemMenu(item: item)
    }
  }

  private var metadata: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.n12) {
          Text(L("Details"))
            .font(Tokens.Typography.sectionTitle.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textPrimary.color)

          Grid(alignment: .leading, horizontalSpacing: Tokens.Space.n24, verticalSpacing: Tokens.Space.n8) {
            detailRow(L("Folder"), item.subtitle)
            detailRow(L("File"), item.url.lastPathComponent)
            if item.duration > 0 {
              detailRow(L("Duration"), item.durationText)
            }
            if let year = item.metadata.year {
              detailRow(L("Year"), String(year))
            }
            if let code = item.metadata.episodeCode {
              detailRow(L("Episode"), code)
            }
            if let quality = item.metadata.quality {
              detailRow(L("Quality"), quality)
            }
            if let size = fileSize {
              detailRow(L("Size"), size)
            }
            if let format {
              detailRow(L("Format"), format)
            }
            detailRow(L("Location"), item.url.deletingLastPathComponent().path)
          }
        }
  }

  /// Fullscreen and Focus mode: only the live surface, filling the window.
  private var immersiveSurface: some View {
    ZStack {
      Tokens.Palette.black.color
      InlinePlayerView(host: host)
      InlinePlayerChrome(model: inlinePlayer, details: AnyView(detailsPanel))
    }
    .background(Tokens.Palette.black.color)
    .ignoresSafeArea()
  }

  private var detailsPanel: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.n16) {
        metadata
        secondaryActions
        primaryAction
      }.padding(Tokens.Space.n20)
    }
    .frame(width: Tokens.Inspector.idealWidth, height: Tokens.Size.n420)
  }

  private var liveSurface: some View {
    Tokens.Palette.black.color
      .overlay {
        ZStack {
          InlinePlayerView(host: host)
          InlinePlayerChrome(model: inlinePlayer)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous)
          .stroke(
            contrast == .increased ? Tokens.Palette.mediaBorderIncreased.color : Tokens.Palette.mediaBorder.color,
            lineWidth: contrast == .increased ? Tokens.Stroke.strong : Tokens.Stroke.hairline)
      }
  }

  private var poster: some View {
    Tokens.Palette.clear.color
      .overlay {
        ZStack(alignment: .bottomLeading) {
          PosterImage(url: item.url)
          LinearGradient(
            colors: [Tokens.Palette.clear.color, Tokens.Palette.detailGradientMid.color, Tokens.Palette.detailGradientEnd.color],
            startPoint: .top,
            endPoint: .bottom)
          VStack(alignment: .leading, spacing: Tokens.Library.cardSpacing) {
            Text(item.title)
              .font(Tokens.Typography.heroTitle.scaledFont(textScale))
              .lineLimit(2)
            if !item.metadata.detailLine.isEmpty {
              Text(item.metadata.detailLine)
                .font(Tokens.Typography.heroBody.scaledFont(textScale))
                .foregroundStyle(Tokens.Palette.onMediaSecondary.color)
            }
          }
          .foregroundStyle(Tokens.Palette.onMedia.color)
          .padding(Tokens.Space.n28)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous)
          .stroke(
            contrast == .increased ? Tokens.Palette.mediaBorderIncreased.color : Tokens.Palette.mediaBorder.color,
            lineWidth: contrast == .increased ? Tokens.Stroke.strong : Tokens.Stroke.hairline)
      }
  }

  private var fileSize: String? {
    guard item.url.isFileURL,
          let values = try? item.url.resourceValues(forKeys: [.fileSizeKey]),
          let bytes = values.fileSize else { return nil }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  private var format: String? {
    let ext = item.url.pathExtension.uppercased()
    return ext.isEmpty ? nil : ext
  }

  @ViewBuilder
  private func detailRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label)
        .font(Tokens.Typography.caption.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textSecondary.color)
        .gridColumnAlignment(.trailing)
      Text(value)
        .font(Tokens.Typography.body.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textPrimary.color)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
  }
}

// MARK: - Shared pieces

private struct ProgressBar: View {
  @Environment(\.libraryTextScale) private var textScale
  let value: Double

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Tokens.Palette.progressTrack.color)
        Capsule()
          .fill(Tokens.Palette.white.color)
          .frame(width: CGFloat(max(0, min(1, value))) * proxy.size.width)
      }
    }
    .frame(height: Tokens.Library.progressHeight)
  }
}

struct PosterImage: View {
  @Environment(\.libraryTextScale) private var textScale
  let url: URL

  @State private var image: NSImage?

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        if let image {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        } else {
          PlaceholderArt(title: url.deletingPathExtension().lastPathComponent)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .task(id: url) {
      image = nil
      let loaded = await PosterStore.shared.image(for: url)
      guard !Task.isCancelled else { return }
      image = loaded
    }
  }
}

private struct PlaceholderArt: View {
  @Environment(\.libraryTextScale) private var textScale
  let title: String

  private var hue: Double {
    let seed = title.unicodeScalars.reduce(0) { partial, scalar in
      (partial &* 31 &+ Int(scalar.value)) & 0xFFFF
    }
    return Double(seed % 360) / 360
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Tokens.Library.placeholderTop(hue: hue),
          Tokens.Library.placeholderBottom(hue: hue)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

      Image(systemName: "play.rectangle.fill")
        .font(.system(size: Tokens.Library.placeholderGlyph, weight: .regular))
        .foregroundStyle(Tokens.Palette.onMediaFaint.color)
    }
  }
}

struct EmptyStateView: View {
  @Environment(\.libraryTextScale) private var textScale
  let symbol: String
  let title: String
  let message: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: Tokens.Space.n12) {
      Image(systemName: symbol)
        .font(.system(size: Tokens.Library.emptyStateGlyph, weight: .light))
        .foregroundStyle(Tokens.Palette.textSecondary.color)
      Text(title)
        .font(Tokens.Typography.sectionTitle.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textPrimary.color)
      Text(message)
        .font(Tokens.Typography.body.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textSecondary.color)
        .multilineTextAlignment(.center)
        .frame(maxWidth: Tokens.Size.emptyStateWidth)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.borderedProminent)
          .padding(.top, Tokens.Space.n4)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(Tokens.Library.dropPadding)
  }
}

private struct DropOverlay: View {
  @Environment(\.libraryTextScale) private var textScale
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: Tokens.Library.dropCorner, style: .continuous)
        .fill(Tokens.Palette.accent.color.opacity(Tokens.Opacity.n12))
      RoundedRectangle(cornerRadius: Tokens.Library.dropCorner, style: .continuous)
        .strokeBorder(
          Tokens.Palette.accent.color,
          style: StrokeStyle(lineWidth: Tokens.Stroke.strong, dash: Tokens.Library.dropDash))
      VStack(spacing: Tokens.Space.n8) {
        Image(systemName: "arrow.down.doc")
          .font(.system(size: Tokens.Library.dropGlyph, weight: .regular))
        Text(L("Drop to open"))
          .font(Tokens.Typography.sectionTitle.scaledFont(textScale))
      }
      .foregroundStyle(Tokens.Palette.accent.color)
    }
    .padding(Tokens.Library.dropPadding)
    .allowsHitTesting(false)
  }
}

// MARK: - Shared collection controls

private struct LibraryCollectionView: View {
  @EnvironmentObject private var model: LibraryModel
  @Environment(\.libraryTextScale) private var textScale
  let items: [LibraryItem]
  let select: (LibraryItem) -> Void
  @AppStorage("library.view.v1") private var listView = false
  @AppStorage("library.sort.v1") private var sort: LibrarySort = .title
  @AppStorage("library.filter.v1") private var filter: LibraryFilter = .all

  private var visible: [LibraryItem] {
    LibraryQuery.apply(items, query: "", sort: sort, filter: filter)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.n16) {
      HStack(spacing: Tokens.Space.n12) {
        Picker(L("Sort"), selection: $sort) {
          Text(L("Title")).tag(LibrarySort.title)
          Text(L("Recently Played")).tag(LibrarySort.recent)
          Text(L("Progress")).tag(LibrarySort.progress)
        }
        .fixedSize()
        Picker(L("Filter"), selection: $filter) {
          Text(L("All")).tag(LibraryFilter.all)
          Text(L("Unfinished")).tag(LibraryFilter.unfinished)
          Text(L("Watched")).tag(LibraryFilter.watched)
          Text(L("Missing Files")).tag(LibraryFilter.missing)
        }
        .fixedSize()
        Spacer(minLength: Tokens.Space.n0)
        Toggle(isOn: $listView) { Image(systemName: "list.bullet") }
          .toggleStyle(.button)
          .help(L("List View"))
          .accessibilityLabel(L("List View"))
      }
      if model.hiddenCount > 0 {
        Button(L("Restore Hidden Videos")) { model.restoreHiddenItems() }
          .buttonStyle(.borderless)
      }
      if visible.isEmpty {
        EmptyStateView(symbol: "line.3.horizontal.decrease", title: L("No matching videos"),
          message: L("No videos match this filter."), actionTitle: L("Show All Videos")) { filter = .all }
          .frame(minHeight: Tokens.Library.gridEmptyStateMinimum)
      } else if listView {
        LazyVStack(spacing: Tokens.Space.n8) {
          ForEach(visible) { item in
            HStack(spacing: Tokens.Space.n12) {
              Button { select(item) } label: {
                HStack(spacing: Tokens.Space.n12) {
                  PosterImage(url: item.url)
                    .frame(width: Tokens.Library.listThumbnailWidth, height: Tokens.Library.listThumbnailHeight)
                    .clipped()
                  VStack(alignment: .leading, spacing: Tokens.Space.n4) {
                    Text(item.title).font(Tokens.Typography.bodyStrong.scaledFont(textScale))
                    Text(item.isMissing ? L("File missing") : item.subtitle)
                      .font(Tokens.Typography.caption.scaledFont(textScale))
                      .foregroundStyle(Tokens.Palette.textSecondary.color)
                  }
                  Spacer(minLength: Tokens.Space.n8)
                  Text(item.progressText).font(Tokens.Typography.numeric.scaledFont(textScale))
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .help(item.title + "\n" + item.subtitle)
              .contextMenu { LibraryItemActions(item: item) }
              LibraryItemMenu(item: item)
            }
            .padding(Tokens.Space.n8)
            .background(Tokens.Palette.surface.color, in: RoundedRectangle(cornerRadius: Tokens.Radius.n8))
          }
        }
      } else {
        LibraryCardGrid(items: visible, select: select)
      }
    }
  }
}

private struct LibraryItemMenu: View {
  @Environment(\.libraryTextScale) private var textScale
  let item: LibraryItem
  var body: some View {
    Menu { LibraryItemActions(item: item) } label: {
      Image(systemName: "ellipsis")
        .frame(width: Tokens.Size.n30, height: Tokens.Size.n30)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(L("Video Actions"))
    .accessibilityLabel(L("Video Actions"))
  }
}

private struct LibraryItemActions: View {
  @Environment(\.libraryTextScale) private var textScale
  let item: LibraryItem
  @EnvironmentObject private var model: LibraryModel
  var body: some View {
    if item.isMissing {
      Button(L("Locate File…")) { model.locate(item) }
    } else {
      Button(item.isResumable ? L("Resume") : L("Play")) { model.open(item) }
      if item.url.isFileURL {
        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
      }
    }
    Button(item.isFinished ? L("Mark Unwatched") : L("Mark Watched")) { model.markWatched(item) }
    Divider()
    Button(L("Remove from Library")) { model.remove(item) }
      .help(L("Hides this entry. The video file is kept."))
  }
}

struct NativeLibrarySearchField: NSViewRepresentable {
  @Binding var query: String
  var placeholder: String? = nil
  var accessibilityLabel: String? = nil
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = placeholder ?? L("Search titles and folders")
    field.setAccessibilityLabel(accessibilityLabel ?? L("Search Library"))
    field.sendsSearchStringImmediately = true
    field.delegate = context.coordinator
    DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    return field
  }
  func updateNSView(_ view: NSSearchField, context: Context) {
    context.coordinator.parent = self
    if view.stringValue != query { view.stringValue = query }
  }
  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: NativeLibrarySearchField
    init(_ parent: NativeLibrarySearchField) { self.parent = parent }
    func controlTextDidChange(_ obj: Notification) {
      if let field = obj.object as? NSSearchField { parent.query = field.stringValue }
    }
  }
}

/// The content under the native titlebar is visual only: its top strip belongs
/// to window interaction, including over a channel's WKWebView.
private struct WindowDragRegion: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ view: NSView, context: Context) {}
  private final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
      guard let window else { return }
      if event.clickCount == 2 {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        if action == "Minimize" { window.performMiniaturize(nil) }
        else if action != "None" { window.performZoom(nil) }
      } else { window.performDrag(with: event) }
    }
  }
}

private struct PaneResizeHandle: View {
  let width: CGFloat
  var direction: CGFloat = 1
  let resize: (CGFloat) -> Void
  @State private var initialWidth: CGFloat?
  var body: some View {
    Tokens.Palette.clear.color
      .frame(width: Tokens.Library.paneResizeWidth)
      .contentShape(Rectangle())
      .gesture(DragGesture().onChanged { value in
        if initialWidth == nil { initialWidth = width }
        resize((initialWidth ?? width) + direction * value.translation.width)
      }.onEnded { _ in initialWidth = nil })
      .accessibilityLabel(direction > 0 ? L("Sidebar Width") : L("Inspector Width"))
      .accessibilityAdjustableAction { adjustment in
        resize(width + (adjustment == .increment ? Tokens.Space.n20 : -Tokens.Space.n20))
      }
  }
}

private struct LibrarySidebarMaterial: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.apply(Tokens.Material.librarySidebar)
    return view
  }
  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.apply(Tokens.Material.librarySidebar)
  }
}

struct LibraryLoadingState: View {
  @Environment(\.libraryTextScale) private var textScale
  var body: some View {
    VStack(spacing: Tokens.Space.n12) {
      ProgressView().controlSize(.regular)
      Text(L("Loading videos…"))
        .font(Tokens.Typography.body.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textSecondary.color)
    }
    .frame(maxWidth: .infinity, minHeight: Tokens.Library.emptyStateMinimum)
    .accessibilityElement(children: .combine)
  }
}
