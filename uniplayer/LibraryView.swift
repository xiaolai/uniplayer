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

private func L(_ key: String) -> String {
  NSLocalizedString(key, comment: "")
}

private func LF(_ key: String, _ arguments: CVarArg...) -> String {
  String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}

enum LibrarySidebarItem: Hashable {
  case section(LibrarySection)
  case channel(String)
}

enum LibrarySection: String, CaseIterable, Identifiable {
  case home
  case search
  case continueWatching
  case recent
  case all

  var id: String { rawValue }

  var title: String {
    switch self {
    case .home: return L("Home")
    case .search: return L("Search")
    case .continueWatching: return L("Continue Watching")
    case .recent: return L("Recently Added")
    case .all: return L("All Videos")
    }
  }

  var symbol: String {
    switch self {
    case .home: return "house"
    case .search: return "magnifyingglass"
    case .continueWatching: return "play.circle"
    case .recent: return "clock"
    case .all: return "rectangle.stack"
    }
  }
}

// MARK: - Chrome

/// The library window's column state and the actions its toolbar invokes.
@MainActor
final class LibraryChrome: ObservableObject {
  @Published var columnVisibility: NavigationSplitViewVisibility = .all
  var openFile: (() -> Void)?
  var openURL: (() -> Void)?

  func toggleSidebar() {
    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
  }
}

/// The titlebar controls: Open File and Open URL grouped in one glass capsule
/// at the sidepane's trailing edge, plus a circular sidebar toggle. While the
/// sidebar is collapsed, only the hover-revealed toggle remains.
struct LibraryTitlebarControls: View {
  @ObservedObject var chrome: LibraryChrome
  @State private var hovering = false

  private var isCollapsed: Bool {
    chrome.columnVisibility == .detailOnly
  }

  var body: some View {
    HStack(spacing: Tokens.Space.n8) {
      if isCollapsed {
        sidebarToggle
          .opacity(hovering ? 1 : 0)
        Spacer(minLength: 0)
      } else {
        Spacer(minLength: 0)
        openGroup
        sidebarToggle
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onHover { hovering = $0 }
  }

  /// The reference app groups related icon buttons in one capsule.
  private var openGroup: some View {
    HStack(spacing: 0) {
      iconButton("folder", help: L("Open File…")) { chrome.openFile?() }
      iconButton("link", help: L("Open URL…")) { chrome.openURL?() }
    }
    .glassEffect(.regular.interactive(), in: .capsule)
  }

  private var sidebarToggle: some View {
    Button {
      chrome.toggleSidebar()
    } label: {
      iconLabel("sidebar.squares.leading")
    }
    .buttonStyle(.plain)
    .foregroundStyle(Tokens.Palette.textPrimary.color)
    .glassEffect(.regular.interactive(), in: .circle)
    .help(isCollapsed ? L("Show Sidebar") : L("Hide Sidebar"))
  }

  private func iconButton(_ symbol: String, help: String,
                          action: @escaping () -> Void) -> some View {
    Button(action: action) {
      iconLabel(symbol)
    }
    .buttonStyle(.plain)
    .foregroundStyle(Tokens.Palette.textPrimary.color)
    .help(help)
  }

  private func iconLabel(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .font(Tokens.Typography.titlebarIcon.font)
      .frame(width: Tokens.Size.n36, height: Tokens.Size.n36)
      .contentShape(Rectangle())
  }
}

// MARK: - Root

struct LibraryRootView: View {
  private let open: (URL) -> Void
  private let openMany: ([URL]) -> Void

  @StateObject private var model: LibraryModel
  @ObservedObject private var chrome: LibraryChrome
  @ObservedObject private var channels = ChannelStore.shared
  @StateObject private var browser = ChannelBrowserModel()
  @State private var selection: LibrarySidebarItem? = .section(.home)
  @State private var selectedItem: LibraryItem?
  @State private var dropTargeted = false
  @State private var channelEditor: ChannelEditorSheet.Mode?
  @State private var channelPendingDeletion: Channel?

  init(player: PlayerCore, chrome: LibraryChrome) {
    // Weak on purpose: PlayerCore owns the window that owns this view.
    let open: (URL) -> Void = { [weak player] url in
      DispatchQueue.main.async {
        player?.openURL(url)
      }
    }
    let openMany: ([URL]) -> Void = { [weak player] urls in
      guard !urls.isEmpty else { return }
      DispatchQueue.main.async {
        _ = player?.openURLs(urls)
      }
    }
    self.open = open
    self.openMany = openMany
    self.chrome = chrome
    let model = LibraryModel(open: open)
    _model = StateObject(wrappedValue: model)
    chrome.openFile = { [weak model] in
      model?.openFilePanel()
    }
    chrome.openURL = {
      AppDelegate.shared.openURL(NSApp)
    }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $chrome.columnVisibility) {
      sidebar
        .frame(width: Tokens.Size.sidebarWidth)
        .toolbar(removing: .sidebarToggle)
    } detail: {
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.canvas.color)
        .ignoresSafeArea(.container, edges: .top)
    }
    .navigationSplitViewStyle(.balanced)
    .tint(Tokens.Palette.accent.color)
    .background(Tokens.Palette.canvas.color)
    .overlay {
      if dropTargeted {
        DropOverlay()
      }
    }
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
      var urls = Array<URL?>(repeating: nil, count: providers.count)
      let group = DispatchGroup()
      for (index, provider) in providers.enumerated() {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          if let url, url.isFileURL {
            urls[index] = url
          }
          group.leave()
        }
      }
      group.notify(queue: .main) {
        let resolved = urls.compactMap { $0 }
        if resolved.count == 1 {
          open(resolved[0])
        } else {
          openMany(resolved)
        }
      }
      return true
    }
    .onAppear {
      model.reload()
    }
    .onChange(of: selection) { _, _ in
      selectedItem = nil
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
        Label(LibrarySection.home.title, systemImage: LibrarySection.home.symbol)
          .tag(LibrarySidebarItem.section(.home))
        Label(LibrarySection.search.title, systemImage: LibrarySection.search.symbol)
          .tag(LibrarySidebarItem.section(.search))
      }
      Section {
        Label(LibrarySection.recent.title, systemImage: LibrarySection.recent.symbol)
          .tag(LibrarySidebarItem.section(.recent))
        Label(LibrarySection.all.title, systemImage: LibrarySection.all.symbol)
          .tag(LibrarySidebarItem.section(.all))
      } header: {
        Text(L("Library"))
      }
      Section {
        ForEach(channels.channels) { channel in
          Label(channel.name, systemImage: channel.symbol)
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
          Label(L("Add Channel…"), systemImage: "plus")
        }
        .buttonStyle(.plain)
      } header: {
        Text(L("Channels"))
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .background(Tokens.Palette.sidebar.color)
    .navigationSplitViewColumnWidth(
      min: Tokens.Library.sidebarMinimum,
      ideal: Tokens.Size.sidebarWidth,
      max: Tokens.Library.sidebarMaximum)
    .safeAreaInset(edge: .bottom) {
      Text(versionText)
        .font(Tokens.Typography.caption.font)
        .foregroundStyle(Tokens.Palette.textTertiary.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.Library.sidebarVersionInset)
        .padding(.bottom, Tokens.Library.sidebarVersionBottom)
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let selectedItem {
      DetailView(
        item: model.allItems.first(where: { $0.id == selectedItem.id }) ?? selectedItem,
        play: { open(selectedItem.url) },
        back: { self.selectedItem = nil })
    } else {
      switch selection ?? .section(.home) {
      case .section(.home):
        HomeView(
          model: model,
          select: { selectedItem = $0 },
          seeAll: { selection = .section($0) })
      case .section(.search):
        SearchView(model: model, select: { selectedItem = $0 })
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
          emptyMessage: L("Open a video to start your library."))
      case .section(.all):
        LibraryGridView(
          title: LibrarySection.all.title,
          items: model.allItems,
          model: model,
          select: { selectedItem = $0 },
          emptyMessage: L("Open a video to start your library."))
      case .channel(let id):
        if let channel = channels.channel(id: id) {
          ChannelDetailView(browser: browser, channel: channel)
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

  private var versionText: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    return version.isEmpty ? "UniPlayer" : "UniPlayer \(version)"
  }
}

// MARK: - Home

private struct HomeView: View {
  @ObservedObject var model: LibraryModel
  let select: (LibraryItem) -> Void
  let seeAll: (LibrarySection) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.sectionGap) {
        if let hero = model.hero {
          HeroView(item: hero) {
            model.open(hero)
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
            title: L("No videos yet"),
            message: L("Open a video to start your library."),
            actionTitle: L("Open File…")) {
              model.openFilePanel()
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
  let item: LibraryItem
  let play: () -> Void

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Tokens.Palette.clear.color
      .aspectRatio(Tokens.Aspect.video, contentMode: .fit)
      .overlay {
        ZStack(alignment: .bottomLeading) {
          PosterImage(url: item.url)

          LinearGradient(
            colors: [Tokens.Palette.clear.color, Tokens.Palette.heroGradientMid.color, Tokens.Palette.heroShade.color],
            startPoint: .top,
            endPoint: .bottom)

          VStack(alignment: .leading, spacing: Tokens.Library.heroSpacing) {
            Text(item.title)
              .font(Tokens.Typography.heroTitle.font)
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
            .font(Tokens.Typography.heroBody.font)
            .foregroundStyle(Tokens.Palette.onMediaSecondary.color)

            Button(action: play) {
              Label(
                item.isResumable ? L("Resume") : L("Play"),
                systemImage: "play.fill")
                .font(Tokens.Typography.button.font)
                .padding(.horizontal, Tokens.Library.heroButtonHorizontal)
                .padding(.vertical, Tokens.Library.heroButtonVertical)
                .background(Tokens.Palette.white.color, in: Capsule())
                .foregroundStyle(Tokens.Palette.black.color)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.top, Tokens.Space.n4)
            .accessibilityLabel(item.isResumable ? L("Resume") : L("Play"))
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
  let items: [LibraryItem]
  let select: (LibraryItem) -> Void
  let seeAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Library.shelfHeaderSpacing) {
      HStack(alignment: .firstTextBaseline) {
        Text(L("Continue Watching"))
          .font(Tokens.Typography.sectionTitle.font)
          .foregroundStyle(Tokens.Palette.textPrimary.color)
        Spacer()
        Button(L("See All"), action: seeAll)
          .buttonStyle(.plain)
          .font(Tokens.Typography.caption.font)
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
            .font(Tokens.Typography.cardTitle.font)
            .lineLimit(2)
          Text(item.progressText)
            .font(Tokens.Typography.caption.font)
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
    .accessibilityHint(L("Open details"))
  }
}

private struct RecentlyAddedShelf: View {
  let items: [LibraryItem]
  let select: (LibraryItem) -> Void
  let seeAll: () -> Void

  private let columns = [
    GridItem(.adaptive(minimum: Tokens.Size.gridMinimum, maximum: Tokens.Size.gridMaximum),
             spacing: Tokens.Library.cardGap)
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.n14) {
      HStack(alignment: .firstTextBaseline) {
        Text(L("Recently Added"))
          .font(Tokens.Typography.sectionTitle.font)
          .foregroundStyle(Tokens.Palette.textPrimary.color)
        Spacer()
        Button(L("See All"), action: seeAll)
          .buttonStyle(.plain)
          .font(Tokens.Typography.caption.font)
          .foregroundStyle(Tokens.Palette.textSecondary.color)
      }

      LazyVGrid(columns: columns, alignment: .leading, spacing: Tokens.Library.gridRowGap) {
        ForEach(items) { item in
          LibraryCard(item: item) {
            select(item)
          }
        }
      }
    }
  }
}

// MARK: - Grid

private struct LibraryGridView: View {
  let title: String
  let items: [LibraryItem]
  @ObservedObject var model: LibraryModel
  let select: (LibraryItem) -> Void
  let emptyMessage: String
  var onBack: (() -> Void)?

  private let columns = [
    GridItem(.adaptive(minimum: Tokens.Size.gridMinimum, maximum: Tokens.Size.gridMaximum),
             spacing: Tokens.Library.cardGap)
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.n20) {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.n10) {
          if let onBack {
            Button(action: onBack) {
              Image(systemName: "chevron.left")
                .font(Tokens.Typography.sectionTitle.font)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.Palette.textSecondary.color)
            .accessibilityLabel(L("Back"))
          }
          Text(title)
            .font(Tokens.Typography.pageTitle.font)
            .foregroundStyle(Tokens.Palette.textPrimary.color)
          Spacer()
          Text("\(items.count)")
            .font(Tokens.Typography.caption.font)
            .foregroundStyle(Tokens.Palette.textSecondary.color)
        }

        if items.isEmpty {
          EmptyStateView(
            symbol: "play.rectangle.on.rectangle",
            title: L("No videos yet"),
            message: emptyMessage,
            actionTitle: L("Open File…")) {
              model.openFilePanel()
            }
          .frame(minHeight: Tokens.Library.gridEmptyStateMinimum)
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: Tokens.Library.gridRowGap) {
            ForEach(items) { item in
              LibraryCard(item: item) {
                select(item)
              }
            }
          }
        }
      }
      .padding(.horizontal, Tokens.Space.pageMargin)
      .padding(.top, Tokens.Space.n28)
      .padding(.bottom, Tokens.Space.pageBottom)
    }
  }
}

private struct LibraryCard: View {
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
                lineWidth: contrast == .increased ? 2 : 1)
          }
          .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
              .stroke(Tokens.Palette.accent.color, lineWidth: focused ? 3 : 0)
              .padding(-Tokens.Space.n3)
          }
          .shadow(color: hovering ? Tokens.Shadow.card.color.color : Tokens.Palette.clear.color, radius: Tokens.Shadow.card.radius, x: Tokens.Shadow.card.offset.width, y: Tokens.Shadow.card.offset.height)

        Text(item.title)
          .font(Tokens.Typography.cardTitle.font)
          .foregroundStyle(Tokens.Palette.textPrimary.color)
          .lineLimit(1)

        Text(item.subtitle)
          .font(Tokens.Typography.caption.font)
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
    .accessibilityHint(L("Open details"))
  }
}

// MARK: - Search

private struct SearchView: View {
  @ObservedObject var model: LibraryModel
  let select: (LibraryItem) -> Void
  @FocusState private var focused: Bool

  private let columns = [
    GridItem(.adaptive(minimum: Tokens.Size.gridMinimum, maximum: Tokens.Size.gridMaximum),
             spacing: Tokens.Library.cardGap)
  ]

  var body: some View {
    VStack(spacing: Tokens.Space.n28) {
      HStack(spacing: Tokens.Space.n10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(Tokens.Palette.textSecondary.color)
        TextField(L("Search"), text: $model.query)
          .textFieldStyle(.plain)
          .font(Tokens.Typography.searchField.font)
          .focused($focused)
      }
      .padding(.horizontal, Tokens.Library.searchHorizontal)
      .padding(.vertical, Tokens.Library.searchVertical)
      .background(Tokens.Palette.surface.color, in: RoundedRectangle(cornerRadius: Tokens.Library.searchCorner, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Tokens.Library.searchCorner, style: .continuous)
          .stroke(Tokens.Palette.separator.color, lineWidth: Tokens.Stroke.hairline)
      }
      .frame(width: Tokens.Size.searchFieldWidth)
      .padding(.top, Tokens.Library.searchTop)

      if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        EmptyStateView(
          symbol: "magnifyingglass",
          title: L("Search"),
          message: L("Find a video by its title or folder."))
          .frame(maxHeight: .infinity)
      } else if model.searchResults.isEmpty {
        EmptyStateView(
          symbol: "magnifyingglass",
          title: L("No Results"),
          message: LF("Nothing matches “%@”.", model.query))
          .frame(maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVGrid(columns: columns, alignment: .leading, spacing: Tokens.Library.gridRowGap) {
            ForEach(model.searchResults) { item in
              LibraryCard(item: item) {
                select(item)
              }
            }
          }
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
  let item: LibraryItem
  let play: () -> Void
  let back: () -> Void

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.n24) {
        Button(action: back) {
          Label(L("Back"), systemImage: "chevron.left")
            .font(Tokens.Typography.body.font)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.Palette.textSecondary.color)
        .keyboardShortcut(.cancelAction)

        Tokens.Palette.clear.color
          .aspectRatio(Tokens.Aspect.video, contentMode: .fit)
          .overlay {
            ZStack(alignment: .bottomLeading) {
              PosterImage(url: item.url)
              LinearGradient(
                colors: [Tokens.Palette.clear.color, Tokens.Palette.detailGradientMid.color, Tokens.Palette.detailGradientEnd.color],
                startPoint: .top,
                endPoint: .bottom)
              VStack(alignment: .leading, spacing: Tokens.Library.cardSpacing) {
                Text(item.title)
                  .font(Tokens.Typography.heroTitle.font)
                  .lineLimit(2)
                if !item.metadata.detailLine.isEmpty {
                  Text(item.metadata.detailLine)
                    .font(Tokens.Typography.heroBody.font)
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

        HStack(alignment: .center, spacing: Tokens.Space.n16) {
          Button(action: play) {
            Label(item.isResumable ? L("Resume") : L("Play"), systemImage: "play.fill")
              .font(Tokens.Typography.button.font)
              .padding(.horizontal, Tokens.Space.n20)
              .padding(.vertical, Tokens.Space.n10)
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)

          if item.isResumable {
            VStack(alignment: .leading, spacing: Tokens.Space.n5) {
              Text(item.progressText)
                .font(Tokens.Typography.caption.font)
                .foregroundStyle(Tokens.Palette.textSecondary.color)
              ProgressView(value: item.progress)
                .tint(Tokens.Palette.accent.color)
                .frame(width: Tokens.Size.progressWidth)
            }
          }

          Spacer()

          if item.url.isFileURL {
            Button(L("Show in Finder")) {
              NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            .buttonStyle(.bordered)
          }
        }

        VStack(alignment: .leading, spacing: Tokens.Space.n12) {
          Text(L("Details"))
            .font(Tokens.Typography.sectionTitle.font)
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
      .padding(.horizontal, Tokens.Space.pageMargin)
      .padding(.top, Tokens.Space.pageTop)
      .padding(.bottom, Tokens.Space.pageBottom)
    }
    .background(Tokens.Palette.canvas.color)
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
        .font(Tokens.Typography.caption.font)
        .foregroundStyle(Tokens.Palette.textSecondary.color)
        .gridColumnAlignment(.trailing)
      Text(value)
        .font(Tokens.Typography.body.font)
        .foregroundStyle(Tokens.Palette.textPrimary.color)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
  }
}

// MARK: - Shared pieces

private struct ProgressBar: View {
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

private struct PosterImage: View {
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

private struct EmptyStateView: View {
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
        .font(Tokens.Typography.sectionTitle.font)
        .foregroundStyle(Tokens.Palette.textPrimary.color)
      Text(message)
        .font(Tokens.Typography.body.font)
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
          .font(Tokens.Typography.sectionTitle.font)
      }
      .foregroundStyle(Tokens.Palette.accent.color)
    }
    .padding(Tokens.Library.dropPadding)
    .allowsHitTesting(false)
  }
}
