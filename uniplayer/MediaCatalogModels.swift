//
//  MediaCatalogModels.swift
//  uniplayer
//
//  Rows read from the media catalog. These are value types: views and scanners
//  never hold a database cursor or touch SQLite directly.
//

import Foundation

struct MediaDirectory: Identifiable, Hashable, Sendable {
  var id: UUID
  var rootID: UUID
  var parentID: UUID?
  var relativePath: String
  var comparisonKey: String
  var lastSuccessfulGeneration: UInt64?
  var lastVisitedAt: Date?
  var listingObservedAt: Date?
  var snapshotComplete: Bool
  var ancestorAbsence: String?
}

struct MediaPlayState: Hashable, Sendable {
  var mediaID: UUID
  var observedPosition: Double
  var observedDuration: Double?
  var completed: Bool
  var manualWatchedOverride: Bool?
  var lastManualActionAt: Date?
  var lastManualActionKind: ManualActionKind?
  var observedAt: Date
  var revision: Int64
}

struct CatalogMedia: Identifiable, Hashable, Sendable {
  var id: UUID
  var rootID: UUID?
  var directoryID: UUID?
  var relativePath: String?
  var comparisonKey: String?
  var name: String
  var foldedSearchText: String
  var providerFileID: String?
  var size: Int64?
  var modifiedAt: Date?
  var duration: Double?
  var firstDiscoveredAt: Date
  var presence: MediaPresence
  var hiddenAt: Date?
  var reasons: Set<MembershipReason>
  var playState: MediaPlayState?
  var rootDisplayName: String?
  var rootKind: MediaSourceKind?
  var url: URL?

  var isHidden: Bool { hiddenAt != nil }
  var isMissing: Bool { presence == .missing }
  var isPlayable: Bool { presence != .missing && url != nil }

  var progress: Double {
    guard let state = playState, let duration = state.observedDuration, duration > 0 else {
      return playState?.completed == true ? 1 : 0
    }
    return min(max(state.observedPosition / duration, 0), 1)
  }

  var isFinished: Bool {
    if playState?.manualWatchedOverride == true { return true }
    if playState?.completed == true { return true }
    return progress >= 0.97
  }

  var isResumable: Bool {
    guard !isFinished, let state = playState else { return false }
    return state.observedPosition > 0
  }
}

struct MediaCollection: Identifiable, Hashable, Sendable {
  var id: UUID
  var name: String
  var createdAt: Date
  var itemCount: Int
}

struct MediaReasonRow: Hashable, Sendable {
  var reason: MembershipReason
  var originID: String
}

struct MediaAliasRow: Hashable, Sendable {
  var kind: String
  var value: String
  var namespace: String
  var validFrom: Date
  var retiredAt: Date?
}

/// An exact pre-action snapshot used by Undo. It captures the reason origins,
/// not just the reason kinds, so collection and history provenance survives a
/// restore.
struct MediaRowSnapshot: Sendable {  var media: CatalogMedia
  var reasonRows: [MediaReasonRow]
  var collectionIDs: [UUID]
  var aliases: [MediaAliasRow]
  var playState: MediaPlayState?
  var redirectID: UUID?
  /// Redirects that pointed at this row before it was retired. A merge
  /// re-points them at the survivor, so Undo must put them back.
  var incomingRedirectIDs: [UUID] = []

  /// The undo guard: every field a merge owns must still be what the merge
  /// produced before an Undo may restore this row.
  func guards(_ other: MediaRowSnapshot) -> Bool {
    playState?.revision == other.playState?.revision
      && Set(reasonRows) == Set(other.reasonRows)
      && Set(collectionIDs) == Set(other.collectionIDs)
      && Set(aliases) == Set(other.aliases)
      && Set(incomingRedirectIDs) == Set(other.incomingRedirectIDs)
      && media.sameFileRow(as: other.media)
  }
}

extension CatalogMedia {
  /// The fields a merge does not own. A scan or relink that changed any of them
  /// makes the pre-merge snapshot too old to restore.
  func sameFileRow(as other: CatalogMedia) -> Bool {
    rootID == other.rootID
      && directoryID == other.directoryID
      && relativePath == other.relativePath
      && comparisonKey == other.comparisonKey
      && name == other.name
      && foldedSearchText == other.foldedSearchText
      && providerFileID == other.providerFileID
      && size == other.size
      && modifiedAt == other.modifiedAt
      && duration == other.duration
      && firstDiscoveredAt == other.firstDiscoveredAt
      && presence == other.presence
      && hiddenAt == other.hiddenAt
  }
}


struct AbsenceReview: Identifiable, Codable, Hashable, Sendable {
  var token: UUID
  var rootID: UUID
  var generation: UInt64
  var directoryIDs: [UUID]
  var missingMediaIDs: [UUID]
  var reason: String
  var missingCount: Int
  var knownCount: Int
  var createdAt: Date

  var id: UUID { token }
}

struct DirectorySnapshot: Sendable {
  var directory: MediaDirectory
  var subdirectories: [MediaDirectory]
  var items: [CatalogMedia]
  var complete: Bool
  var observedAt: Date?
  var generation: UInt64?
}

enum CatalogSearchScope: Hashable, Sendable {
  case thisFolder(UUID)
  case allLibrary
  case indexedRoot(UUID)
}

enum CatalogFilter: String, CaseIterable, Sendable {
  case all
  case unfinished
  case watched
  case favorites
  case missing
}

/// What one committed directory batch added to the catalog.
struct DirectoryCommitCounts: Sendable {
  var discovered = 0
  var updated = 0
}
