//
//  MediaSource.swift
//  uniplayer
//
//  Saved local and LAN media roots. A root is a folder the person chose and
//  the identity observed for the volume it lives on; it is not a second player
//  and it never owns credentials or mount lifecycle. The types here are pure
//  value objects so they can be exercised without a database, a window or a
//  mounted share.
//

import Foundation

// MARK: - Kinds and states

enum MediaSourceKind: String, Codable, CaseIterable, Sendable {
  case local
  case mountedSMB

  var isNetwork: Bool { self == .mountedSMB }
  var symbolName: String { self == .mountedSMB ? "externaldrive.connected.to.line.below" : "folder" }
}

enum SourceInclusion: String, Codable, Sendable {
  case browseOnly
  case indexed

  var isIndexed: Bool { self == .indexed }
}

enum MediaPresence: String, Codable, Sendable {
  case unknown
  case present
  case missing
}

enum SourceConnectivity: String, Codable, Sendable {
  case unknown
  case connecting
  case online
  case offline
  case authenticationRequired
  case accessDenied

  var isUsable: Bool { self == .online }
}

enum SourceActivity: String, Codable, Sendable {
  case idle
  case listing
  case scanning
  case paused
  case attention
}

enum MembershipReason: String, Codable, CaseIterable, Sendable {
  case indexed
  case explicit
  case history
  case collection
  case favorite
}

enum ManualActionKind: String, Codable, Sendable {
  case watched
  case reset
}

// MARK: - Comparison semantics

/// How a root compares two paths. `key(for:)` is the only place a path is
/// folded; catalog uniqueness and overlap checks both use it so a case change
/// cannot create a duplicate silently.
struct ComparisonSemantics: Codable, Hashable, Sendable {
  var caseSensitive: Bool
  var unicodeNormalizing: Bool

  static let `default` = ComparisonSemantics(caseSensitive: false, unicodeNormalizing: true)

  func key(for relativePath: String) -> String {
    var value = relativePath
    if unicodeNormalizing {
      value = value.precomposedStringWithCanonicalMapping
    }
    if !caseSensitive {
      value = value.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    return value
  }

  var persistedValue: String {
    "\(caseSensitive ? "cs" : "ci"):\(unicodeNormalizing ? "nfc" : "raw")"
  }

  init(caseSensitive: Bool, unicodeNormalizing: Bool) {
    self.caseSensitive = caseSensitive
    self.unicodeNormalizing = unicodeNormalizing
  }

  init?(persistedValue: String) {
    let parts = persistedValue.split(separator: ":")
    guard parts.count == 2 else { return nil }
    switch (parts[0], parts[1]) {
    case ("cs", "nfc"): self.init(caseSensitive: true, unicodeNormalizing: true)
    case ("cs", "raw"): self.init(caseSensitive: true, unicodeNormalizing: false)
    case ("ci", "nfc"): self.init(caseSensitive: false, unicodeNormalizing: true)
    case ("ci", "raw"): self.init(caseSensitive: false, unicodeNormalizing: false)
    default: return nil
    }
  }
}

// MARK: - Identity

/// The observed storage identity of a root. Server aliases and mount folder
/// names are hints; this value is what the catalog compares.
struct SourceNamespace: Codable, Hashable, Sendable {
  var kind: MediaSourceKind
  /// A volume UUID where the system reports one, otherwise a conservative
  /// filesystem identity. Never a display name alone.
  var volumeIdentity: String
  var fileSystemType: String
  /// Sanitized endpoint/share label for diagnostics and properties. No
  /// credentials, user names or passwords.
  var endpointLabel: String?
  var accountContextLabel: String?

  var persistedValue: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(self) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }

  static func decode(_ value: String) -> SourceNamespace? {
    guard let data = value.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(SourceNamespace.self, from: data)
  }

  var displayLabel: String? {
    if let endpointLabel, !endpointLabel.isEmpty { return endpointLabel }
    return nil
  }
}

struct SourceIdentity: Codable, Hashable, Sendable {
  var namespace: SourceNamespace
  var pathInNamespace: String
  var comparison: ComparisonSemantics
  /// The observed mount point for the volume that holds this root. This is a
  /// hint resolved from the current mount table, not saved identity.
  var mountPath: String
  /// False when the public API could not prove the volume identity. Such a
  /// root may still be browsed, but absence is never reconciled automatically.
  var isVerified: Bool

  init(namespace: SourceNamespace, pathInNamespace: String,
       comparison: ComparisonSemantics, mountPath: String = "",
       isVerified: Bool) {
    self.namespace = namespace
    self.pathInNamespace = SourcePath.normalized(pathInNamespace)
    self.comparison = comparison
    self.mountPath = mountPath
    self.isVerified = isVerified
  }
}

// MARK: - Roots

struct MediaSourceRoot: Identifiable, Codable, Hashable, Sendable {
  var id: UUID
  var displayName: String
  var kind: MediaSourceKind
  /// Security-scoped or plain bookmark data. Bookmarks assist relocation in an
  /// unsandboxed build; they are not a claim of sandbox authorization.
  var bookmark: Data?
  var namespace: SourceNamespace
  var pathInNamespace: String
  var currentMountHint: String?
  var comparison: ComparisonSemantics
  var inclusion: SourceInclusion
  var createdAt: Date
  var lastSuccessfulUpdate: Date?
  var detachedAt: Date?

  var isDetached: Bool { detachedAt != nil }

  /// The root URL while the volume is attached at the last observed mount
  /// point. This is a hint for display; identity checks still run before I/O.
  var resolvedURL: URL? {
    guard let currentMountHint, !currentMountHint.isEmpty else { return nil }
    var url = URL(fileURLWithPath: currentMountHint, isDirectory: true)
    let relative = SourcePath.normalized(pathInNamespace)
    if !relative.isEmpty {
      for component in relative.split(separator: "/") {
        url.appendPathComponent(String(component), isDirectory: true)
      }
    }
    return url
  }

  func resolvedURL(mountPath: String) -> URL {
    var url = URL(fileURLWithPath: mountPath, isDirectory: true)
    let relative = SourcePath.normalized(pathInNamespace)
    if !relative.isEmpty {
      for component in relative.split(separator: "/") {
        url.appendPathComponent(String(component), isDirectory: true)
      }
    }
    return url
  }

  func overlaps(with other: MediaSourceRoot) -> Bool {
    guard namespace == other.namespace,
          comparison == other.comparison else { return false }
    return SourcePath.isAncestor(pathInNamespace, of: other.pathInNamespace, semantics: comparison)
      || SourcePath.isAncestor(other.pathInNamespace, of: pathInNamespace, semantics: comparison)
  }
}

// MARK: - File observations

struct FileStat: Hashable, Sendable {
  var url: URL
  var isDirectory: Bool
  var isSymbolicLink: Bool
  var isPackage: Bool
  var size: Int64?
  var modified: Date?
  var isReadable: Bool
}

struct DirectoryEntry: Hashable, Sendable {
  var url: URL
  var name: String
  var isDirectory: Bool
  var isSymbolicLink: Bool
  var isPackage: Bool
  var size: Int64?
  var modified: Date?
}

struct DirectoryListing: Sendable {
  var url: URL
  var entries: [DirectoryEntry]
  /// True only for a complete successful enumeration. A partial page, a
  /// cancellation or a permission failure must leave this false; absence is
  /// never inferred from an incomplete listing.
  var isComplete: Bool
  var observedAt: Date
  var generation: UInt64
}

// MARK: - Paths

enum SourcePath {
  /// Root-relative, slash separated, no leading or trailing slash, no `.` or
  /// `..` components. The root itself is the empty string.
  static func normalized(_ path: String) -> String {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
      .filter { $0 != "." && $0 != ".." }
    return components.joined(separator: "/")
  }

  static func isAncestor(_ ancestor: String, of descendant: String,
                         semantics: ComparisonSemantics) -> Bool {
    let a = semantics.key(for: normalized(ancestor))
    let d = semantics.key(for: normalized(descendant))
    if a.isEmpty { return true }
    if a == d { return true }
    return d.hasPrefix(a + "/")
  }

  static func parent(of path: String) -> String? {
    let normalized = normalized(path)
    guard !normalized.isEmpty else { return nil }
    var components = normalized.split(separator: "/").map(String.init)
    components.removeLast()
    return components.joined(separator: "/")
  }

  static func lastComponent(of path: String) -> String {
    String(normalized(path).split(separator: "/").last ?? "")
  }

  static func appending(_ component: String, to path: String) -> String {
    let base = normalized(path)
    let child = normalized(component)
    guard !child.isEmpty else { return base }
    return base.isEmpty ? child : base + "/" + child
  }
}

// MARK: - Leases

/// An in-use reference to a resolved URL. It prevents relinking or
/// reconciliation from moving the ground underneath active playback. It is not
/// a sandbox capability and it never forces an unmount.
final class SourceAccessLease {
  let id: UUID
  let mediaID: UUID?
  let rootID: UUID?
  let url: URL
  let generation: UInt64

  private let lock = NSLock()
  private var released = false
  private let onRelease: ((SourceAccessLease) -> Void)?

  init(mediaID: UUID?, rootID: UUID?, url: URL, generation: UInt64,
       onRelease: ((SourceAccessLease) -> Void)? = nil) {
    self.id = UUID()
    self.mediaID = mediaID
    self.rootID = rootID
    self.url = url
    self.generation = generation
    self.onRelease = onRelease
  }

  func release() {
    lock.lock()
    guard !released else {
      lock.unlock()
      return
    }
    released = true
    lock.unlock()
    onRelease?(self)
  }

  deinit { release() }
}

final class SourceLeaseRegistry {
  static let shared = SourceLeaseRegistry()

  private let lock = NSLock()
  private var counts: [UUID: Int] = [:]

  func makeLease(mediaID: UUID?, rootID: UUID?, url: URL, generation: UInt64) -> SourceAccessLease {
    if let rootID {
      lock.lock()
      counts[rootID, default: 0] += 1
      lock.unlock()
    }
    return SourceAccessLease(mediaID: mediaID, rootID: rootID, url: url,
                             generation: generation) { [weak self] lease in
      guard let self, let rootID = lease.rootID else { return }
      self.lock.lock()
      let next = max(0, (self.counts[rootID] ?? 1) - 1)
      if next == 0 { self.counts.removeValue(forKey: rootID) }
      else { self.counts[rootID] = next }
      self.lock.unlock()
    }
  }

  func activeLeaseCount(for rootID: UUID) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return counts[rootID] ?? 0
  }
}

// MARK: - Errors

enum MediaSourceError: Error, Equatable {
  case notFound
  case unreadable
  case permissionDenied
  case offline
  case authenticationRequired
  case accessDenied
  case identityUnverified
  case identityChanged
  case duplicate(existing: UUID)
  case overlap(existing: UUID)
  case possibleAlias(existing: UUID)
  case invalidLocator
  case cancelled
  case timedOut
  case quarantined
  case partial
  case unsupported
  case conflict
  case database(String)

  var userMessage: String {
    switch self {
    case .notFound: return "This item wasn’t found at its saved location."
    case .unreadable: return "This item could not be read."
    case .permissionDenied: return "You no longer have access to this folder."
    case .offline: return "The source is offline."
    case .authenticationRequired: return "Sign in again to access this source."
    case .accessDenied: return "Access to this source was denied."
    case .identityUnverified: return "The source’s identity could not be verified."
    case .identityChanged: return "The source changed since it was saved."
    case .duplicate: return "This folder is already a source."
    case .overlap: return "This folder overlaps an existing source."
    case .possibleAlias: return "This may be the same folder under another name."
    case .invalidLocator: return "The saved location is not valid."
    case .cancelled: return "The operation was cancelled."
    case .timedOut: return "The source did not respond in time."
    case .quarantined: return "A previous request is still waiting for this source."
    case .partial: return "Some folders could not be read."
    case .unsupported: return "This source is not supported."
    case .conflict: return "This item changed since you last looked at it."
    case .database: return "The media library could not be read."
    }
  }
}

// MARK: - Provider

protocol MediaSourceProvider: AnyObject {
  var kind: MediaSourceKind { get }
  /// Observe the volume identity at a folder. Throws when the folder is not
  /// readable; never fabricates an identity from a display name.
  func observeIdentity(at url: URL) throws -> SourceIdentity
  func listDirectory(at url: URL, generation: UInt64) throws -> DirectoryListing
  func stat(at url: URL) throws -> FileStat
}

// MARK: - Feature flag

enum MediaSourcesFeature {
  static let defaultsKey = "media.sources.enabled.v1"

  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: defaultsKey)
  }

  static func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: defaultsKey)
    NotificationCenter.default.post(name: .mediaSourcesEnabledDidChange, object: nil)
  }
}

extension Notification.Name {
  static let mediaSourcesEnabledDidChange = Notification.Name("UniPlayerMediaSourcesEnabledDidChange")
  static let mediaCatalogDidChange = Notification.Name("UniPlayerMediaCatalogDidChange")
  static let mediaSourceStateDidChange = Notification.Name("UniPlayerMediaSourceStateDidChange")
  static let mediaSourcesAddRequested = Notification.Name("UniPlayerMediaSourcesAddRequested")
  static let mediaSourcesShowRequested = Notification.Name("UniPlayerMediaSourcesShowRequested")
  static let mediaSourcesGoUpRequested = Notification.Name("UniPlayerMediaSourcesGoUpRequested")
  static let mediaSourcesOpenSelectionRequested = Notification.Name("UniPlayerMediaSourcesOpenSelectionRequested")
}
