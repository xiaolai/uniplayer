//
//  MediaSourcesView.swift
//  uniplayer
//
//  Native source browsing, source properties, collection contents and the Add
//  Source flow. Browsing is table-first, selection never plays, and every
//  recovery state offers a concrete next action.
//

import AppKit
import Combine
import SwiftUI

private func L(_ key: String) -> String {
  NSLocalizedString(key, comment: "")
}

private func LF(_ key: String, _ arguments: CVarArg...) -> String {
  String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}

// MARK: - Browser

struct SourceBrowserView: View {
  @Environment(\.libraryTextScale) private var textScale
  @ObservedObject var coordinator: SourceCoordinator
  @StateObject private var model: SourceBrowserModel
  let onOpenMedia: (UUID, PlaybackIntent) -> Void
  let onSelectSource: (UUID) -> Void
  let onSourceRemoved: () -> Void
  let onShowProperties: (UUID) -> Void
  let onRelink: (UUID) -> Void
  let onShowInFinder: (URL) -> Void
  let onModelReady: (SourceBrowserModel) -> Void
  let chrome: LibraryChrome

  @State private var showCollectionPicker = false
  @State private var errorMessage: String?
  @State private var now = Date()
  @State private var hostWindow: NSWindow?

  private var state: SourceState {
    coordinator.state(for: model.rootID)
  }

  private var waitingForSource: Bool {
    guard let started = state.activityStartedAt,
          state.activity == .listing || state.activity == .scanning else { return false }
    return now.timeIntervalSince(started) >= 3
  }

  init(rootID: UUID, coordinator: SourceCoordinator, catalog: MediaCatalog,
       chrome: LibraryChrome,
       existingModel: SourceBrowserModel? = nil,
       onOpenMedia: @escaping (UUID, PlaybackIntent) -> Void,
       onSelectSource: @escaping (UUID) -> Void,
       onSourceRemoved: @escaping () -> Void,
       onShowProperties: @escaping (UUID) -> Void,
       onRelink: @escaping (UUID) -> Void,
       onShowInFinder: @escaping (URL) -> Void,
       onModelReady: @escaping (SourceBrowserModel) -> Void = { _ in }) {
    self.coordinator = coordinator
    self.chrome = chrome
    if let existingModel {
      self._model = StateObject(wrappedValue: existingModel)
    } else {
      self._model = StateObject(wrappedValue: SourceBrowserModel(
        rootID: rootID, coordinator: coordinator, catalog: catalog))
    }
    self.onOpenMedia = onOpenMedia
    self.onSelectSource = onSelectSource
    self.onSourceRemoved = onSourceRemoved
    self.onShowProperties = onShowProperties
    self.onRelink = onRelink
    self.onShowInFinder = onShowInFinder
    self.onModelReady = onModelReady
  }

  var body: some View {
    VStack(spacing: Tokens.Space.n0) {
      header
        .padding(.horizontal, Tokens.Space.n20)
        .padding(.top, Tokens.Library.titlebarHeight)
        .padding(.bottom, Tokens.Space.n8)
      scopeBar
        .padding(.horizontal, Tokens.Space.n20)
        .padding(.bottom, Tokens.Space.n8)
      banners
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      footer
        .padding(.horizontal, Tokens.Space.n20)
        .padding(.vertical, Tokens.Space.n8)
    }
    .background(Tokens.Palette.canvas.color)
    .background(SourceWindowReader { hostWindow = $0 })
    .task { await model.loadInitial() }
    .onAppear {
      model.openMedia = onOpenMedia
      onModelReady(model)
      updateChromeNavigation()
    }
    .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    .onReceive(NotificationCenter.default.publisher(for: .mediaSourcesGoUpRequested)) { note in
      guard let window = note.object as? NSWindow, window === hostWindow else { return }
      Task { await model.goUp() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .mediaSourcesOpenSelectionRequested)) { note in
      guard let window = note.object as? NSWindow, window === hostWindow else { return }
      if let row = model.rows.first(where: { model.selectedIDs.contains($0.id) }) {
        model.activate(row)
      }
    }
    .sheet(isPresented: $showCollectionPicker) {
      CollectionPickerSheet(
        collections: coordinator.collections,
        onCreate: { name in try? await coordinator.createCollection(name: name) },
        onPick: { collectionID in
          Task {
            await model.addSelected(to: collectionID)
            showCollectionPicker = false
          }
        })
    }
    .alert(L("Source Error"), isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } })) {
      Button(L("OK")) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .alert(L("Action Failed"), isPresented: Binding(
      get: { model.actionError != nil },
      set: { if !$0 { model.actionError = nil } })) {
      Button(L("OK")) { model.actionError = nil }
    } message: {
      Text(model.actionError ?? "")
    }
    .onChange(of: coordinator.roots) { _, _ in
      // A rename or removal from properties is reflected without leaving the
      // browser.
      if coordinator.root(id: model.rootID) == nil {
        onSourceRemoved()
      }
    }
    .onAppear { updateChromeNavigation() }
    .onChange(of: model.canGoBack) { _, _ in updateChromeNavigation() }
    .onChange(of: model.canGoForward) { _, _ in updateChromeNavigation() }
  }

  private var header: some View {
    HStack(spacing: Tokens.Space.n8) {
      Button {
        Task { await model.goBack() }
      } label: {
        Image(systemName: "chevron.left")
          .frame(width: Tokens.Size.n30, height: Tokens.Size.n30)
      }
      .buttonStyle(.plain)
      .disabled(!model.canGoBack)
      .help(L("Back"))
      .accessibilityLabel(L("Back"))

      Button {
        Task { await model.goForward() }
      } label: {
        Image(systemName: "chevron.right")
          .frame(width: Tokens.Size.n30, height: Tokens.Size.n30)
      }
      .buttonStyle(.plain)
      .disabled(!model.canGoForward)
      .help(L("Forward"))
      .accessibilityLabel(L("Forward"))

      breadcrumbs
      Spacer(minLength: Tokens.Space.n8)

      if model.loading {
        ProgressView().controlSize(.small)
          .frame(width: Tokens.Size.n20, height: Tokens.Size.n20)
          .accessibilityLabel(L("Loading Folder"))
      }
      if coordinator.state(for: model.rootID).activity == .scanning {
        Button(L("Cancel Scan")) {
          coordinator.cancel(rootID: model.rootID)
        }
        .buttonStyle(.borderless)
      }

      Toggle(isOn: $model.showGrid) {
        Image(systemName: model.showGrid ? "list.bullet" : "square.grid.2x2")
      }
      .toggleStyle(.button)
      .help(model.showGrid ? L("List View") : L("Grid View"))
      .accessibilityLabel(model.showGrid ? L("List View") : L("Grid View"))

      Menu {
        Button(L("Add Folder…")) { addSource() }
        Button(L("Refresh")) { Task { await model.refresh() } }
        Divider()
        if let root = model.root {
          Button(L("Source Settings…")) { onShowProperties(root.id) }
          Button(L("Remove Source…"), role: .destructive) {
            confirmRemoveSource(root)
          }
        }
      } label: {
        Image(systemName: "plus")
          .frame(width: Tokens.Size.n30, height: Tokens.Size.n30)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .help(L("Source Actions"))
      .accessibilityLabel(L("Source Actions"))
    }
  }

  private var breadcrumbs: some View {
    HStack(spacing: Tokens.Space.n4) {
      ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { index, crumb in
        if index > 0 {
          Image(systemName: "chevron.compact.right")
            .font(Tokens.Typography.caption.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textTertiary.color)
            .accessibilityHidden(true)
        }
        Button(crumb.title) {
          Task { await model.navigate(toBreadcrumb: crumb.path) }
        }
        .buttonStyle(.plain)
        .font(index == model.breadcrumbs.count - 1
              ? Tokens.Typography.bodyStrong.scaledFont(textScale)
              : Tokens.Typography.body.scaledFont(textScale))
        .foregroundStyle(index == model.breadcrumbs.count - 1
                         ? Tokens.Palette.textPrimary.color
                         : Tokens.Palette.textSecondary.color)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(crumb.title)
      }
    }
  }

  private var scopeBar: some View {
    HStack(spacing: Tokens.Space.n12) {
      NativeLibrarySearchField(
        query: $model.query,
        placeholder: searchPlaceholder,
        accessibilityLabel: L("Search Source"))
        .frame(maxWidth: Tokens.Size.searchFieldWidth)
        .frame(height: Tokens.Size.n30)
      Picker(L("Search Scope"), selection: $model.scope) {
        Text(L("This Folder")).tag(SourceSearchScope.thisFolder)
        Text(L("All Library")).tag(SourceSearchScope.allLibrary)
        if model.inclusion == .indexed {
          Text(L("Indexed Folders")).tag(SourceSearchScope.indexedFolder)
        }
      }
      .pickerStyle(.menu)
      .fixedSize()
      .help(L("Choose what the search covers"))
      if model.searchLoading {
        ProgressView().controlSize(.small)
      }
      Spacer(minLength: Tokens.Space.n0)
    }
  }

  private var searchPlaceholder: String {
    switch model.scope {
    case .thisFolder: return L("Search This Folder")
    case .allLibrary: return L("Search All Library")
    case .indexedFolder: return L("Search Indexed Folders")
    }
  }

  @ViewBuilder
  private var banners: some View {
    if waitingForSource {
      banner {
        Label(LF("Waiting for %@…", model.root?.displayName ?? L("Source")),
              systemImage: "clock")
        Spacer()
        Button(L("Cancel")) {
          coordinator.cancel(rootID: model.rootID)
        }
      }
    } else if let review = model.pendingReview {
      banner {
        Label(LF("Review %d missing items before hiding them.", review.missingCount),
              systemImage: "exclamationmark.triangle")
        Spacer()
        Button(L("Review Changes")) {
          Task {
            if let message = await model.applyReview() { errorMessage = message }
          }
        }
        Button(L("Keep Items")) { Task { await model.dismissReview() } }
      }
    } else if model.isStale {
      banner {
        Label(L("Only saved items are shown. Refresh to reconnect."),
              systemImage: "internaldrive")
        Spacer()
        Button(L("Refresh")) { Task { await model.refresh() } }
      }
    }
  }

  private func banner<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: Tokens.Space.n12, content: content)
      .font(Tokens.Typography.caption.scaledFont(textScale))
      .padding(.horizontal, Tokens.Space.n20)
      .padding(.vertical, Tokens.Space.n8)
      .background(Tokens.Palette.surface.color)
      .overlay(alignment: .bottom) {
        Divider()
      }
  }

  @ViewBuilder
  private var content: some View {
    if model.loading && model.snapshot == nil {
      LibraryLoadingState()
    } else if let error = model.error, model.snapshot == nil {
      errorState(error)
    } else if model.rows.isEmpty {
      emptyState
    } else if model.showGrid {
      grid
    } else {
      table
    }
  }

  private var table: some View {
    Table(model.rows, selection: $model.selectedIDs) {
      TableColumn(L("Name")) { row in
        HStack(spacing: Tokens.Space.n8) {
          Image(systemName: row.isDirectory ? "folder" : (row.isFavorite ? "star.fill" : "play.rectangle"))
            .font(Tokens.Typography.body.scaledFont(textScale))
            .foregroundStyle(row.isFavorite
                             ? Tokens.Palette.systemOrange.color
                             : Tokens.Palette.textSecondary.color)
            .frame(width: Tokens.Icon.n16)
            .accessibilityHidden(true)
          Text(row.name)
            .font(Tokens.Typography.body.scaledFont(textScale))
            .lineLimit(1)
            .truncationMode(.middle)
          if row.presence == .missing {
            Text(L("Missing"))
              .font(Tokens.Typography.badge.scaledFont(textScale))
              .foregroundStyle(Tokens.Palette.textSecondary.color)
          }
          Spacer(minLength: Tokens.Space.n0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.activate(row) }
        .contextMenu { rowActions(row) }
        .help(row.name)
      }
      TableColumn(L("Size")) { row in
        Text(row.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
          .font(Tokens.Typography.numeric.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textSecondary.color)
      }
      .width(min: Tokens.Size.n64, ideal: Tokens.Size.n100, max: Tokens.Size.n140)
      TableColumn(L("Modified")) { row in
        Text(row.modified?.formatted(date: .abbreviated, time: .shortened) ?? "")
          .font(Tokens.Typography.numeric.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textSecondary.color)
      }
      .width(min: Tokens.Size.n120, ideal: Tokens.Size.n180, max: Tokens.Size.n220)
      TableColumn(L("Duration")) { row in
        Text(row.duration.map { VideoTime($0).stringRepresentation } ?? "")
          .font(Tokens.Typography.numeric.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textSecondary.color)
      }
      .width(min: Tokens.Size.n64, ideal: Tokens.Size.n80, max: Tokens.Size.n100)
    }
    .tableStyle(.inset(alternatesRowBackgrounds: true))
    .scrollPosition(id: $model.scrollRowID)
    .onKeyPress(.return) {
      if let row = model.rows.first(where: { model.selectedIDs.contains($0.id) }) {
        model.activate(row)
        return .handled
      }
      return .ignored
    }
  }

  private var grid: some View {
    ScrollView {
      LazyVGrid(columns: [
        GridItem(.adaptive(minimum: Tokens.Size.gridMinimum,
                           maximum: Tokens.Size.gridMaximum),
                 spacing: Tokens.Library.cardGap)
      ], alignment: .leading, spacing: Tokens.Library.gridRowGap) {
        ForEach(model.rows) { row in
          SourceGridCard(
            row: row,
            selected: model.selectedIDs.contains(row.id),
            textScale: textScale,
            select: { model.select(row) },
            activate: { model.activate(row) })
            .contextMenu { rowActions(row) }
        }
      }
      .padding(.horizontal, Tokens.Space.pageMargin)
      .padding(.vertical, Tokens.Space.n16)
    }
  }

  @ViewBuilder
  private func rowActions(_ row: SourceBrowserRow) -> some View {
    if row.isDirectory {
      Button(L("Open Folder")) { model.activate(row) }
      Divider()
    } else {
      Button(L("Play")) { model.select(row); model.play(row, intent: .ordinaryOpen) }
      Button(L("Resume")) { model.select(row); model.play(row, intent: .resume) }
      Button(L("Play from Beginning")) { model.select(row); model.play(row, intent: .fromBeginning) }
      Divider()
      Button(row.isFinished ? L("Mark Unwatched") : L("Mark Watched")) {
        model.select(row)
        Task { await model.markWatched(!row.isFinished) }
      }
      Button(row.isFavorite ? L("Remove from Favorites") : L("Add to Favorites")) {
        model.select(row)
        Task { await model.toggleFavorite() }
      }
      Button(L("Add to Collection…")) {
        model.select(row)
        showCollectionPicker = true
      }
      Button(row.isHidden ? L("Show in Library") : L("Hide from Library")) {
        model.select(row)
        Task { await model.setHidden(!row.isHidden) }
      }
      if let url = row.resolvedURL, url.isFileURL {
        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
      Divider()
      Button(L("Relink…")) { onRelink(row.id) }
      if let root = model.root {
        Button(L("Source Settings…")) { onShowProperties(root.id) }
      }
    }
  }

  private var footer: some View {
    HStack(spacing: Tokens.Space.n8) {
      Text(LF("%d items", model.rows.count))
        .font(Tokens.Typography.caption.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textSecondary.color)
      Text("·")
        .foregroundStyle(Tokens.Palette.textTertiary.color)
      Text(model.inclusion == .indexed ? L("Include in Library") : L("Browse Only"))
        .font(Tokens.Typography.caption.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textSecondary.color)
      Spacer()
      if model.organization.canUndo {
        Button(L("Undo")) {
          Task {
            if let message = await model.undo() { errorMessage = message }
          }
        }
        .help(model.organization.undoTitle ?? L("Undo"))
      }
      if let root = model.root {
        Button(model.inclusion == .indexed ? L("Browse Only") : L("Include in Library")) {
          Task {
            await model.setInclusion(model.inclusion == .indexed ? .browseOnly : .indexed)
          }
        }
        .buttonStyle(.bordered)
        .disabled(root.isDetached)
      }
    }
  }

  private var emptyState: some View {
    VStack {
      if model.query.isEmpty {
        EmptyStateView(
          symbol: "folder",
          title: L("No Videos in This Folder"),
          message: model.isStale
            ? L("Only saved items are shown. Refresh to reconnect.")
            : L("This folder has no videos. Browse its parent or add another source."),
          actionTitle: model.canGoUp ? L("Browse Parent") : L("Add Folder…")) {
            if model.canGoUp {
              Task { await model.goUp() }
            } else {
              addSource()
            }
          }
      } else {
        EmptyStateView(
          symbol: "magnifyingglass",
          title: L("No Matches in This Folder"),
          message: L("Try All Library, which includes indexed and organized items."),
          actionTitle: L("Search All Library")) {
            model.scope = .allLibrary
            model.query = model.query
          }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func errorState(_ error: MediaSourceError) -> some View {
    let retryBlocked = state.lastError == .timedOut || state.lastError == .quarantined
    return EmptyStateView(
      symbol: error == .accessDenied ? "lock" : "externaldrive",
      title: L("Source Unavailable"),
      message: retryBlocked
        ? L("A previous request is still waiting for this source. Retry is unavailable until it finishes.")
        : error.userMessage,
      actionTitle: retryBlocked ? nil : L("Reconnect")) {
        if !retryBlocked {
          Task { await model.reconnect() }
        }
      }
      .overlay(alignment: .bottom) {
        HStack(spacing: Tokens.Space.n8) {
          if let root = model.root {
            Button(L("Source Settings…")) { onShowProperties(root.id) }
          }
          Button(L("Add Folder…")) { addSource() }
        }
        .padding(.bottom, Tokens.Space.n24)
      }
  }

  private func addSource() {
    AddSourceSupport.present(
      coordinator: coordinator,
      window: NSApp.keyWindow,
      onCreated: { root in
        onSelectSource(root.id)
      },
      onError: { message in errorMessage = message })
  }

  private func updateChromeNavigation() {
    chrome.canNavigateBack = model.canGoBack
    chrome.canNavigateForward = model.canGoForward
    chrome.navigateBack = { Task { await model.goBack() } }
    chrome.navigateForward = { Task { await model.goForward() } }
  }

  private func confirmRemoveSource(_ root: MediaSourceRoot) {
    let alert = NSAlert()
    alert.messageText = L("Remove Source?")
    alert.informativeText = LF("“%@” will no longer be browsed. Media files are kept, and items you played or organized remain available to relink.", root.displayName)
    alert.addButton(withTitle: L("Remove Source"))
    alert.addButton(withTitle: L("Cancel"))
    alert.alertStyle = .warning
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task {
      do {
        try await model.removeSource()
        onSourceRemoved()
      } catch {
        errorMessage = (error as? MediaSourceError)?.userMessage
          ?? String(describing: error)
      }
    }
  }
}

// MARK: - Catalog-backed Library views

struct CatalogLibraryView: View {
  @Environment(\.libraryTextScale) private var textScale
  let catalog: MediaCatalog
  let title: String
  let onOpenMedia: (UUID, PlaybackIntent) -> Void

  @State private var media: [CatalogMedia] = []
  @State private var loading = true
  @State private var loadError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.n20) {
        HStack {
          Text(title)
            .font(Tokens.Typography.pageTitle.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textPrimary.color)
          Spacer()
          Text(LF("%d items", media.count))
            .font(Tokens.Typography.caption.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textSecondary.color)
        }
        if let loadError {
          CatalogLoadBanner(message: loadError) { Task { await reload() } }
        }
        if loading {
          LibraryLoadingState()
        } else if media.isEmpty {
          if loadError == nil {
            EmptyStateView(
              symbol: "play.rectangle.on.rectangle",
              title: L("No Videos Yet"),
              message: L("Add a source and include it in Library, or open a video."))
              .frame(minHeight: Tokens.Library.emptyStateMinimum)
          }
        } else {
          LazyVGrid(columns: [
            GridItem(.adaptive(minimum: Tokens.Size.gridMinimum,
                               maximum: Tokens.Size.gridMaximum),
                     spacing: Tokens.Library.cardGap)
          ], alignment: .leading, spacing: Tokens.Library.gridRowGap) {
            ForEach(media) { item in
              SourceMediaCard(item: item, textScale: textScale) {
                onOpenMedia(item.id, .ordinaryOpen)
              }
            }
          }
        }
      }
      .padding(.horizontal, Tokens.Space.pageMargin)
      .padding(.top, Tokens.Space.pageTop)
      .padding(.bottom, Tokens.Space.pageBottom)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Tokens.Palette.canvas.color)
    .task { await reload() }
    .onReceive(NotificationCenter.default.publisher(for: .mediaCatalogDidChange)) { _ in
      Task { await reload() }
    }
  }

  private func reload() async {
    do {
      media = try await catalog.libraryMedia()
      loadError = nil
    } catch {
      loadError = (error as? MediaSourceError)?.userMessage
        ?? String(describing: error)
    }
    loading = false
  }
}

struct CatalogSearchView: View {
  @Environment(\.libraryTextScale) private var textScale
  let catalog: MediaCatalog
  let onOpenMedia: (UUID, PlaybackIntent) -> Void

  @State private var query = ""
  @State private var results: [CatalogMedia] = []
  @State private var loading = false
  @State private var searchError: String?
  @State private var searchTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: Tokens.Space.n20) {
      NativeLibrarySearchField(
        query: $query,
        placeholder: L("Search titles and folders"),
        accessibilityLabel: L("Search Library"))
        .frame(maxWidth: Tokens.Size.searchFieldWidth)
        .frame(height: Tokens.Size.n30)
        .padding(.horizontal, Tokens.Space.n16)
        .padding(.top, Tokens.Library.searchTop)
      if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        EmptyStateView(
          symbol: "magnifyingglass",
          title: L("Search"),
          message: L("Find a video by its title or folder."))
          .frame(maxHeight: .infinity)
      } else if loading {
        LibraryLoadingState()
      } else if let searchError {
        CatalogLoadBanner(message: searchError) { scheduleSearch(query) }
          .padding(.horizontal, Tokens.Space.pageMargin)
      } else if results.isEmpty {
        EmptyStateView(
          symbol: "magnifyingglass",
          title: L("No Results"),
          message: LF("Nothing matches “%@”.", query),
          actionTitle: L("Clear Search")) { query = "" }
          .frame(maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVGrid(columns: [
            GridItem(.adaptive(minimum: Tokens.Size.gridMinimum,
                               maximum: Tokens.Size.gridMaximum),
                     spacing: Tokens.Library.cardGap)
          ], alignment: .leading, spacing: Tokens.Library.gridRowGap) {
            ForEach(results) { item in
              SourceMediaCard(item: item, textScale: textScale) {
                onOpenMedia(item.id, .ordinaryOpen)
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
    .onChange(of: query) { _, value in scheduleSearch(value) }
    .onDisappear { searchTask?.cancel() }
  }

  private func scheduleSearch(_ value: String) {
    searchTask?.cancel()
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      results = []
      loading = false
      return
    }
    searchTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled else { return }
      loading = true
      do {
        let found = try await catalog.search(term: trimmed, scope: .allLibrary)
        guard !Task.isCancelled else { return }
        results = found
        searchError = nil
      } catch {
        guard !Task.isCancelled else { return }
        results = []
        searchError = (error as? MediaSourceError)?.userMessage
          ?? String(describing: error)
      }
      loading = false
    }
  }
}

// MARK: - Favorites

struct FavoritesView: View {
  @Environment(\.libraryTextScale) private var textScale
  let catalog: MediaCatalog
  let onOpenMedia: (UUID, PlaybackIntent) -> Void

  @State private var media: [CatalogMedia] = []
  @State private var loading = true
  @State private var loadError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.n20) {
        Text(L("Favorites"))
          .font(Tokens.Typography.pageTitle.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textPrimary.color)
        if let loadError {
          CatalogLoadBanner(message: loadError) { Task { await reload() } }
        }
        if loading {
          LibraryLoadingState()
        } else if media.isEmpty {
          if loadError == nil {
            EmptyStateView(
              symbol: "star",
              title: L("No Favorites Yet"),
              message: L("Add a favorite from a source browser or an item’s details."))
              .frame(minHeight: Tokens.Library.emptyStateMinimum)
          }
        } else {
          LazyVGrid(columns: [
            GridItem(.adaptive(minimum: Tokens.Size.gridMinimum,
                               maximum: Tokens.Size.gridMaximum),
                     spacing: Tokens.Library.cardGap)
          ], alignment: .leading, spacing: Tokens.Library.gridRowGap) {
            ForEach(media) { item in
              SourceMediaCard(item: item, textScale: textScale) {
                onOpenMedia(item.id, .ordinaryOpen)
              }
            }
          }
        }
      }
      .padding(.horizontal, Tokens.Space.pageMargin)
      .padding(.top, Tokens.Space.pageTop)
      .padding(.bottom, Tokens.Space.pageBottom)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Tokens.Palette.canvas.color)
    .task { await reload() }
    .onReceive(NotificationCenter.default.publisher(for: .mediaCatalogDidChange)) { _ in
      Task { await reload() }
    }
  }

  private func reload() async {
    do {
      media = try await catalog.search(term: "", scope: .allLibrary,
                                       filter: .favorites)
      loadError = nil
    } catch {
      loadError = (error as? MediaSourceError)?.userMessage
        ?? String(describing: error)
    }
    loading = false
  }
}

// MARK: - Grid card

private struct SourceGridCard: View {
  let row: SourceBrowserRow
  let selected: Bool
  let textScale: Double
  let select: () -> Void
  let activate: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Library.cardSpacing) {
      Tokens.Palette.clear.color
        .aspectRatio(Tokens.Aspect.video, contentMode: .fit)
        .overlay {
          ZStack {
            Tokens.Palette.surface.color
            Image(systemName: row.isDirectory ? "folder.fill" : (row.isFavorite ? "star.fill" : "play.rectangle.fill"))
              .font(.system(size: Tokens.Library.placeholderGlyph, weight: .regular))
              .foregroundStyle(row.isFavorite
                               ? Tokens.Palette.systemOrange.color
                               : Tokens.Palette.textTertiary.color)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
            .stroke(selected ? Tokens.Palette.accent.color : Tokens.Palette.separator.color,
                    lineWidth: selected ? Tokens.Stroke.strong : Tokens.Stroke.hairline)
        }
      Text(row.name)
        .font(Tokens.Typography.cardTitle.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textPrimary.color)
        .lineLimit(1)
        .truncationMode(.middle)
      Text(row.presence == .missing ? L("Missing") : (row.isDirectory ? L("Folder") : rowType))
        .font(Tokens.Typography.caption.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textSecondary.color)
        .lineLimit(1)
    }
    .contentShape(Rectangle())
    .onTapGesture { select() }
    .simultaneousGesture(TapGesture(count: 2).onEnded { activate() })
    .accessibilityElement(children: .combine)
    .accessibilityLabel(row.name)
    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    .focusable()
    .onKeyPress(.return) {
      activate()
      return .handled
    }
  }

  private var rowType: String {
    guard let duration = row.duration else { return L("Video") }
    return VideoTime(duration).stringRepresentation
  }
}

// MARK: - Add Source

@MainActor
enum AddSourceSupport {
  static func present(coordinator: SourceCoordinator, window: NSWindow?,
                      onCreated: @escaping (MediaSourceRoot) -> Void,
                      onError: @escaping (String) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.resolvesAliases = true
    panel.message = L("Choose a folder to browse. Mounted network shares are selected the same way.")
    panel.prompt = L("Add Source")
    let handler: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK else { return }
      let urls = panel.urls
      Task { @MainActor in
        var selectedRoot: MediaSourceRoot?
        for url in urls {
          do {
            var outcome = try await coordinator.addRoot(at: url)
            if case .possibleAlias(let existing) = outcome {
              guard confirmPossibleAlias(existing: existing, url: url) else { continue }
              outcome = try await coordinator.addRoot(
                at: url, allowPossibleAliasDuplicate: true)
            }
            switch outcome {
            case .created(let root):
              if selectedRoot == nil { selectedRoot = root }
            case .overlap(let root) where root.isDetached:
              var confirmed = false
              alert(title: L("Restore Existing Source?"),
                    message: LF("“%@” overlaps this folder and still has saved items. Restoring it reuses its identity.", root.displayName),
                    primary: L("Restore")) { confirmed = true }
              if confirmed, let restored = try? await coordinator.restore(root),
                 selectedRoot == nil {
                selectedRoot = restored
              }
            case .existing(let root), .overlap(let root), .possibleAlias(let root):
              alert(title: L("Source Already Exists"),
                    message: LF("“%@” is already a source.", root.displayName),
                    primary: L("Open Existing Source")) {
                if selectedRoot == nil { selectedRoot = root }
              }
            case .restore(let root):
              var confirmed = false
              alert(title: L("Restore Source?"),
                    message: LF("Restore “%@” and keep its saved items?", root.displayName),
                    primary: L("Restore")) { confirmed = true }
              if confirmed, let restored = try? await coordinator.restore(root),
                 selectedRoot == nil {
                selectedRoot = restored
              }
            }
          } catch {
            onError((error as? MediaSourceError)?.userMessage ?? String(describing: error))
          }
        }
        if let selectedRoot { onCreated(selectedRoot) }
      }
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: handler)
    } else {
      panel.begin(completionHandler: handler)
    }
  }

  private static func confirmPossibleAlias(existing: MediaSourceRoot, url: URL) -> Bool {
    let alert = NSAlert()
    alert.messageText = L("This May Be the Same Source")
    alert.informativeText = LF("“%@” already points at this server and folder under another volume identity. Adding it again keeps two independent sources.", existing.displayName)
    alert.addButton(withTitle: L("Add Anyway"))
    alert.addButton(withTitle: L("Choose Another Folder"))
    return alert.runModal() == .alertFirstButtonReturn
  }

  private static func alert(title: String, message: String, primary: String,
                            action: @escaping () -> Void) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: primary)
    alert.addButton(withTitle: L("Cancel"))
    if alert.runModal() == .alertFirstButtonReturn { action() }
  }
}

// MARK: - Source properties

struct SourcePropertiesView: View {
  @Environment(\.libraryTextScale) private var textScale
  @ObservedObject var coordinator: SourceCoordinator
  let rootID: UUID
  let onBack: () -> Void
  let onShowInFinder: (URL) -> Void

  @State private var name = ""
  @State private var inclusion: SourceInclusion = .browseOnly
  @State private var pendingReview: AbsenceReview?
  @State private var errorMessage: String?

  private var root: MediaSourceRoot? { coordinator.root(id: rootID) }
  private var state: SourceState { coordinator.state(for: rootID) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.n20) {
        Button(action: onBack) {
          Label(L("Back"), systemImage: "chevron.left")
            .font(Tokens.Typography.body.scaledFont(textScale))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.Palette.textSecondary.color)
        .accessibilityLabel(L("Back"))

        if let root {
          Text(root.displayName)
            .font(Tokens.Typography.pageTitle.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textPrimary.color)
          Form {
            Section(L("Source")) {
              TextField(L("Name"), text: $name)
              LabeledContent(L("Type"), value: kindLabel(root.kind))
              LabeledContent(L("Location"), value: root.resolvedURL?.path ?? L("Offline"))
              Picker(L("Library"), selection: $inclusion) {
                Text(L("Browse Only")).tag(SourceInclusion.browseOnly)
                Text(L("Include in Library")).tag(SourceInclusion.indexed)
              }
              if let last = root.lastSuccessfulUpdate {
                LabeledContent(L("Last Updated"), value: last.formatted(date: .abbreviated, time: .shortened))
              }
            }
            Section(L("Status")) {
              LabeledContent(L("Connection"), value: connectivityLabel(state.connectivity))
              LabeledContent(L("Activity"), value: activityLabel(state.activity))
              if let error = state.lastError {
                LabeledContent(L("Last Error"), value: error.userMessage)
              }
              if let review = pendingReview {
                VStack(alignment: .leading, spacing: Tokens.Space.n8) {
                  Text(LF("%d items may be missing.", review.missingCount))
                    .font(Tokens.Typography.body.scaledFont(textScale))
                  HStack(spacing: Tokens.Space.n8) {
                    Button(L("Review Changes")) {
                      Task {
                        do {
                          try await coordinator.applyReview(review)
                          pendingReview = nil
                        } catch {
                          errorMessage = (error as? MediaSourceError)?.userMessage
                            ?? String(describing: error)
                        }
                      }
                    }
                    Button(L("Keep Items")) {
                      Task {
                        await coordinator.dismissReview(rootID: rootID)
                        pendingReview = nil
                      }
                    }
                  }
                }
              }
            }
            Section {
              HStack(spacing: Tokens.Space.n8) {
                Button(L("Save Changes")) {
                  Task {
                    do {
                      try await coordinator.rename(root, to: name)
                      if let updated = coordinator.root(id: rootID) {
                        try await coordinator.setInclusion(inclusion, for: updated)
                      }
                    } catch {
                      errorMessage = (error as? MediaSourceError)?.userMessage
                        ?? String(describing: error)
                    }
                  }
                }
                .buttonStyle(.borderedProminent)
                Button(L("Refresh")) {
                  Task {
                    do {
                      _ = try await coordinator.scan(rootID: rootID)
                      pendingReview = try? await coordinator.pendingReview(rootID: rootID)
                    } catch {
                      errorMessage = (error as? MediaSourceError)?.userMessage
                        ?? String(describing: error)
                    }
                  }
                }
                if let url = root.resolvedURL, url.isFileURL {
                  Button(L("Show in Finder")) { onShowInFinder(url) }
                }
              }
              Button(L("Remove Source…"), role: .destructive) {
                confirmRemove(root)
              }
            }
          }
          .formStyle(.grouped)
          .frame(maxWidth: Tokens.Size.n600)
        } else {
          EmptyStateView(
            symbol: "externaldrive",
            title: L("Source Not Found"),
            message: L("This source may have been removed."),
            actionTitle: L("Back")) { onBack() }
            .frame(maxHeight: .infinity)
        }
      }
      .padding(.horizontal, Tokens.Space.pageMargin)
      .padding(.top, Tokens.Space.pageTop)
      .padding(.bottom, Tokens.Space.pageBottom)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Tokens.Palette.canvas.color)
    .task(id: rootID) {
      // Keyed by source: switching properties views must reload the form, or
      // Save would apply the previous source's name and inclusion here.
      guard let root else { return }
      name = root.displayName
      inclusion = root.inclusion
      pendingReview = try? await coordinator.pendingReview(rootID: rootID)
    }
    .alert(L("Source Error"), isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } })) {
      Button(L("OK")) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func confirmRemove(_ root: MediaSourceRoot) {
    let alert = NSAlert()
    alert.messageText = L("Remove Source?")
    alert.informativeText = LF("“%@” will no longer be browsed. Media files are kept, and items you played or organized remain available to relink.", root.displayName)
    alert.addButton(withTitle: L("Remove Source"))
    alert.addButton(withTitle: L("Cancel"))
    alert.alertStyle = .warning
    if alert.runModal() == .alertFirstButtonReturn {
      Task {
        do {
          try await coordinator.remove(root)
          onBack()
        } catch {
          errorMessage = (error as? MediaSourceError)?.userMessage
            ?? String(describing: error)
        }
      }
    }
  }

  private func kindLabel(_ kind: MediaSourceKind) -> String {
    switch kind {
    case .local: return L("Local Folder or Disk")
    case .mountedSMB: return L("Mounted Network Share")
    }
  }

  private func connectivityLabel(_ connectivity: SourceConnectivity) -> String {
    switch connectivity {
    case .unknown: return L("Unknown")
    case .connecting: return L("Connecting")
    case .online: return L("Online")
    case .offline: return L("Offline")
    case .authenticationRequired: return L("Sign In Required")
    case .accessDenied: return L("Access Denied")
    }
  }

  private func activityLabel(_ activity: SourceActivity) -> String {
    switch activity {
    case .idle: return L("Idle")
    case .listing: return L("Listing")
    case .scanning: return L("Scanning")
    case .paused: return L("Paused")
    case .attention: return L("Needs Attention")
    }
  }
}

// MARK: - Collections

struct CollectionDetailView: View {
  @Environment(\.libraryTextScale) private var textScale
  let collection: MediaCollection
  let catalog: MediaCatalog
  let coordinator: SourceCoordinator
  let onOpenMedia: (UUID, PlaybackIntent) -> Void
  let onBack: () -> Void

  @State private var media: [CatalogMedia] = []
  @State private var loading = true
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.n20) {
        HStack(spacing: Tokens.Space.n10) {
          Button(action: onBack) {
            Image(systemName: "chevron.left")
              .frame(width: Tokens.Size.n30, height: Tokens.Size.n30)
          }
          .buttonStyle(.plain)
          .foregroundStyle(Tokens.Palette.textSecondary.color)
          .accessibilityLabel(L("Back"))
          Text(collection.name)
            .font(Tokens.Typography.pageTitle.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textPrimary.color)
          Spacer()
          Text(LF("%d items", media.count))
            .font(Tokens.Typography.caption.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textSecondary.color)
        }
        if let errorMessage {
          CatalogLoadBanner(message: errorMessage) { Task { await reload() } }
        }
        if loading {
          LibraryLoadingState()
        } else if media.isEmpty {
          if errorMessage == nil {
            EmptyStateView(
              symbol: "rectangle.stack",
              title: L("Empty Collection"),
              message: L("Add videos from a source browser or from their details."))
              .frame(minHeight: Tokens.Library.emptyStateMinimum)
          }
        } else {
          LazyVGrid(columns: [
            GridItem(.adaptive(minimum: Tokens.Size.gridMinimum,
                               maximum: Tokens.Size.gridMaximum),
                     spacing: Tokens.Library.cardGap)
          ], alignment: .leading, spacing: Tokens.Library.gridRowGap) {
            ForEach(media) { item in
              SourceMediaCard(item: item, textScale: textScale) {
                onOpenMedia(item.id, .ordinaryOpen)
              }
              .contextMenu {
                Button(L("Remove from Collection")) {
                  Task {
                    do {
                      try await catalog.removeFromCollection(
                        collectionID: collection.id, mediaIDs: [item.id])
                      media.removeAll { $0.id == item.id }
                    } catch {
                      errorMessage = (error as? MediaSourceError)?.userMessage
                        ?? String(describing: error)
                    }
                  }
                }
              }
            }
          }
        }
      }
      .padding(.horizontal, Tokens.Space.pageMargin)
      .padding(.top, Tokens.Space.pageTop)
      .padding(.bottom, Tokens.Space.pageBottom)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Tokens.Palette.canvas.color)
    .task(id: collection.id) {
      media = []
      loading = true
      await reload()
    }
    .onReceive(NotificationCenter.default.publisher(for: .mediaCatalogDidChange)) { _ in
      Task { await reload() }
    }
    .alert(L("Collection Error"), isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } })) {
      Button(L("OK")) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func reload() async {
    do {
      let ids = try await catalog.collectionMediaIDs(id: collection.id)
      media = try await catalog.media(ids: ids)
      errorMessage = nil
    } catch {
      errorMessage = (error as? MediaSourceError)?.userMessage
        ?? String(describing: error)
    }
    loading = false
  }
}

struct SourceMediaCard: View {
  let item: CatalogMedia
  let textScale: Double
  let activate: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Library.cardSpacing) {
      Tokens.Palette.clear.color
        .aspectRatio(Tokens.Aspect.video, contentMode: .fit)
        .overlay {
          if MediaArtworkPolicy.shouldLoadArtwork(for: item), let url = item.url {
            PosterImage(url: url)
          } else {
            ZStack {
              Tokens.Palette.surface.color
              Image(systemName: item.reasons.contains(.favorite)
                    ? "star.fill" : "play.rectangle.fill")
                .font(.system(size: Tokens.Library.placeholderGlyph, weight: .regular))
                .foregroundStyle(Tokens.Palette.textTertiary.color)
            }
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
            .stroke(Tokens.Palette.separator.color, lineWidth: Tokens.Stroke.hairline)
        }
      Text(item.name)
        .font(Tokens.Typography.cardTitle.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textPrimary.color)
        .lineLimit(1)
        .truncationMode(.middle)
      Text(item.rootDisplayName ?? L("Library"))
        .font(Tokens.Typography.caption.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textSecondary.color)
        .lineLimit(1)
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { activate() }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.name)
    .accessibilityAddTraits(.isButton)
    .focusable()
    .onKeyPress(.return) {
      activate()
      return .handled
    }
    .help(item.name)
  }
}

struct CollectionPickerSheet: View {
  @Environment(\.libraryTextScale) private var textScale
  @Environment(\.dismiss) private var dismiss
  let collections: [MediaCollection]
  let onCreate: (String) async -> UUID?
  let onPick: (UUID) -> Void

  @State private var name = ""
  @State private var working = false

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.n16) {
      Text(L("Add to Collection"))
        .font(Tokens.Typography.sectionTitle.scaledFont(textScale))
      List(collections) { collection in
        Button {
          onPick(collection.id)
        } label: {
          HStack {
            Image(systemName: "rectangle.stack")
              .foregroundStyle(Tokens.Palette.textSecondary.color)
            Text(collection.name)
            Spacer()
            Text("\(collection.itemCount)")
              .font(Tokens.Typography.numeric.scaledFont(textScale))
              .foregroundStyle(Tokens.Palette.textSecondary.color)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .frame(minHeight: Tokens.Size.n200)
      Divider()
      HStack(spacing: Tokens.Space.n8) {
        TextField(L("New Collection"), text: $name)
        Button(L("Create")) {
          let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return }
          working = true
          Task {
            if let id = await onCreate(trimmed) { onPick(id) }
            working = false
          }
        }
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
      }
      HStack {
        Spacer()
        Button(L("Cancel")) { dismiss() }
      }
    }
    .padding(Tokens.Space.n20)
    .frame(width: Tokens.Size.n400)
  }
}

/// Reports the NSWindow the source browser is actually hosted in. Keyboard
/// commands arrive carrying a window; comparing against the global key window
/// would let every mounted browser answer the same command.
private struct SourceWindowReader: NSViewRepresentable {
  var onChange: (NSWindow?) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { onChange(view.window) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { onChange(nsView.window) }
  }
}

/// A catalog read failure must look like a failure, not an empty library.
private struct CatalogLoadBanner: View {
  @Environment(\.libraryTextScale) private var textScale
  let message: String
  let retry: () -> Void

  var body: some View {
    HStack(spacing: Tokens.Space.n8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(Tokens.Palette.systemOrange.color)
        .accessibilityHidden(true)
      Text(message)
        .font(Tokens.Typography.body.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textPrimary.color)
      Spacer(minLength: Tokens.Space.n0)
      Button(L("Try Again"), action: retry)
    }
    .padding(Tokens.Space.n12)
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.Radius.n8, style: .continuous)
        .stroke(Tokens.Palette.systemOrange.color))
  }
}
