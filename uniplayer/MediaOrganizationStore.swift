//
//  MediaOrganizationStore.swift
//  uniplayer
//
//  Deliberate organization edits with an exact, revision-guarded Undo. The
//  store captures provenance rows before an action, not just a boolean, so
//  undoing a collection or favorite edit cannot silently create an explicit
//  membership reason.
//

import Foundation

enum OrganizationError: Error, Equatable {
  case cannotUndo(String)
  case busy

  var userMessage: String {
    switch self {
    case .cannotUndo(let reason): return reason
    case .busy: return "Another library change is still being saved. Try again in a moment."
    }
  }
}

@MainActor
final class MediaOrganizationStore {
  private struct Entry {
    let title: String
    let undo: () async throws -> Void
    let redo: () async throws -> Void
  }

  private let catalog: MediaCatalog
  private let mirrorLegacyDefaults: Bool
  private var undoStack: [Entry] = []
  private var redoStack: [Entry] = []
  private var applying = false

  init(catalog: MediaCatalog, mirrorLegacyDefaults: Bool = true) {
    self.catalog = catalog
    self.mirrorLegacyDefaults = mirrorLegacyDefaults
  }

  var canUndo: Bool { !undoStack.isEmpty }
  var canRedo: Bool { !redoStack.isEmpty }
  var undoTitle: String? { undoStack.last?.title }

  func addToCollection(_ mediaIDs: [UUID], to collectionID: UUID) async throws {
    try beginMutation()
    defer { endMutation() }
    var prior: [UUID: [UUID]] = [:]
    for mediaID in mediaIDs {
      prior[mediaID] = try await catalog.collectionIDs(for: mediaID)
    }
    let newlyAdded = mediaIDs.filter { !(prior[$0] ?? []).contains(collectionID) }
    try await catalog.addToCollection(collectionID: collectionID, mediaIDs: mediaIDs)
    push(Entry(
      title: "Add to Collection",
      undo: { [catalog] in
        try await catalog.removeFromCollection(collectionID: collectionID,
                                               mediaIDs: newlyAdded)
      },
      redo: { [catalog] in
        try await catalog.addToCollection(collectionID: collectionID,
                                          mediaIDs: newlyAdded)
      }))
  }

  func removeFromCollection(_ mediaIDs: [UUID], from collectionID: UUID) async throws {
    try beginMutation()
    defer { endMutation() }
    var prior: [UUID: [UUID]] = [:]
    for mediaID in mediaIDs {
      prior[mediaID] = try await catalog.collectionIDs(for: mediaID)
    }
    let removed = mediaIDs.filter { (prior[$0] ?? []).contains(collectionID) }
    try await catalog.removeFromCollection(collectionID: collectionID, mediaIDs: mediaIDs)
    push(Entry(
      title: "Remove from Collection",
      undo: { [catalog] in
        try await catalog.addToCollection(collectionID: collectionID, mediaIDs: removed)
      },
      redo: { [catalog] in
        try await catalog.removeFromCollection(collectionID: collectionID,
                                               mediaIDs: removed)
      }))
  }

  func setFavorite(_ favorite: Bool, mediaIDs: [UUID]) async throws {
    try beginMutation()
    defer { endMutation() }
    var prior: [UUID: Bool] = [:]
    for mediaID in mediaIDs {
      prior[mediaID] = try await catalog.reasons(mediaID: mediaID).contains(.favorite)
    }
    try await catalog.setFavorite(mediaIDs: mediaIDs, favorite: favorite)
    push(Entry(
      title: favorite ? "Favorite" : "Unfavorite",
      undo: { [catalog] in
        for mediaID in mediaIDs {
          try await catalog.setFavorite(mediaID: mediaID, favorite: prior[mediaID] ?? false)
        }
      },
      redo: { [catalog] in
        for mediaID in mediaIDs {
          try await catalog.setFavorite(mediaID: mediaID, favorite: favorite)
        }
      }))
  }

  func markWatched(_ watched: Bool, mediaIDs: [UUID]) async throws {
    try await applyWatchedState(watched, mediaIDs: mediaIDs)
  }

  func resetUnwatched(_ mediaIDs: [UUID]) async throws {
    try await applyWatchedState(nil, mediaIDs: mediaIDs)
  }

  /// One implementation for watched, unwatched and reset. `watched == nil`
  /// clears the override and the mirrored legacy value together. The undo
  /// restores every play state in one transaction, so a batch cannot end up
  /// half undone, and it captures the legacy values the mirror is about to
  /// overwrite so the fallback library agrees after an undo.
  private func applyWatchedState(_ watched: Bool?, mediaIDs: [UUID]) async throws {
    try beginMutation()
    defer { endMutation() }
    let legacyBefore = mirrorLegacyDefaults
      ? await captureLegacyWatched(mediaIDs) : []
    var prior: [(mediaID: UUID, state: MediaPlayState?)] = []
    for mediaID in mediaIDs {
      prior.append((mediaID, try await catalog.playState(mediaID: mediaID)))
    }
    if let watched {
      try await catalog.markWatched(mediaIDs: mediaIDs, watched: watched)
    } else {
      try await catalog.resetUnwatched(mediaIDs: mediaIDs)
    }
    var post: [UUID: Int64?] = [:]
    for mediaID in mediaIDs {
      post[mediaID] = try await catalog.playState(mediaID: mediaID)?.revision
    }
    await mirrorWatched(mediaIDs, watched: watched)
    let rows = prior.map { row in
      (mediaID: row.mediaID, expectedRevision: post[row.mediaID] ?? nil,
       restore: row.state)
    }
    push(Entry(
      title: watched == true ? "Mark Watched"
        : (watched == false ? "Mark Unwatched" : "Reset Progress"),
      undo: { [weak self, catalog] in
        try await catalog.restorePlayStates(rows)
        await self?.applyLegacyWatched(legacyBefore)
      },
      redo: { [weak self, catalog] in
        if let watched {
          try await catalog.markWatched(mediaIDs: mediaIDs, watched: watched)
        } else {
          try await catalog.resetUnwatched(mediaIDs: mediaIDs)
        }
        await self?.mirrorWatched(mediaIDs, watched: watched)
      }))
  }

  /// Hide is independent of membership. Mirror it into the legacy defaults so
  /// an older build's fallback honours the same choice.
  func setHidden(_ hidden: Bool, mediaIDs: [UUID]) async throws {
    try beginMutation()
    defer { endMutation() }
    var prior: [UUID: Bool] = [:]
    for mediaID in mediaIDs {
      prior[mediaID] = (try await catalog.media(id: mediaID))?.isHidden ?? false
    }
    try await catalog.setHidden(mediaIDs: mediaIDs, hidden: hidden)
    for mediaID in mediaIDs {
      await mirrorHidden(mediaID: mediaID, hidden: hidden)
    }
    push(Entry(
      title: hidden ? "Hide from Library" : "Show in Library",
      undo: { [weak self, catalog] in
        for mediaID in mediaIDs {
          let previous = prior[mediaID] ?? false
          try await catalog.setHidden(mediaID: mediaID, hidden: previous)
          await self?.mirrorHidden(mediaID: mediaID, hidden: previous)
        }
      },
      redo: { [weak self, catalog] in
        for mediaID in mediaIDs {
          try await catalog.setHidden(mediaID: mediaID, hidden: hidden)
          await self?.mirrorHidden(mediaID: mediaID, hidden: hidden)
        }
      }))
  }

  private struct LegacyWatchedValue {
    var key: String
    var value: Bool?
  }

  /// Hold the store for the whole mutation, not just its start: an edit that
  /// suspends at an await must finish before Undo can run, or it can push a
  /// new entry while undo is removing one.
  private func beginMutation() throws {
    if applying { throw OrganizationError.busy }
    applying = true
  }

  private func endMutation() {
    applying = false
  }

  private func legacyKeys(for mediaID: UUID) async -> [String] {
    let aliases = (try? await catalog.aliases(for: mediaID)) ?? []
    return aliases
      .filter { $0.kind == "filePath" || $0.kind == "url" }
      .map { $0.value }
  }

  private func captureLegacyWatched(_ mediaIDs: [UUID]) async -> [LegacyWatchedValue] {
    let values = UserDefaults.standard
      .dictionary(forKey: "library.watched.v1") as? [String: Bool] ?? [:]
    var captured: [LegacyWatchedValue] = []
    for mediaID in mediaIDs {
      for key in await legacyKeys(for: mediaID) {
        captured.append(LegacyWatchedValue(key: key, value: values[key]))
      }
    }
    return captured
  }

  private func applyLegacyWatched(_ captured: [LegacyWatchedValue]) {
    guard mirrorLegacyDefaults, !captured.isEmpty else { return }
    let defaults = UserDefaults.standard
    var values = defaults.dictionary(forKey: "library.watched.v1") as? [String: Bool] ?? [:]
    for row in captured {
      if let value = row.value { values[row.key] = value }
      else { values.removeValue(forKey: row.key) }
    }
    defaults.set(values, forKey: "library.watched.v1")
  }

  private func mirrorWatched(_ mediaIDs: [UUID], watched: Bool?) async {
    guard mirrorLegacyDefaults else { return }
    let defaults = UserDefaults.standard
    var values = defaults.dictionary(forKey: "library.watched.v1") as? [String: Bool] ?? [:]
    for mediaID in mediaIDs {
      let aliases = (try? await catalog.aliases(for: mediaID)) ?? []
      for alias in aliases where alias.kind == "filePath" || alias.kind == "url" {
        if let watched { values[alias.value] = watched }
        else { values.removeValue(forKey: alias.value) }
      }
    }
    defaults.set(values, forKey: "library.watched.v1")
  }

  private func mirrorHidden(mediaID: UUID, hidden: Bool) async {
    guard mirrorLegacyDefaults else { return }
    let defaults = UserDefaults.standard
    var values = Set(defaults.stringArray(forKey: "library.hidden.v1") ?? [])
    let aliases = (try? await catalog.aliases(for: mediaID)) ?? []
    for alias in aliases where alias.kind == "filePath" || alias.kind == "url" {
      if hidden { values.insert(alias.value) } else { values.remove(alias.value) }
    }
    defaults.set(Array(values), forKey: "library.hidden.v1")
  }

  /// Merge a confirmed relink collision. Undo restores both exact snapshots
  /// only while the survivor's play-state revision has not moved.
  @discardableResult
  func merge(mediaID: UUID, with otherID: UUID) async throws -> UUID {
    try beginMutation()
    defer { endMutation() }
    guard let first = try await catalog.snapshot(mediaID: mediaID),
          let second = try await catalog.snapshot(mediaID: otherID) else {
      throw MediaSourceError.notFound
    }
    let survivorID = Self.isOlder(first.media, second.media)
      ? first.media.id : second.media.id
    let retiredID = survivorID == first.media.id ? second.media.id : first.media.id
    let survivorSnapshot = survivorID == first.media.id ? first : second
    let retiredSnapshot = survivorID == first.media.id ? second : first
    // The post-merge expectation comes from the merge transaction itself, so a
    // change landing just after the merge cannot become part of what Undo is
    // willing to overwrite.
    guard let postMerge = try await catalog.mergeMediaAndSnapshot(
      retiredID: retiredID, survivingID: survivorID,
      operationID: "organization:\(UUID().uuidString)") else {
      throw MediaSourceError.notFound
    }

    push(Entry(
      title: "Merge Items",
      undo: { [catalog] in
        do {
          // The guard runs inside the restore transaction; a change landing
          // between a separate check and the write cannot slip through.
          try await catalog.restore([survivorSnapshot, retiredSnapshot],
                                    expecting: [postMerge])
        } catch MediaSourceError.conflict {
          throw OrganizationError.cannotUndo(
            "Playback or organization changed after the merge, so it cannot be undone automatically.")
        }
      },
      redo: { [catalog] in
        _ = try await catalog.mergeMedia(
          retiredID: retiredID, survivingID: survivorID,
          operationID: "organization:redo:\(UUID().uuidString)")
      }))
    return survivorID
  }

  /// Merge two rows for a confirmed relink. No Undo entry is recorded: a
  /// relink immediately moves the survivor's locator and aliases after the
  /// merge, so an expectation captured here could never be replayed.
  @discardableResult
  func mergeForRelink(mediaID: UUID, with otherID: UUID) async throws -> UUID {
    try beginMutation()
    defer { endMutation() }
    guard let first = try await catalog.snapshot(mediaID: mediaID),
          let second = try await catalog.snapshot(mediaID: otherID) else {
      throw MediaSourceError.notFound
    }
    let survivorID = Self.isOlder(first.media, second.media)
      ? first.media.id : second.media.id
    let retiredID = survivorID == first.media.id ? second.media.id : first.media.id
    return try await catalog.mergeMedia(
      retiredID: retiredID, survivingID: survivorID,
      operationID: "relink:\(UUID().uuidString)")
  }

  func undo() async throws {
    guard !applying, let entry = undoStack.last else { return }
    applying = true
    defer { applying = false }
    try await entry.undo()
    undoStack.removeLast()
    redoStack.append(entry)
  }

  func redo() async throws {
    guard !applying, let entry = redoStack.last else { return }
    applying = true
    defer { applying = false }
    try await entry.redo()
    redoStack.removeLast()
    undoStack.append(entry)
  }

  func clearHistory() {
    guard !applying else { return }
    undoStack.removeAll()
    redoStack.removeAll()
  }

  /// The fields a merge does not own live on `CatalogMedia.sameFileRow`, which
  /// the catalog checks inside the restore transaction.

  private func push(_ entry: Entry) {
    undoStack.append(entry)
    redoStack.removeAll()
  }

  private static func isOlder(_ lhs: CatalogMedia, _ rhs: CatalogMedia) -> Bool {
    if lhs.firstDiscoveredAt != rhs.firstDiscoveredAt {
      return lhs.firstDiscoveredAt < rhs.firstDiscoveredAt
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
