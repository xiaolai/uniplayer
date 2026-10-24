//
//  SourceBrowserModel.swift
//  uniplayer
//
//  One source's browse state: directory, selection, search scope, history and
//  cached offline listings. Rendering reads this model; only explicit
//  navigation, refresh and open actions perform source I/O.
//

import Foundation
import Combine

enum SourceSearchScope: String, CaseIterable, Identifiable {
  case thisFolder
  case allLibrary
  case indexedFolder

  var id: String { rawValue }

  var title: String {
    switch self {
    case .thisFolder: return "This Folder"
    case .allLibrary: return "All Library"
    case .indexedFolder: return "Indexed Folders"
    }
  }
}

struct SourceBreadcrumb: Identifiable, Hashable {
  var id: String { path }
  let title: String
  let path: String
}

struct SourceBrowserRow: Identifiable, Hashable {
  let id: UUID
  let name: String
  let isDirectory: Bool
  let size: Int64?
  let modified: Date?
  let duration: Double?
  let presence: MediaPresence
  let isFavorite: Bool
  let isFinished: Bool
  let isHidden: Bool
  let relativePath: String?
  let resolvedURL: URL?

  var isPlayable: Bool { !isDirectory && presence != .missing }
}

@MainActor
final class SourceBrowserModel: ObservableObject {
  let rootID: UUID
  private let coordinator: SourceCoordinator
  private let catalog: MediaCatalog
  let organization: MediaOrganizationStore

  @Published private(set) var root: MediaSourceRoot?
  @Published private(set) var path = ""
  @Published private(set) var breadcrumbs: [SourceBreadcrumb] = []
  @Published private(set) var snapshot: DirectorySnapshot?
  @Published private(set) var rows: [SourceBrowserRow] = []
  @Published private(set) var loading = false
  @Published private(set) var searchLoading = false
  @Published private(set) var error: MediaSourceError?
  @Published private(set) var pendingReview: AbsenceReview?
  @Published private(set) var isStale = false
  @Published var selectedIDs: Set<UUID> = []
  /// Row to bring into view after a back/forward navigation. The table binds
  /// its scroll position to this value.
  @Published var scrollRowID: UUID?
  @Published var actionError: String?
  @Published var query = "" {
    didSet { scheduleSearch() }
  }
  @Published var scope: SourceSearchScope = .thisFolder {
    didSet {
      if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        scheduleSearch()
      }
    }
  }
  @Published var showGrid = false

  var openMedia: ((UUID, PlaybackIntent) -> Void)?
  var showProperties: (() -> Void)?
  var addSource: (() -> Void)?

  private struct HistoryEntry: Hashable {
    let path: String
    let parentID: UUID?
  }

  private var history: [HistoryEntry] = [HistoryEntry(path: "", parentID: nil)]
  private var historyIndex = 0
  /// Selection per directory, so Back returns to the item that was selected.
  private var selectionByPath: [String: Set<UUID>] = [:]
  private var didLoadInitial = false
  private var navigationID = UUID()
  private var loadTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?

  init(rootID: UUID, coordinator: SourceCoordinator, catalog: MediaCatalog) {
    self.rootID = rootID
    self.coordinator = coordinator
    self.catalog = catalog
    self.organization = coordinator.organization
  }

  var canGoBack: Bool { historyIndex > 0 }
  var canGoForward: Bool { historyIndex + 1 < history.count }
  var canGoUp: Bool { !path.isEmpty }
  var isAtRoot: Bool { path.isEmpty }

  var selectedMediaIDs: [UUID] {
    rows.filter { !$0.isDirectory && selectedIDs.contains($0.id) }.map(\.id)
  }

  var selectedRows: [SourceBrowserRow] {
    rows.filter { selectedIDs.contains($0.id) }
  }

  var inclusion: SourceInclusion {
    root?.inclusion ?? .browseOnly
  }

  // MARK: - Loading

  func loadInitial() async {
    guard !didLoadInitial else { return }
    didLoadInitial = true
    root = coordinator.root(id: rootID)
    pendingReview = try? await coordinator.pendingReview(rootID: rootID)
    await navigate(to: HistoryEntry(path: "", parentID: nil), recordHistory: false)
  }

  func navigate(to path: String, parentID: UUID?) async {
    await navigate(to: HistoryEntry(path: path, parentID: parentID), recordHistory: true)
  }

  private func navigate(to entry: HistoryEntry, recordHistory: Bool) async {
    selectionByPath[path] = selectedIDs
    loadTask?.cancel()
    let token = UUID()
    navigationID = token
    loading = true
    error = nil
    root = coordinator.root(id: rootID)
    let task = Task { @MainActor in
      do {
        let snapshot = try await coordinator.browse(
          rootID: rootID, relativePath: entry.path, parentID: entry.parentID)
        guard !Task.isCancelled, navigationID == token else { return }
        apply(snapshot: snapshot, path: entry.path, stale: false,
              selection: recordHistory ? [] : (selectionByPath[entry.path] ?? []))
        let review = try? await coordinator.pendingReview(rootID: rootID)
        guard !Task.isCancelled, navigationID == token else { return }
        pendingReview = review ?? nil
        if recordHistory { record(entry) }
      } catch {
        guard !Task.isCancelled, navigationID == token else { return }
        let sourceError = error as? MediaSourceError ?? .unreadable
        self.error = sourceError
        await loadCachedSnapshot(
          path: entry.path, token: token,
          selection: recordHistory ? [] : (selectionByPath[entry.path] ?? []))
        guard navigationID == token else { return }
        if recordHistory { record(entry) }
      }
      if navigationID == token { loading = false }
    }
    loadTask = task
    await task.value
  }

  private func loadCachedSnapshot(path: String, token: UUID,
                                  selection: Set<UUID>) async {
    guard let root else { return }
    guard let directory = try? await catalog.directory(
      rootID: root.id, relativePath: path, comparison: root.comparison) else {
      // No cached row for the requested directory: keep the previous listing
      // and its path so the view never pairs the old path with an empty list.
      return
    }
    guard navigationID == token else { return }
    if let cached = try? await catalog.directorySnapshot(directoryID: directory.id) {
      guard navigationID == token else { return }
      apply(snapshot: cached, path: path, stale: true, selection: selection)
    }
  }

  private func apply(snapshot: DirectorySnapshot, path: String, stale: Bool,
                     selection: Set<UUID>) {
    self.snapshot = snapshot
    self.path = path
    self.isStale = stale || !snapshot.complete
    let available = Set(snapshot.subdirectories.map(\.id) + snapshot.items.map(\.id))
    self.selectedIDs = selection.intersection(available)
    self.scrollRowID = snapshot.subdirectories.first(where: {
      self.selectedIDs.contains($0.id)
    })?.id ?? snapshot.items.first(where: {
      self.selectedIDs.contains($0.id)
    })?.id
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      rebuildRows()
    } else {
      scheduleSearch()
    }
    updateBreadcrumbs()
  }

  private func record(_ entry: HistoryEntry) {
    if historyIndex + 1 < history.count {
      history.removeSubrange((historyIndex + 1)..<history.count)
    }
    if history.last != entry {
      history.append(entry)
    }
    historyIndex = history.count - 1
  }

  func goBack() async {
    guard canGoBack else { return }
    historyIndex -= 1
    await navigate(to: history[historyIndex], recordHistory: false)
  }

  func goForward() async {
    guard canGoForward else { return }
    historyIndex += 1
    await navigate(to: history[historyIndex], recordHistory: false)
  }

  func navigate(toBreadcrumb path: String) async {
    let token = navigationID
    let parent = await parentDirectoryID(for: path)
    // A newer navigation may have completed while the lookup ran; starting
    // this one afterwards would supersede it.
    guard navigationID == token else { return }
    await navigate(to: HistoryEntry(path: path, parentID: parent), recordHistory: true)
  }

  func goUp() async {
    let token = navigationID
    guard let target = SourcePath.parent(of: path) else { return }
    let parentID = await parentDirectoryID(for: target)
    guard navigationID == token else { return }
    await navigate(to: target, parentID: parentID)
  }

  func refresh() async {
    let token = navigationID
    let review = try? await coordinator.pendingReview(rootID: rootID)
    let parentID = await parentDirectoryID(for: path)
    guard navigationID == token else { return }
    pendingReview = review ?? nil
    await navigate(to: HistoryEntry(path: path, parentID: parentID), recordHistory: false)
  }

  func reconnect() async {
    error = nil
    await refresh()
  }

  /// The ID of the directory that should be recorded as the parent when
  /// navigating to `path`. The root has no parent.
  private func parentDirectoryID(for path: String) async -> UUID? {
    guard let root, !path.isEmpty else { return nil }
    let parentPath = SourcePath.parent(of: path) ?? ""
    return try? await catalog.directory(rootID: root.id, relativePath: parentPath,
                                        comparison: root.comparison)?.id
  }

  // MARK: - Rows

  private func rebuildRows() {
    guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard let snapshot else {
      rows = []
      return
    }
    var result: [SourceBrowserRow] = []
    for directory in snapshot.subdirectories {
      result.append(SourceBrowserRow(
        id: directory.id,
        name: SourcePath.lastComponent(of: directory.relativePath),
        isDirectory: true,
        size: nil,
        modified: nil,
        duration: nil,
        presence: .present,
        isFavorite: false,
        isFinished: false,
        isHidden: false,
        relativePath: directory.relativePath,
        resolvedURL: url(forRelativePath: directory.relativePath)))
    }
    for item in snapshot.items {
      result.append(row(for: item))
    }
    rows = result
  }

  private func row(for item: CatalogMedia) -> SourceBrowserRow {
    SourceBrowserRow(
      id: item.id,
      name: item.name,
      isDirectory: false,
      size: item.size,
      modified: item.modifiedAt,
      duration: item.duration ?? item.playState?.observedDuration,
      presence: item.presence,
      isFavorite: item.reasons.contains(.favorite),
      isFinished: item.isFinished,
      isHidden: item.isHidden,
      relativePath: item.relativePath,
      resolvedURL: item.url)
  }

  private func url(forRelativePath path: String) -> URL? {
    guard let root, var url = root.resolvedURL else { return nil }
    for component in SourcePath.normalized(path).split(separator: "/") {
      url.appendPathComponent(String(component))
    }
    return url
  }

  func select(_ row: SourceBrowserRow) {
    selectedIDs = [row.id]
  }

  // MARK: - Search

  private func scheduleSearch() {
    searchTask?.cancel()
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if term.isEmpty {
      rebuildRows()
      return
    }
    searchTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled else { return }
      await performSearch(term: term)
    }
  }

  private func performSearch(term: String) async {
    searchLoading = true
    defer { searchLoading = false }
    switch scope {
    case .thisFolder:
      guard !Task.isCancelled else { return }
      let folded = MediaCatalog.folded(term)
      rows = (snapshot?.items ?? []).filter {
        MediaCatalog.folded($0.name).contains(folded)
      }.map { row(for: $0) }
    case .allLibrary:
      let results = try? await catalog.search(term: term, scope: .allLibrary)
      guard !Task.isCancelled else { return }
      if let results { rows = results.map { row(for: $0) } }
    case .indexedFolder:
      let results = try? await catalog.search(term: term, scope: .indexedRoot(rootID))
      guard !Task.isCancelled else { return }
      if let results { rows = results.map { row(for: $0) } }
    }
    if Task.isCancelled { return }
    selectedIDs = []
  }

  func clearSearch() {
    searchTask?.cancel()
    query = ""
    rebuildRows()
  }

  /// Run the current query without the debounce. Used by tests and by an
  /// explicit Return in the search field.
  func searchNow() async {
    searchTask?.cancel()
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if term.isEmpty {
      rebuildRows()
    } else {
      await performSearch(term: term)
    }
  }

  // MARK: - Actions

  func activate(_ row: SourceBrowserRow) {
    if row.isDirectory {
      Task { await navigate(to: row.relativePath ?? row.name, parentID: snapshot?.directory.id) }
    } else {
      openMedia?(row.id, .ordinaryOpen)
    }
  }

  func play(_ row: SourceBrowserRow, intent: PlaybackIntent) {
    guard !row.isDirectory else { return }
    openMedia?(row.id, intent)
  }

  func playSelected(intent: PlaybackIntent) {
    guard let first = selectedRows.first(where: { !$0.isDirectory }) else { return }
    openMedia?(first.id, intent)
  }

  func markWatched(_ watched: Bool) async {
    let ids = selectedMediaIDs
    guard !ids.isEmpty else { return }
    do {
      if watched {
        try await organization.markWatched(true, mediaIDs: ids)
      } else {
        try await organization.resetUnwatched(ids)
      }
      await reloadRows()
    } catch {
      actionError = (error as? MediaSourceError)?.userMessage ?? String(describing: error)
    }
  }

  func toggleFavorite() async {
    let ids = selectedMediaIDs
    guard !ids.isEmpty else { return }
    let favorite = !(selectedRows.first(where: { !$0.isDirectory })?.isFavorite ?? false)
    do {
      try await organization.setFavorite(favorite, mediaIDs: ids)
      await reloadRows()
    } catch {
      actionError = (error as? MediaSourceError)?.userMessage ?? String(describing: error)
    }
  }

  func addSelected(to collectionID: UUID) async {
    let ids = selectedMediaIDs
    guard !ids.isEmpty else { return }
    do {
      try await organization.addToCollection(ids, to: collectionID)
      await reloadRows()
    } catch {
      actionError = (error as? MediaSourceError)?.userMessage ?? String(describing: error)
    }
  }

  func setHidden(_ hidden: Bool) async {
    let ids = selectedMediaIDs
    guard !ids.isEmpty else { return }
    do {
      try await organization.setHidden(hidden, mediaIDs: ids)
      await reloadRows()
    } catch {
      actionError = (error as? MediaSourceError)?.userMessage ?? String(describing: error)
    }
  }

  func applyReview() async -> String? {
    guard let review = pendingReview else { return nil }
    do {
      try await coordinator.applyReview(review)
      pendingReview = nil
      await refresh()
      return nil
    } catch {
      return (error as? MediaSourceError)?.userMessage ?? String(describing: error)
    }
  }

  func dismissReview() async {
    await coordinator.dismissReview(rootID: rootID)
    pendingReview = nil
  }

  func setInclusion(_ inclusion: SourceInclusion) async {
    guard let root else { return }
    try? await coordinator.setInclusion(inclusion, for: root)
    self.root = coordinator.root(id: rootID)
    await refresh()
  }

  func removeSource() async throws {
    guard let root else { return }
    try await coordinator.remove(root)
  }

  func undo() async -> String? {
    do {
      try await organization.undo()
      await reloadRows()
      return nil
    } catch {
      if let organization = error as? OrganizationError {
        return organization.userMessage
      }
      if let source = error as? MediaSourceError {
        return source.userMessage
      }
      return String(describing: error)
    }
  }

  private func reloadRows() async {
    guard let current = snapshot else { return }
    let token = navigationID
    if let refreshed = try? await catalog.directorySnapshot(
      directoryID: current.directory.id) {
      guard navigationID == token else { return }
      apply(snapshot: refreshed, path: path, stale: isStale, selection: selectedIDs)
    }
  }

  private func updateBreadcrumbs() {
    guard let root else {
      breadcrumbs = []
      return
    }
    var result = [SourceBreadcrumb(title: root.displayName, path: "")]
    var current = ""
    for component in path.split(separator: "/") {
      current = SourcePath.appending(String(component), to: current)
      result.append(SourceBreadcrumb(title: String(component), path: current))
    }
    breadcrumbs = result
  }
}
