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

enum LibrarySection: String, CaseIterable, Identifiable {
  case home
  case search
  case continueWatching
  case recent
  case all
  case playlists

  var id: String { rawValue }

  var title: String {
    switch self {
    case .home: return L("Home")
    case .search: return L("Search")
    case .continueWatching: return L("Continue Watching")
    case .recent: return L("Recently Added")
    case .all: return L("All Videos")
    case .playlists: return L("Playlists")
    }
  }

  var symbol: String {
    switch self {
    case .home: return "house"
    case .search: return "magnifyingglass"
    case .continueWatching: return "play.circle"
    case .recent: return "clock"
    case .all: return "rectangle.stack"
    case .playlists: return "list.bullet.rectangle"
    }
  }
}

// MARK: - Root

struct LibraryRootView: View {
  private let open: (URL) -> Void

  @StateObject private var model: LibraryModel
  @State private var selection: LibrarySection? = .home
  @State private var selectedItem: LibraryItem?
  @State private var dropTargeted = false

  init(player: PlayerCore) {
    // Weak on purpose: PlayerCore owns the window that owns this view.
    let open: (URL) -> Void = { [weak player] url in
      DispatchQueue.main.async {
        player?.openURL(url)
      }
    }
    self.open = open
    _model = StateObject(wrappedValue: LibraryModel(open: open))
  }

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.canvas)
    }
    .navigationSplitViewStyle(.balanced)
    .tint(Tokens.accent)
    .background(Tokens.canvas)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          model.openFilePanel()
        } label: {
          Label(L("Open File…"), systemImage: "folder")
        }
        .help(L("Open File…"))
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          AppDelegate.shared.openURL(NSApp)
        } label: {
          Label(L("Open URL…"), systemImage: "link")
        }
        .help(L("Open URL…"))
      }
    }
    .overlay {
      if dropTargeted {
        DropOverlay()
      }
    }
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
      for provider in providers {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          guard let url, url.isFileURL else { return }
          open(url)
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
  }

  private var sidebar: some View {
    List(selection: $selection) {
      Section {
        Label(LibrarySection.home.title, systemImage: LibrarySection.home.symbol)
          .tag(LibrarySection.home)
        Label(LibrarySection.search.title, systemImage: LibrarySection.search.symbol)
          .tag(LibrarySection.search)
      }
      Section {
        Label(LibrarySection.recent.title, systemImage: LibrarySection.recent.symbol)
          .tag(LibrarySection.recent)
        Label(LibrarySection.all.title, systemImage: LibrarySection.all.symbol)
          .tag(LibrarySection.all)
        Label(LibrarySection.playlists.title, systemImage: LibrarySection.playlists.symbol)
          .tag(LibrarySection.playlists)
      } header: {
        Text(L("Library"))
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .background(Tokens.sidebar)
    .navigationSplitViewColumnWidth(
      min: 200,
      ideal: Tokens.sidebarWidth,
      max: 260)
    .safeAreaInset(edge: .bottom) {
      Text(versionText)
        .font(Tokens.caption)
        .foregroundStyle(Tokens.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
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
      switch selection ?? .home {
      case .home:
        HomeView(
          model: model,
          select: { selectedItem = $0 },
          seeAll: { selection = $0 })
      case .search:
        SearchView(model: model, select: { selectedItem = $0 })
      case .continueWatching:
        LibraryGridView(
          title: LibrarySection.continueWatching.title,
          items: model.continueWatching,
          model: model,
          select: { selectedItem = $0 },
          emptyMessage: L("Open a video and it will appear here."),
          onBack: { selection = .home })
      case .recent:
        LibraryGridView(
          title: LibrarySection.recent.title,
          items: model.recentlyAdded,
          model: model,
          select: { selectedItem = $0 },
          emptyMessage: L("Open a video to start your library."))
      case .all:
        LibraryGridView(
          title: LibrarySection.all.title,
          items: model.allItems,
          model: model,
          select: { selectedItem = $0 },
          emptyMessage: L("Open a video to start your library."))
      case .playlists:
        PlaylistsView()
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
      VStack(alignment: .leading, spacing: Tokens.sectionSpacing) {
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
            items: model.recentlyAdded,
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
          .frame(minHeight: 260)
        }
      }
      .padding(.horizontal, Tokens.contentPadding)
      .padding(.top, 28)
      .padding(.bottom, 48)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct HeroView: View {
  let item: LibraryItem
  let play: () -> Void

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Color.clear
      .aspectRatio(16.0 / 9.0, contentMode: .fit)
      .overlay {
        ZStack(alignment: .bottomLeading) {
          PosterImage(url: item.url)

          LinearGradient(
            colors: [.clear, .black.opacity(0.18), Tokens.heroShade],
            startPoint: .top,
            endPoint: .bottom)

          VStack(alignment: .leading, spacing: 10) {
            Text(item.title)
              .font(Tokens.heroTitle)
              .lineLimit(2)

            HStack(spacing: 8) {
              Text(item.subtitle)
              if item.isResumable {
                Text("·")
                Text(item.progressText)
              } else if item.duration > 0 {
                Text("·")
                Text(item.durationText)
              }
            }
            .font(Tokens.heroBody)
            .foregroundStyle(.white.opacity(0.78))

            Button(action: play) {
              Label(
                item.isResumable ? L("Resume") : L("Play"),
                systemImage: "play.fill")
                .font(Tokens.button)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(.white, in: Capsule())
                .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 4)
            .accessibilityLabel(item.isResumable ? L("Resume") : L("Play"))
          }
          .foregroundStyle(.white)
          .padding(32)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: Tokens.heroCorner, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Tokens.heroCorner, style: .continuous)
        .stroke(
          .white.opacity(contrast == .increased ? 0.5 : 0.08),
          lineWidth: contrast == .increased ? 2 : 1)
    }
    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
  }
}

private struct ContinueWatchingShelf: View {
  let items: [LibraryItem]
  let select: (LibraryItem) -> Void
  let seeAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(L("Continue Watching"))
          .font(Tokens.sectionTitle)
          .foregroundStyle(Tokens.textPrimary)
        Spacer()
        Button(L("See All"), action: seeAll)
          .buttonStyle(.plain)
          .font(Tokens.caption)
          .foregroundStyle(Tokens.textSecondary)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 16) {
          ForEach(items) { item in
            ContinueWatchingCard(item: item) {
              select(item)
            }
          }
        }
        .padding(.vertical, 2)
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
  @FocusState private var focused: Bool

  private var borderOpacity: Double {
    contrast == .increased ? 0.65 : (hovering ? 0.34 : 0.10)
  }

  var body: some View {
    Button(action: play) {
      ZStack(alignment: .bottomLeading) {
        PosterImage(url: item.url)

        LinearGradient(
          colors: [.clear, Tokens.cardShade],
          startPoint: .center,
          endPoint: .bottom)

        VStack(alignment: .leading, spacing: 6) {
          Text(item.title)
            .font(Tokens.cardTitle)
            .lineLimit(2)
          Text(item.progressText)
            .font(Tokens.caption)
            .foregroundStyle(.white.opacity(0.72))
          ProgressBar(value: item.progress)
        }
        .padding(12)
        .foregroundStyle(.white)
      }
      .frame(width: Tokens.cardWidth, height: Tokens.cardHeight)
      .clipShape(RoundedRectangle(cornerRadius: Tokens.cardCorner, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Tokens.cardCorner, style: .continuous)
          .stroke(
            .white.opacity(borderOpacity),
            lineWidth: contrast == .increased ? 2 : 1)
      }
      .overlay {
        RoundedRectangle(cornerRadius: Tokens.cardCorner, style: .continuous)
          .stroke(Tokens.accent, lineWidth: focused ? 3 : 0)
          .padding(-3)
      }
      .shadow(color: .black.opacity(hovering ? 0.28 : 0), radius: 14, y: 6)
      .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
      .animation(reduceMotion ? nil : Tokens.hover, value: hovering)
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
    GridItem(.adaptive(minimum: Tokens.gridMinimum, maximum: Tokens.gridMaximum),
             spacing: Tokens.gridSpacing)
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text(L("Recently Added"))
          .font(Tokens.sectionTitle)
          .foregroundStyle(Tokens.textPrimary)
        Spacer()
        Button(L("See All"), action: seeAll)
          .buttonStyle(.plain)
          .font(Tokens.caption)
          .foregroundStyle(Tokens.textSecondary)
      }

      LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
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
    GridItem(.adaptive(minimum: Tokens.gridMinimum, maximum: Tokens.gridMaximum),
             spacing: Tokens.gridSpacing)
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          if let onBack {
            Button(action: onBack) {
              Image(systemName: "chevron.left")
                .font(Tokens.sectionTitle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.textSecondary)
            .accessibilityLabel(L("Back"))
          }
          Text(title)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(Tokens.textPrimary)
          Spacer()
          Text("\(items.count)")
            .font(Tokens.caption)
            .foregroundStyle(Tokens.textSecondary)
        }

        if items.isEmpty {
          EmptyStateView(
            symbol: "play.rectangle.on.rectangle",
            title: L("No videos yet"),
            message: emptyMessage,
            actionTitle: L("Open File…")) {
              model.openFilePanel()
            }
          .frame(minHeight: 300)
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(items) { item in
              LibraryCard(item: item) {
                select(item)
              }
            }
          }
        }
      }
      .padding(.horizontal, Tokens.contentPadding)
      .padding(.top, 28)
      .padding(.bottom, 48)
    }
  }
}

private struct LibraryCard: View {
  let item: LibraryItem
  let play: () -> Void

  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @FocusState private var focused: Bool

  private var borderOpacity: Double {
    contrast == .increased ? 0.65 : (hovering ? 0.28 : 0.08)
  }

  var body: some View {
    Button(action: play) {
      VStack(alignment: .leading, spacing: 8) {
        Color.clear
          .aspectRatio(16.0 / 9.0, contentMode: .fit)
          .overlay {
            PosterImage(url: item.url)
          }
          .clipShape(RoundedRectangle(cornerRadius: Tokens.cardCorner, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: Tokens.cardCorner, style: .continuous)
              .stroke(
                .white.opacity(borderOpacity),
                lineWidth: contrast == .increased ? 2 : 1)
          }
          .overlay {
            RoundedRectangle(cornerRadius: Tokens.cardCorner, style: .continuous)
              .stroke(Tokens.accent, lineWidth: focused ? 3 : 0)
              .padding(-3)
          }
          .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: 12, y: 5)

        Text(item.title)
          .font(Tokens.cardTitle)
          .foregroundStyle(Tokens.textPrimary)
          .lineLimit(1)

        Text(item.subtitle)
          .font(Tokens.caption)
          .foregroundStyle(Tokens.textSecondary)
          .lineLimit(1)
      }
      .contentShape(Rectangle())
      .scaleEffect(hovering && !reduceMotion ? 1.015 : 1)
      .animation(reduceMotion ? nil : Tokens.hover, value: hovering)
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
    GridItem(.adaptive(minimum: Tokens.gridMinimum, maximum: Tokens.gridMaximum),
             spacing: Tokens.gridSpacing)
  ]

  var body: some View {
    VStack(spacing: 28) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(Tokens.textSecondary)
        TextField(L("Search"), text: $model.query)
          .textFieldStyle(.plain)
          .font(.system(size: 15))
          .focused($focused)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Tokens.hairline, lineWidth: 1)
      }
      .frame(width: 420)
      .padding(.top, 32)

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
          LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(model.searchResults) { item in
              LibraryCard(item: item) {
                select(item)
              }
            }
          }
          .padding(.horizontal, Tokens.contentPadding)
          .padding(.bottom, 48)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Tokens.canvas)
    .onAppear {
      focused = true
    }
  }
}

// MARK: - Playlists

private struct PlaylistsView: View {
  var body: some View {
    EmptyStateView(
      symbol: "list.bullet.rectangle",
      title: L("No playlists yet"),
      message: L("Playlists you create will appear here."))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Tokens.canvas)
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
      VStack(alignment: .leading, spacing: 24) {
        Button(action: back) {
          Label(L("Back"), systemImage: "chevron.left")
            .font(Tokens.body)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.textSecondary)
        .keyboardShortcut(.cancelAction)

        Color.clear
          .aspectRatio(16.0 / 9.0, contentMode: .fit)
          .overlay {
            ZStack(alignment: .bottomLeading) {
              PosterImage(url: item.url)
              LinearGradient(
                colors: [.clear, .black.opacity(0.15), .black.opacity(0.84)],
                startPoint: .top,
                endPoint: .bottom)
              VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                  .font(Tokens.heroTitle)
                  .lineLimit(2)
                if !item.metadata.detailLine.isEmpty {
                  Text(item.metadata.detailLine)
                    .font(Tokens.heroBody)
                    .foregroundStyle(.white.opacity(0.78))
                }
              }
              .foregroundStyle(.white)
              .padding(28)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: Tokens.heroCorner, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: Tokens.heroCorner, style: .continuous)
              .stroke(
                .white.opacity(contrast == .increased ? 0.5 : 0.08),
                lineWidth: contrast == .increased ? 2 : 1)
          }

        HStack(alignment: .center, spacing: 16) {
          Button(action: play) {
            Label(item.isResumable ? L("Resume") : L("Play"), systemImage: "play.fill")
              .font(Tokens.button)
              .padding(.horizontal, 20)
              .padding(.vertical, 10)
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)

          if item.isResumable {
            VStack(alignment: .leading, spacing: 5) {
              Text(item.progressText)
                .font(Tokens.caption)
                .foregroundStyle(Tokens.textSecondary)
              ProgressView(value: item.progress)
                .tint(Tokens.accent)
                .frame(width: 180)
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

        VStack(alignment: .leading, spacing: 12) {
          Text(L("Details"))
            .font(Tokens.sectionTitle)
            .foregroundStyle(Tokens.textPrimary)

          Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
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
      .padding(.horizontal, Tokens.contentPadding)
      .padding(.top, 24)
      .padding(.bottom, 48)
    }
    .background(Tokens.canvas)
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
        .font(Tokens.caption)
        .foregroundStyle(Tokens.textSecondary)
        .gridColumnAlignment(.trailing)
      Text(value)
        .font(Tokens.body)
        .foregroundStyle(Tokens.textPrimary)
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
        Capsule().fill(.white.opacity(0.26))
        Capsule()
          .fill(.white)
          .frame(width: CGFloat(max(0, min(1, value))) * proxy.size.width)
      }
    }
    .frame(height: 3)
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
      image = await PosterStore.shared.image(for: url)
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
          Color(hue: hue, saturation: 0.42, brightness: 0.34),
          Color(hue: hue, saturation: 0.50, brightness: 0.18)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

      Image(systemName: "play.rectangle.fill")
        .font(.system(size: 34, weight: .regular))
        .foregroundStyle(.white.opacity(0.34))
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
    VStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 42, weight: .light))
        .foregroundStyle(Tokens.textSecondary)
      Text(title)
        .font(Tokens.sectionTitle)
        .foregroundStyle(Tokens.textPrimary)
      Text(message)
        .font(Tokens.body)
        .foregroundStyle(Tokens.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.borderedProminent)
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(24)
  }
}

private struct DropOverlay: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Tokens.accent.opacity(0.12))
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(
          Tokens.accent,
          style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
      VStack(spacing: 8) {
        Image(systemName: "arrow.down.doc")
          .font(.system(size: 30, weight: .regular))
        Text(L("Drop to open"))
          .font(Tokens.sectionTitle)
      }
      .foregroundStyle(Tokens.accent)
    }
    .padding(24)
    .allowsHitTesting(false)
  }
}
