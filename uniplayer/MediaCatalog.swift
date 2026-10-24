//
//  MediaCatalog.swift
//  uniplayer
//
//  The media catalog is a local SQLite database with one serial writer and
//  reader boundary. Views read cached values only; scanners and providers never
//  run their filesystem work on this queue, and this queue never performs
//  source I/O. Every multi-row user action is one transaction.
//

import Foundation
import SQLite3

private let SQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - SQLite primitives

final class SQLiteStatement {
  private let statement: OpaquePointer

  init(database: OpaquePointer, sql: String) throws {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw MediaSourceError.database(String(cString: sqlite3_errmsg(database)))
    }
    self.statement = statement
  }

  deinit { sqlite3_finalize(statement) }

  func bind(_ index: Int32, _ value: String?) {
    if let value {
      sqlite3_bind_text(statement, index, value, -1, SQLiteTransient)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  func bind(_ index: Int32, _ value: Int64?) {
    if let value { sqlite3_bind_int64(statement, index, value) }
    else { sqlite3_bind_null(statement, index) }
  }

  func bind(_ index: Int32, _ value: Int?) {
    bind(index, value.map(Int64.init))
  }

  func bind(_ index: Int32, _ value: Double?) {
    if let value { sqlite3_bind_double(statement, index, value) }
    else { sqlite3_bind_null(statement, index) }
  }

  func bind(_ index: Int32, _ value: Bool) {
    sqlite3_bind_int(statement, index, value ? 1 : 0)
  }

  func bind(_ index: Int32, _ value: Bool?) {
    if let value { bind(index, value) }
    else { sqlite3_bind_null(statement, index) }
  }

  func bind(_ index: Int32, _ value: Data?) {
    if let value {
      _ = value.withUnsafeBytes { bytes in
        sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), SQLiteTransient)
      }
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  func bind(_ index: Int32, _ value: UInt64?) {
    if let value { sqlite3_bind_int64(statement, index, Int64(bitPattern: value)) }
    else { sqlite3_bind_null(statement, index) }
  }

  @discardableResult
  func step() throws -> Bool {
    switch sqlite3_step(statement) {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    default:
      throw MediaSourceError.database(String(cString: sqlite3_errmsg(sqlite3_db_handle(statement))))
    }
  }

  func reset() {
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
  }

  func text(_ index: Int32) -> String? {
    guard let pointer = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
  }

  func int64(_ index: Int32) -> Int64? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(statement, index)
  }

  func int(_ index: Int32) -> Int? { int64(index).map(Int.init) }

  func uint64(_ index: Int32) -> UInt64? {
    int64(index).map { UInt64(bitPattern: $0) }
  }

  func double(_ index: Int32) -> Double? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(statement, index)
  }

  func bool(_ index: Int32) -> Bool? {
    int64(index).map { $0 != 0 }
  }

  func data(_ index: Int32) -> Data? {
    guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    return Data(bytes: pointer, count: count)
  }

  func uuid(_ index: Int32) throws -> UUID {
    guard let value = text(index), let uuid = UUID(uuidString: value) else {
      throw MediaSourceError.database("invalid UUID column")
    }
    return uuid
  }
}

final class SQLiteDatabase {
  private let handle: OpaquePointer
  private var transactionDepth = 0

  init(path: String) throws {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
    let result = sqlite3_open_v2(path, &database, flags, nil)
    guard result == SQLITE_OK, let database else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
      if let database { sqlite3_close_v2(database) }
      throw MediaSourceError.database(message)
    }
    self.handle = database
    sqlite3_busy_timeout(handle, 5000)
    if path != ":memory:" {
      try execute("PRAGMA journal_mode=WAL")
    }
    try execute("PRAGMA foreign_keys=ON")
    try execute("PRAGMA synchronous=NORMAL")
  }

  deinit { sqlite3_close_v2(handle) }

  func execute(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
      sqlite3_free(error)
      throw MediaSourceError.database(message)
    }
  }

  func prepare(_ sql: String) throws -> SQLiteStatement {
    try SQLiteStatement(database: handle, sql: sql)
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    if transactionDepth > 0 {
      transactionDepth += 1
      defer { transactionDepth -= 1 }
      return try body()
    }
    try execute("BEGIN IMMEDIATE")
    transactionDepth = 1
    do {
      let value = try body()
      try execute("COMMIT")
      transactionDepth = 0
      return value
    } catch {
      try? execute("ROLLBACK")
      transactionDepth = 0
      throw error
    }
  }

  func userVersion() throws -> Int {
    let statement = try prepare("PRAGMA user_version")
    guard try statement.step() else { return 0 }
    return statement.int(0) ?? 0
  }

  func setUserVersion(_ version: Int) throws {
    try execute("PRAGMA user_version=\(version)")
  }
}

// MARK: - Catalog

final class MediaCatalog {
  static let schemaVersion = 1

  let databaseURL: URL
  private let database: SQLiteDatabase
  private let queue = DispatchQueue(label: "UniPlayerMediaCatalog", qos: .utility)
  private var closed = false

  init(databaseURL: URL) throws {
    self.databaseURL = databaseURL
    if databaseURL.path != ":memory:" {
      try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                              withIntermediateDirectories: true)
    }
    database = try SQLiteDatabase(path: databaseURL.path)
    try createSchemaIfNeeded()
  }

  private init(databasePath: String) throws {
    self.databaseURL = URL(fileURLWithPath: databasePath)
    database = try SQLiteDatabase(path: databasePath)
    try createSchemaIfNeeded()
  }

  static func inMemory() throws -> MediaCatalog {
    try MediaCatalog(databasePath: ":memory:")
  }

  static var defaultDatabaseURL: URL {
    Utility.appSupportDirUrl
      .appendingPathComponent("MediaLibrary", isDirectory: true)
      .appendingPathComponent("catalog.sqlite", isDirectory: false)
  }

  /// Stop accepting work after the writes already queued have run. `queue.sync`
  /// is the flush; marking `closed` on the same queue makes every later call
  /// fail instead of writing to a catalog the app has abandoned.
  func close() {
    queue.sync {
      guard !closed else { return }
      closed = true
    }
  }

  /// Wait at most `timeout` for the serial writer to reach this point. The
  /// caller proceeds either way; the last committed transaction is the
  /// checkpoint, so a timeout never leaves a half-written row.
  func flushForTermination(timeout: TimeInterval) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    queue.async { semaphore.signal() }
    return semaphore.wait(timeout: .now() + timeout) == .success
  }

  func integrityCheck() async throws -> (integrity: String, foreignKeyViolations: Int) {
    try await perform {
      let integrity = try self.database.prepare("PRAGMA integrity_check")
      let integrityValue = try integrity.step() ? (integrity.text(0) ?? "") : ""
      let foreignKeys = try self.database.prepare("PRAGMA foreign_key_check")
      var violations = 0
      while try foreignKeys.step() { violations += 1 }
      return (integrityValue, violations)
    }
  }

  // MARK: Schema

  private func createSchemaIfNeeded() throws {
    let version = try database.userVersion()
    guard version <= Self.schemaVersion else {
      throw MediaSourceError.database("catalog schema \(version) is newer than supported \(Self.schemaVersion)")
    }
    if version == Self.schemaVersion { return }
    try database.transaction {
      try database.execute("""
        CREATE TABLE IF NOT EXISTS roots (
          id TEXT PRIMARY KEY NOT NULL,
          display_name TEXT NOT NULL,
          provider_kind TEXT NOT NULL,
          bookmark BLOB,
          observed_namespace TEXT NOT NULL,
          volume_identity TEXT NOT NULL,
          file_system_type TEXT NOT NULL,
          endpoint_label TEXT,
          account_context_label TEXT,
          path_in_namespace TEXT NOT NULL,
          current_mount_hint TEXT,
          comparison_semantics TEXT NOT NULL,
          inclusion TEXT NOT NULL,
          created_at REAL NOT NULL,
          last_successful_update REAL,
          detached_at REAL
        );
        CREATE TABLE IF NOT EXISTS directories (
          id TEXT PRIMARY KEY NOT NULL,
          root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
          parent_id TEXT REFERENCES directories(id) ON DELETE CASCADE,
          relative_path TEXT NOT NULL,
          comparison_key TEXT NOT NULL,
          last_successful_generation INTEGER,
          last_visited_at REAL,
          listing_observed_at REAL,
          snapshot_complete INTEGER NOT NULL DEFAULT 0,
          ancestor_absence TEXT,
          UNIQUE(root_id, comparison_key)
        );
        CREATE TABLE IF NOT EXISTS media_files (
          id TEXT PRIMARY KEY NOT NULL,
          root_id TEXT REFERENCES roots(id) ON DELETE SET NULL,
          directory_id TEXT REFERENCES directories(id) ON DELETE SET NULL,
          relative_path TEXT,
          comparison_key TEXT,
          original_name TEXT NOT NULL,
          folded_search_text TEXT NOT NULL,
          provider_file_id TEXT,
          size INTEGER,
          mtime REAL,
          duration REAL,
          first_discovered_at REAL NOT NULL,
          presence TEXT NOT NULL DEFAULT 'unknown',
          hidden_at REAL,
          UNIQUE(root_id, comparison_key)
        );
        CREATE TABLE IF NOT EXISTS membership_reasons (
          media_id TEXT NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
          reason TEXT NOT NULL,
          origin_id TEXT NOT NULL,
          PRIMARY KEY (media_id, reason, origin_id)
        );
        CREATE TABLE IF NOT EXISTS locator_aliases (
          alias_kind TEXT NOT NULL,
          alias_value TEXT NOT NULL,
          media_id TEXT NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
          observed_namespace TEXT NOT NULL,
          valid_from REAL NOT NULL,
          retired_at REAL,
          PRIMARY KEY (alias_kind, alias_value)
        );
        CREATE TABLE IF NOT EXISTS play_states (
          media_id TEXT PRIMARY KEY REFERENCES media_files(id) ON DELETE CASCADE,
          observed_position REAL NOT NULL DEFAULT 0,
          observed_duration REAL,
          completed INTEGER NOT NULL DEFAULT 0,
          manual_watched_override INTEGER,
          last_manual_action_at REAL,
          last_manual_action_kind TEXT,
          observed_at REAL NOT NULL,
          revision INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS item_redirects (
          obsolete_media_id TEXT PRIMARY KEY,
          surviving_media_id TEXT NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
          operation_id TEXT NOT NULL,
          created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS collections (
          id TEXT PRIMARY KEY NOT NULL,
          name TEXT NOT NULL,
          created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS collection_items (
          collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
          media_id TEXT NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
          added_at REAL NOT NULL,
          PRIMARY KEY (collection_id, media_id)
        );
        CREATE TABLE IF NOT EXISTS scan_runs (
          id TEXT PRIMARY KEY NOT NULL,
          root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
          generation INTEGER NOT NULL,
          state TEXT NOT NULL,
          started_at REAL NOT NULL,
          ended_at REAL,
          discovered INTEGER NOT NULL DEFAULT 0,
          updated INTEGER NOT NULL DEFAULT 0,
          error_category TEXT,
          pending_absence_review TEXT
        );
        CREATE TABLE IF NOT EXISTS migration_state (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT,
          completed_at REAL
        );
        CREATE INDEX IF NOT EXISTS idx_media_root_dir ON media_files(root_id, directory_id);
        CREATE INDEX IF NOT EXISTS idx_media_folded ON media_files(folded_search_text);
        CREATE INDEX IF NOT EXISTS idx_dirs_root_parent ON directories(root_id, parent_id);
        CREATE INDEX IF NOT EXISTS idx_reasons_origin ON membership_reasons(reason, origin_id);
        CREATE INDEX IF NOT EXISTS idx_aliases_media ON locator_aliases(media_id);
        CREATE INDEX IF NOT EXISTS idx_collection_items_media ON collection_items(media_id);
        CREATE INDEX IF NOT EXISTS idx_scan_runs_root ON scan_runs(root_id, started_at);
        """)
      try database.setUserVersion(Self.schemaVersion)
    }
  }

  // MARK: Async boundary

  private func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        guard !self.closed else {
          continuation.resume(throwing: MediaSourceError.database("catalog closed"))
          return
        }
        do { continuation.resume(returning: try body()) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }

  private func didWrite() {
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .mediaCatalogDidChange, object: nil)
    }
  }

  // MARK: - Roots

  func insertRoot(_ root: MediaSourceRoot) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          INSERT INTO roots
            (id, display_name, provider_kind, bookmark, observed_namespace,
             volume_identity, file_system_type, endpoint_label,
             account_context_label, path_in_namespace, current_mount_hint,
             comparison_semantics, inclusion, created_at,
             last_successful_update, detached_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """)
        statement.bind(1, root.id.uuidString)
        statement.bind(2, root.displayName)
        statement.bind(3, root.kind.rawValue)
        statement.bind(4, root.bookmark)
        statement.bind(5, root.namespace.persistedValue)
        statement.bind(6, root.namespace.volumeIdentity)
        statement.bind(7, root.namespace.fileSystemType)
        statement.bind(8, root.namespace.endpointLabel)
        statement.bind(9, root.namespace.accountContextLabel)
        statement.bind(10, root.pathInNamespace)
        statement.bind(11, root.currentMountHint)
        statement.bind(12, root.comparison.persistedValue)
        statement.bind(13, root.inclusion.rawValue)
        statement.bind(14, root.createdAt.timeIntervalSince1970)
        statement.bind(15, root.lastSuccessfulUpdate?.timeIntervalSince1970)
        statement.bind(16, root.detachedAt?.timeIntervalSince1970)
        try statement.step()
      }
    }
    didWrite()
  }

  /// Only the requested column changes. A caller holding a root read before a
  /// scan or a rename must not be able to write the whole row back.
  func setRootDisplayName(id: UUID, displayName: String) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare(
          "UPDATE roots SET display_name = ? WHERE id = ?")
        statement.bind(1, displayName)
        statement.bind(2, id.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  func setRootInclusion(id: UUID, inclusion: SourceInclusion) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare(
          "UPDATE roots SET inclusion = ? WHERE id = ?")
        statement.bind(1, inclusion.rawValue)
        statement.bind(2, id.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  func roots(includeDetached: Bool = true) async throws -> [MediaSourceRoot] {
    try await perform {
      try self.fetchRootsLocked(includeDetached: includeDetached)
    }
  }

  func root(id: UUID) async throws -> MediaSourceRoot? {
    try await perform {
      try self.fetchRootsLocked(where: "id = ?", bind: { $0.bind(1, id.uuidString) }).first
    }
  }

  func roots(matching namespace: SourceNamespace) async throws -> [MediaSourceRoot] {
    try await perform {
      try self.fetchRootsLocked(where: "observed_namespace = ?",
                                bind: { $0.bind(1, namespace.persistedValue) })
    }
  }

  func detachRoot(id: UUID, at date: Date = Date()) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("UPDATE roots SET detached_at = ? WHERE id = ?")
        statement.bind(1, date.timeIntervalSince1970)
        statement.bind(2, id.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  /// A scan updates only the observed mount hint and its completion time. It
  /// must not rewrite a name, inclusion or detached state that the person
  /// changed while the scan was running.
  func updateRootScanMetadata(id: UUID, mountHint: String?,
                              lastUpdate: Date?) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          UPDATE roots SET
            current_mount_hint = COALESCE(?, current_mount_hint),
            last_successful_update = COALESCE(?, last_successful_update)
          WHERE id = ?
          """)
        statement.bind(1, mountHint)
        statement.bind(2, lastUpdate?.timeIntervalSince1970)
        statement.bind(3, id.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  func restoreRoot(id: UUID) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("UPDATE roots SET detached_at = NULL WHERE id = ?")
        statement.bind(1, id.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  private func fetchRootsLocked(includeDetached: Bool = true) throws -> [MediaSourceRoot] {
    try fetchRootsLocked(where: includeDetached ? nil : "detached_at IS NULL")
  }

  private func fetchRootsLocked(where clause: String?,
                                bind: ((SQLiteStatement) -> Void)? = nil) throws -> [MediaSourceRoot] {
    let sql = """
      SELECT id, display_name, provider_kind, bookmark, observed_namespace,
             path_in_namespace, current_mount_hint, comparison_semantics,
             inclusion, created_at, last_successful_update, detached_at
      FROM roots
      \(clause.map { "WHERE \($0)" } ?? "")
      ORDER BY display_name COLLATE NOCASE, id
      """
    let statement = try database.prepare(sql)
    bind?(statement)
    var result: [MediaSourceRoot] = []
    while try statement.step() {
      guard let namespace = SourceNamespace.decode(statement.text(4) ?? "") else {
        throw MediaSourceError.database("invalid root namespace")
      }
      guard let comparison = ComparisonSemantics(persistedValue: statement.text(7) ?? "") else {
        throw MediaSourceError.database("invalid comparison semantics")
      }
      result.append(MediaSourceRoot(
        id: try statement.uuid(0),
        displayName: statement.text(1) ?? "",
        kind: MediaSourceKind(rawValue: statement.text(2) ?? "") ?? .local,
        bookmark: statement.data(3),
        namespace: namespace,
        pathInNamespace: statement.text(5) ?? "",
        currentMountHint: statement.text(6),
        comparison: comparison,
        inclusion: SourceInclusion(rawValue: statement.text(8) ?? "") ?? .browseOnly,
        createdAt: Date(timeIntervalSince1970: statement.double(9) ?? 0),
        lastSuccessfulUpdate: statement.double(10).map(Date.init(timeIntervalSince1970:)),
        detachedAt: statement.double(11).map(Date.init(timeIntervalSince1970:))))
    }
    return result
  }

  // MARK: - Directories

  func upsertDirectory(rootID: UUID, parentID: UUID?, relativePath: String,
                       comparison: ComparisonSemantics) async throws -> MediaDirectory {
    let directory = try await perform {
      try self.upsertDirectoryLocked(rootID: rootID, parentID: parentID,
                                     relativePath: relativePath, comparison: comparison)
    }
    didWrite()
    return directory
  }

  private func upsertDirectoryLocked(rootID: UUID, parentID: UUID?, relativePath: String,
                                     comparison: ComparisonSemantics) throws -> MediaDirectory {
    let path = SourcePath.normalized(relativePath)
    let key = comparison.key(for: path)
    let select = try database.prepare("""
      SELECT id, root_id, parent_id, relative_path, comparison_key,
             last_successful_generation, last_visited_at, listing_observed_at,
             snapshot_complete, ancestor_absence
      FROM directories WHERE root_id = ? AND comparison_key = ?
      """)
    select.bind(1, rootID.uuidString)
    select.bind(2, key)
    if try select.step() {
      let existing = try directory(from: select)
      let update = try database.prepare("""
        UPDATE directories SET parent_id = ?, relative_path = ? WHERE id = ?
        """)
      update.bind(1, parentID?.uuidString)
      update.bind(2, path)
      update.bind(3, existing.id.uuidString)
      try update.step()
      return MediaDirectory(id: existing.id, rootID: rootID, parentID: parentID,
                            relativePath: path, comparisonKey: key,
                            lastSuccessfulGeneration: existing.lastSuccessfulGeneration,
                            lastVisitedAt: existing.lastVisitedAt,
                            listingObservedAt: existing.listingObservedAt,
                            snapshotComplete: existing.snapshotComplete,
                            ancestorAbsence: existing.ancestorAbsence)
    }
    let id = UUID()
    let insert = try database.prepare("""
      INSERT INTO directories
        (id, root_id, parent_id, relative_path, comparison_key,
         last_successful_generation, last_visited_at, listing_observed_at,
         snapshot_complete, ancestor_absence)
      VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, 0, NULL)
      """)
    insert.bind(1, id.uuidString)
    insert.bind(2, rootID.uuidString)
    insert.bind(3, parentID?.uuidString)
    insert.bind(4, path)
    insert.bind(5, key)
    try insert.step()
    return MediaDirectory(id: id, rootID: rootID, parentID: parentID,
                          relativePath: path, comparisonKey: key,
                          lastSuccessfulGeneration: nil, lastVisitedAt: nil,
                          listingObservedAt: nil, snapshotComplete: false,
                          ancestorAbsence: nil)
  }

  func directory(id: UUID) async throws -> MediaDirectory? {
    try await perform { try self.fetchDirectoriesLocked(where: "id = ?", bind: { $0.bind(1, id.uuidString) }).first }
  }

  func directory(rootID: UUID, relativePath: String,
                 comparison: ComparisonSemantics) async throws -> MediaDirectory? {
    try await perform {
      try self.fetchDirectoriesLocked(where: "root_id = ? AND comparison_key = ?") {
        $0.bind(1, rootID.uuidString)
        $0.bind(2, comparison.key(for: relativePath))
      }.first
    }
  }

  func directories(rootID: UUID, parentID: UUID?) async throws -> [MediaDirectory] {
    try await perform {
      if let parentID {
        return try self.fetchDirectoriesLocked(where: "root_id = ? AND parent_id = ?") {
          $0.bind(1, rootID.uuidString)
          $0.bind(2, parentID.uuidString)
        }
      }
      return try self.fetchDirectoriesLocked(where: "root_id = ? AND parent_id IS NULL") {
        $0.bind(1, rootID.uuidString)
      }
    }
  }

  private func fetchDirectoriesLocked(where clause: String?,
                                      bind: ((SQLiteStatement) -> Void)? = nil) throws -> [MediaDirectory] {
    let sql = """
      SELECT id, root_id, parent_id, relative_path, comparison_key,
             last_successful_generation, last_visited_at, listing_observed_at,
             snapshot_complete, ancestor_absence
      FROM directories
      \(clause.map { "WHERE \($0)" } ?? "")
      ORDER BY relative_path COLLATE NOCASE
      """
    let statement = try database.prepare(sql)
    bind?(statement)
    var result: [MediaDirectory] = []
    while try statement.step() { result.append(try directory(from: statement)) }
    return result
  }

  private func directory(from statement: SQLiteStatement) throws -> MediaDirectory {
    MediaDirectory(
      id: try statement.uuid(0),
      rootID: try statement.uuid(1),
      parentID: statement.text(2).flatMap(UUID.init(uuidString:)),
      relativePath: statement.text(3) ?? "",
      comparisonKey: statement.text(4) ?? "",
      lastSuccessfulGeneration: statement.uint64(5),
      lastVisitedAt: statement.double(6).map(Date.init(timeIntervalSince1970:)),
      listingObservedAt: statement.double(7).map(Date.init(timeIntervalSince1970:)),
      snapshotComplete: statement.bool(8) ?? false,
      ancestorAbsence: statement.text(9))
  }

  func recordDirectorySnapshot(directoryID: UUID, observedAt: Date,
                               complete: Bool, generation: UInt64) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          UPDATE directories
          SET listing_observed_at = MAX(COALESCE(listing_observed_at, 0), ?),
              snapshot_complete = ?,
              last_visited_at = MAX(COALESCE(last_visited_at, 0), ?),
              last_successful_generation = CASE
                WHEN ? THEN MAX(COALESCE(last_successful_generation, 0), ?)
                ELSE last_successful_generation END
          WHERE id = ?
          """)
        statement.bind(1, observedAt.timeIntervalSince1970)
        statement.bind(2, complete)
        statement.bind(3, observedAt.timeIntervalSince1970)
        statement.bind(4, complete)
        statement.bind(5, UInt64(generation))
        statement.bind(6, directoryID.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  // MARK: - Media

  func upsertMedia(rootID: UUID?, directoryID: UUID?, relativePath: String?,
                   comparisonKey: String?, name: String, size: Int64?,
                   modifiedAt: Date?, duration: Double?, presence: MediaPresence,
                   providerFileID: String? = nil,
                   firstDiscoveredAt: Date? = nil) async throws -> UUID {
    let id = try await perform {
      try self.upsertMediaLocked(rootID: rootID, directoryID: directoryID,
                                 relativePath: relativePath, comparisonKey: comparisonKey,
                                 name: name, size: size, modifiedAt: modifiedAt,
                                 duration: duration, presence: presence,
                                 providerFileID: providerFileID,
                                 firstDiscoveredAt: firstDiscoveredAt)
    }
    didWrite()
    return id
  }

  private func upsertMediaLocked(rootID: UUID?, directoryID: UUID?, relativePath: String?,
                                 comparisonKey: String?, name: String, size: Int64?,
                                 modifiedAt: Date?, duration: Double?, presence: MediaPresence,
                                 providerFileID: String?,
                                 firstDiscoveredAt: Date?) throws -> UUID {
    if let rootID, let comparisonKey {
      let select = try database.prepare("SELECT id FROM media_files WHERE root_id = ? AND comparison_key = ?")
      select.bind(1, rootID.uuidString)
      select.bind(2, comparisonKey)
      if try select.step(), let existing = select.text(0) {
        let update = try database.prepare("""
          UPDATE media_files SET directory_id = ?, relative_path = ?, original_name = ?,
            folded_search_text = ?, provider_file_id = COALESCE(?, provider_file_id),
            size = COALESCE(?, size), mtime = COALESCE(?, mtime),
            duration = COALESCE(?, duration), presence = ?
          WHERE id = ?
          """)
        update.bind(1, directoryID?.uuidString)
        update.bind(2, relativePath)
        update.bind(3, name)
        update.bind(4, Self.folded(name))
        update.bind(5, providerFileID)
        update.bind(6, size)
        update.bind(7, modifiedAt?.timeIntervalSince1970)
        update.bind(8, duration)
        update.bind(9, presence.rawValue)
        update.bind(10, existing)
        try update.step()
        guard let uuid = UUID(uuidString: existing) else {
          throw MediaSourceError.database("invalid media UUID")
        }
        return uuid
      }
    }
    let id = UUID()
    let insert = try database.prepare("""
      INSERT INTO media_files
        (id, root_id, directory_id, relative_path, comparison_key, original_name,
         folded_search_text, provider_file_id, size, mtime, duration,
         first_discovered_at, presence, hidden_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
      """)
    insert.bind(1, id.uuidString)
    insert.bind(2, rootID?.uuidString)
    insert.bind(3, directoryID?.uuidString)
    insert.bind(4, relativePath)
    insert.bind(5, comparisonKey)
    insert.bind(6, name)
    insert.bind(7, Self.folded(name))
    insert.bind(8, providerFileID)
    insert.bind(9, size)
    insert.bind(10, modifiedAt?.timeIntervalSince1970)
    insert.bind(11, duration)
    insert.bind(12, (firstDiscoveredAt ?? Date()).timeIntervalSince1970)
    insert.bind(13, presence.rawValue)
    try insert.step()
    return id
  }

  func media(id: UUID) async throws -> CatalogMedia? {
    try await perform { try self.fetchMediaLocked(where: "m.id = ?", bind: { $0.bind(1, id.uuidString) }).first }
  }

  func media(ids: [UUID]) async throws -> [CatalogMedia] {
    guard !ids.isEmpty else { return [] }
    return try await perform {
      let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
      return try self.fetchMediaLocked(where: "m.id IN (\(placeholders))") { statement in
        for (index, id) in ids.enumerated() { statement.bind(Int32(index + 1), id.uuidString) }
      }
    }
  }

  func media(rootID: UUID, comparisonKey: String) async throws -> CatalogMedia? {
    try await perform {
      try self.fetchMediaLocked(where: "m.root_id = ? AND m.comparison_key = ?") {
        $0.bind(1, rootID.uuidString)
        $0.bind(2, comparisonKey)
      }.first
    }
  }

  func setPresence(mediaIDs: [UUID], presence: MediaPresence) async throws {
    guard !mediaIDs.isEmpty else { return }
    try await perform {
      try self.database.transaction {
        let placeholders = Array(repeating: "?", count: mediaIDs.count).joined(separator: ",")
        let statement = try self.database.prepare(
          "UPDATE media_files SET presence = ? WHERE id IN (\(placeholders))")
        statement.bind(1, presence.rawValue)
        for (index, id) in mediaIDs.enumerated() {
          statement.bind(Int32(index + 2), id.uuidString)
        }
        try statement.step()
      }
    }
    didWrite()
  }

  func setHidden(mediaID: UUID, hidden: Bool) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare(
          "UPDATE media_files SET hidden_at = ? WHERE id = ?")
        statement.bind(1, hidden ? Date().timeIntervalSince1970 : nil)
        statement.bind(2, mediaID.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  func setHidden(mediaIDs: [UUID], hidden: Bool) async throws {
    guard !mediaIDs.isEmpty else { return }
    try await perform {
      try self.database.transaction {
        let now = Date().timeIntervalSince1970
        let statement = try self.database.prepare(
          "UPDATE media_files SET hidden_at = ? WHERE id = ?")
        for mediaID in mediaIDs {
          statement.reset()
          statement.bind(1, hidden ? now : nil)
          statement.bind(2, mediaID.uuidString)
          try statement.step()
        }
      }
    }
    didWrite()
  }

  func restoreAllHidden() async throws {
    try await perform {
      try self.database.transaction {
        try self.database.execute(
          "UPDATE media_files SET hidden_at = NULL WHERE hidden_at IS NOT NULL")
      }
    }
    didWrite()
  }

  func setDuration(mediaID: UUID, duration: Double?) async throws {
    guard let duration, duration > 0 else { return }
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare(
          "UPDATE media_files SET duration = ? WHERE id = ?")
        statement.bind(1, duration)
        statement.bind(2, mediaID.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  func updateMediaLocator(mediaID: UUID, rootID: UUID?, directoryID: UUID?,
                          relativePath: String?, comparisonKey: String?,
                          name: String, presence: MediaPresence) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          UPDATE media_files SET root_id = ?, directory_id = ?, relative_path = ?,
            comparison_key = ?, original_name = ?, folded_search_text = ?,
            presence = ? WHERE id = ?
          """)
        statement.bind(1, rootID?.uuidString)
        statement.bind(2, directoryID?.uuidString)
        statement.bind(3, relativePath)
        statement.bind(4, comparisonKey)
        statement.bind(5, name)
        statement.bind(6, Self.folded(name))
        statement.bind(7, presence.rawValue)
        statement.bind(8, mediaID.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  /// Include in Library adds the indexed reason to every catalogued file under
  /// the root, including browse-only rows discovered earlier.
  func addIndexedReasons(rootID: UUID) async throws {
    try await perform {
      try self.database.transaction {
        // Indexed membership is derived from the root's stored state, not
        // from a caller's cached snapshot: a root detached or switched to
        // Browse Only while a scan was in flight must add nothing here.
        let statement = try self.database.prepare("""
          INSERT OR IGNORE INTO membership_reasons (media_id, reason, origin_id)
          SELECT m.id, 'indexed', r.id
          FROM media_files m JOIN roots r ON r.id = m.root_id
          WHERE m.root_id = ? AND r.inclusion = 'indexed' AND r.detached_at IS NULL
          """)
        statement.bind(1, rootID.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  /// Bring a root's derived indexed membership in line with the root's stored
  /// inclusion and attachment in one transaction. Callers that hold a cached
  /// root snapshot can therefore not re-add or remove reasons from stale data.
  func reconcileIndexedReasons(rootID: UUID) async throws {
    try await perform {
      try self.database.transaction {
        let state = try self.database.prepare(
          "SELECT inclusion, detached_at FROM roots WHERE id = ?")
        state.bind(1, rootID.uuidString)
        guard try state.step() else { return }
        let indexed = state.text(0) == SourceInclusion.indexed.rawValue
        let detached = state.double(1) != nil
        if indexed && !detached {
          let insert = try self.database.prepare("""
            INSERT OR IGNORE INTO membership_reasons (media_id, reason, origin_id)
            SELECT m.id, 'indexed', r.id
            FROM media_files m JOIN roots r ON r.id = m.root_id
            WHERE m.root_id = ? AND r.inclusion = 'indexed' AND r.detached_at IS NULL
            """)
          insert.bind(1, rootID.uuidString)
          try insert.step()
        } else {
          let delete = try self.database.prepare("""
            DELETE FROM membership_reasons WHERE reason = 'indexed' AND origin_id = ?
            """)
          delete.bind(1, rootID.uuidString)
          try delete.step()
        }
      }
    }
    didWrite()
  }

  /// Add the derived indexed reason for one row only while that row still
  /// belongs to the root and the root is indexed and attached in the catalog.
  /// A scanner's captured root snapshot may be older than both.
  func addIndexedReasonIfCurrent(mediaID: UUID, rootID: UUID) async throws {
    try await perform {
      try self.database.transaction {
        try self.addIndexedReasonLocked(mediaID: mediaID, rootID: rootID)
      }
    }
    didWrite()
  }

  private func addIndexedReasonLocked(mediaID: UUID, rootID: UUID) throws {
    let statement = try database.prepare("""
      INSERT OR IGNORE INTO membership_reasons (media_id, reason, origin_id)
      SELECT m.id, 'indexed', r.id
      FROM media_files m JOIN roots r ON r.id = m.root_id
      WHERE m.id = ? AND m.root_id = ?
        AND r.inclusion = 'indexed' AND r.detached_at IS NULL
      """)
    statement.bind(1, mediaID.uuidString)
    statement.bind(2, rootID.uuidString)
    try statement.step()
  }

  /// Commit one directory listing in one transaction: child directory rows,
  /// media rows, aliases, collision merges and indexed membership. The
  /// scanner's batch size therefore bounds one transaction and one change
  /// notification instead of a loop of awaited writes.
  func commitDirectoryObservation(
    root: MediaSourceRoot, directoryID: UUID,
    files: [(url: URL, entry: DirectoryEntry, relativePath: String)],
    directories: [(url: URL, relativePath: String)]
  ) async throws -> DirectoryCommitCounts {
    let counts = try await perform {
      try self.database.transaction {
        for child in directories {
          _ = try self.upsertDirectoryLocked(
            rootID: root.id, parentID: directoryID,
            relativePath: child.relativePath, comparison: root.comparison)
        }
        var counts = DirectoryCommitCounts()
        for file in files {
          let key = root.comparison.key(for: file.relativePath)
          let existed = try self.mediaExistsLocked(rootID: root.id,
                                                   comparisonKey: key)
          let mediaID = try self.upsertMediaLocked(
            rootID: root.id, directoryID: directoryID,
            relativePath: file.relativePath, comparisonKey: key,
            name: file.entry.name, size: file.entry.size,
            modifiedAt: file.entry.modified, duration: nil, presence: .present,
            providerFileID: nil, firstDiscoveredAt: nil)
          let aliasKind = file.url.isFileURL ? "filePath" : "url"
          let aliasValue = file.url.isFileURL
            ? file.url.standardizedFileURL.path
            : file.url.absoluteString
          if let owner = try self.addAliasLocked(
            kind: aliasKind, value: aliasValue, mediaID: mediaID,
            namespace: root.namespace.persistedValue, replaceRetired: true),
             owner != mediaID {
            // The locator belongs to a live row, almost always a legacy import
            // from before the catalog. The scanned row has the live root, so
            // retire the other into it; otherwise one file resolves twice.
            if let other = try self.fetchMediaLocked(
              where: "m.id = ?", bind: { $0.bind(1, owner.uuidString) }).first,
               other.rootID == nil || other.rootID == root.id {
              _ = try self.mergeMediaLocked(
                retiredID: owner, survivingID: mediaID,
                operationID: "scan:\(root.id.uuidString):\(aliasValue)")
            } else {
              Logger.log("Scanned locator already belongs to a row under another source; kept both rows.",
                         level: .warning, subsystem: Logger.Sub.mediaScan)
            }
          }
          try self.addIndexedReasonLocked(mediaID: mediaID, rootID: root.id)
          if existed { counts.updated += 1 } else { counts.discovered += 1 }
        }
        return counts
      }
    }
    didWrite()
    return counts
  }

  private func mediaExistsLocked(rootID: UUID, comparisonKey: String) throws -> Bool {
    let select = try database.prepare(
      "SELECT 1 FROM media_files WHERE root_id = ? AND comparison_key = ?")
    select.bind(1, rootID.uuidString)
    select.bind(2, comparisonKey)
    return try select.step()
  }

  func mediaIDs(rootID: UUID) async throws -> [UUID] {
    try await perform {
      let statement = try self.database.prepare(
        "SELECT id FROM media_files WHERE root_id = ?")
      statement.bind(1, rootID.uuidString)
      var result: [UUID] = []
      while try statement.step() {
        if let value = statement.text(0), let uuid = UUID(uuidString: value) {
          result.append(uuid)
        }
      }
      return result
    }
  }

  /// Import one legacy locator atomically: alias lookup, media insert and
  /// alias insert share one transaction, so an interrupted import cannot leave
  /// a media row whose alias is missing and duplicate it on the next run.
  func importLegacyMedia(aliasKind: String, aliasValue: String,
                         name: String, duration: Double?, added: Date,
                         presence: MediaPresence) async throws -> UUID {
    let id = try await perform {
      try self.database.transaction {
        let aliasSelect = try self.database.prepare("""
          SELECT media_id FROM locator_aliases
          WHERE alias_kind = ? AND alias_value = ?
          """)
        aliasSelect.bind(1, aliasKind)
        aliasSelect.bind(2, aliasValue)
        if try aliasSelect.step(), let value = aliasSelect.text(0),
           let existing = UUID(uuidString: value) {
          return existing
        }
        let id = try self.upsertMediaLocked(
          rootID: nil, directoryID: nil, relativePath: nil,
          comparisonKey: nil, name: name, size: nil, modifiedAt: nil,
          duration: duration, presence: presence, providerFileID: nil,
          firstDiscoveredAt: added)
        let aliasInsert = try self.database.prepare("""
          INSERT OR IGNORE INTO locator_aliases
            (alias_kind, alias_value, media_id, observed_namespace, valid_from, retired_at)
          VALUES (?, ?, ?, '', ?, NULL)
          """)
        aliasInsert.bind(1, aliasKind)
        aliasInsert.bind(2, aliasValue)
        aliasInsert.bind(3, id.uuidString)
        aliasInsert.bind(4, Date().timeIntervalSince1970)
        try aliasInsert.step()
        return id
      }
    }
    didWrite()
    return id
  }
  /// Bound the per-root visited-directory cache. Only rows with no membership
  /// reason and no play state are eligible; explicit, history, collection,
  /// favorite, hidden and played rows are never evicted.
  func evictVisitedRows(rootID: UUID, limit: Int = 50_000) async throws {
    guard limit > 0 else { return }
    try await perform {
      try self.database.transaction {
        let countStatement = try self.database.prepare("""
          SELECT COUNT(*) FROM media_files m
          WHERE m.root_id = ?
            AND m.hidden_at IS NULL
            AND NOT EXISTS (SELECT 1 FROM membership_reasons r WHERE r.media_id = m.id)
            AND NOT EXISTS (SELECT 1 FROM play_states p WHERE p.media_id = m.id)
          """)
        countStatement.bind(1, rootID.uuidString)
        guard try countStatement.step(), (countStatement.int(0) ?? 0) > limit else {
          return
        }

        let select = try self.database.prepare("""
          SELECT m.id, m.directory_id FROM media_files m
          LEFT JOIN directories d ON d.id = m.directory_id
          WHERE m.root_id = ?
            AND m.hidden_at IS NULL
            AND NOT EXISTS (SELECT 1 FROM membership_reasons r WHERE r.media_id = m.id)
            AND NOT EXISTS (SELECT 1 FROM play_states p WHERE p.media_id = m.id)
          ORDER BY COALESCE(d.last_visited_at, 0) DESC, m.id DESC
          """)
        select.bind(1, rootID.uuidString)
        var kept = 0
        var evictedDirectories: Set<String> = []
        var evicted: [String] = []
        while try select.step() {
          kept += 1
          if kept <= limit { continue }
          guard let mediaID = select.text(0) else { continue }
          evicted.append(mediaID)
          if let directoryID = select.text(1) { evictedDirectories.insert(directoryID) }
        }
        guard !evicted.isEmpty else { return }
        let delete = try self.database.prepare(
          "DELETE FROM media_files WHERE id = ?")
        for mediaID in evicted {
          delete.reset()
          delete.bind(1, mediaID)
          try delete.step()
        }
        let mark = try self.database.prepare("""
          UPDATE directories SET snapshot_complete = 0 WHERE id = ?
          """)
        for directoryID in evictedDirectories {
          mark.reset()
          mark.bind(1, directoryID)
          try mark.step()
        }
      }
    }
    didWrite()
  }

  func touchMedia(mediaID: UUID, presence: MediaPresence = .present) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare(
          "UPDATE media_files SET presence = ? WHERE id = ?")
        statement.bind(1, presence.rawValue)
        statement.bind(2, mediaID.uuidString)
        try statement.step()
      }
    }
  }

  // MARK: - Aliases

  /// Add an alias. Returns the media row it already pointed at when a live
  /// alias belongs to another row, so callers can resolve a collision instead
  /// of creating a duplicate. With `replaceRetired`, a retired alias owned by
  /// another row is reassigned: the locator stopped describing that row when it
  /// moved, and the file now found there is a new item.
  @discardableResult
  func addAlias(kind: String, value: String, mediaID: UUID,
                namespace: String, replaceRetired: Bool = false) async throws -> UUID? {
    let result: UUID? = try await perform {
      try self.database.transaction {
        try self.addAliasLocked(kind: kind, value: value, mediaID: mediaID,
                                namespace: namespace, replaceRetired: replaceRetired)
      }
    }
    didWrite()
    return result
  }

  /// The alias body, for callers already inside a transaction. Returns the
  /// other owner of a live alias, or nil when this row now owns the locator.
  @discardableResult
  private func addAliasLocked(kind: String, value: String, mediaID: UUID,
                              namespace: String, replaceRetired: Bool) throws -> UUID? {
        let select = try database.prepare("""
          SELECT media_id, retired_at FROM locator_aliases
          WHERE alias_kind = ? AND alias_value = ?
          """)
        select.bind(1, kind)
        select.bind(2, value)
        if try select.step(), let text = select.text(0),
           let owner = UUID(uuidString: text) {
          let retired = select.double(1) != nil
          if owner == mediaID {
            // Re-adopting a previously retired locator: reactivate it rather
            // than leaving the media with no live alias.
            if retired {
              let update = try database.prepare("""
                UPDATE locator_aliases
                SET retired_at = NULL, observed_namespace = ?, valid_from = ?
                WHERE alias_kind = ? AND alias_value = ?
                """)
              update.bind(1, namespace)
              update.bind(2, Date().timeIntervalSince1970)
              update.bind(3, kind)
              update.bind(4, value)
              try update.step()
            }
            return nil
          }
          if retired && replaceRetired {
            let update = try database.prepare("""
              UPDATE locator_aliases
              SET media_id = ?, retired_at = NULL, observed_namespace = ?, valid_from = ?
              WHERE alias_kind = ? AND alias_value = ?
              """)
            update.bind(1, mediaID.uuidString)
            update.bind(2, namespace)
            update.bind(3, Date().timeIntervalSince1970)
            update.bind(4, kind)
            update.bind(5, value)
            try update.step()
            return nil
          }
          return owner
        }
        let statement = try database.prepare("""
          INSERT INTO locator_aliases
            (alias_kind, alias_value, media_id, observed_namespace, valid_from, retired_at)
          VALUES (?, ?, ?, ?, ?, NULL)
          """)
        statement.bind(1, kind)
        statement.bind(2, value)
        statement.bind(3, mediaID.uuidString)
        statement.bind(4, namespace)
        statement.bind(5, Date().timeIntervalSince1970)
        try statement.step()
        return nil
  }

  func resolveAlias(kind: String, value: String) async throws -> UUID? {
    try await perform {
      let statement = try self.database.prepare("""
        SELECT media_id FROM locator_aliases
        WHERE alias_kind = ? AND alias_value = ? AND retired_at IS NULL
        """)
      statement.bind(1, kind)
      statement.bind(2, value)
      guard try statement.step(), let text = statement.text(0) else { return nil }
      return UUID(uuidString: text)
    }
  }

  /// Presence for a batch of live locators, so a library list can mark missing
  /// items without one catalog round trip per row.
  func presence(forAliases aliases: [(kind: String, value: String)])
    async throws -> [String: MediaPresence] {
    try await perform {
      var result: [String: MediaPresence] = [:]
      let statement = try self.database.prepare("""
        SELECT m.presence FROM locator_aliases a
        JOIN media_files m ON m.id = a.media_id
        WHERE a.alias_kind = ? AND a.alias_value = ? AND a.retired_at IS NULL
        """)
      for alias in aliases {
        statement.reset()
        statement.bind(1, alias.kind)
        statement.bind(2, alias.value)
        if try statement.step(), let raw = statement.text(0),
           let presence = MediaPresence(rawValue: raw) {
          result[alias.value] = presence
        }
      }
      return result
    }
  }

  func aliases(for mediaID: UUID) async throws -> [(kind: String, value: String)] {    try await perform {
      let statement = try self.database.prepare("""
        SELECT alias_kind, alias_value FROM locator_aliases
        WHERE media_id = ? AND retired_at IS NULL
        """)
      statement.bind(1, mediaID.uuidString)
      var values: [(String, String)] = []
      while try statement.step() {
        values.append((statement.text(0) ?? "", statement.text(1) ?? ""))
      }
      return values
    }
  }

  func retireAlias(kind: String, value: String) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          UPDATE locator_aliases SET retired_at = ?
          WHERE alias_kind = ? AND alias_value = ?
          """)
        statement.bind(1, Date().timeIntervalSince1970)
        statement.bind(2, kind)
        statement.bind(3, value)
        try statement.step()
      }
    }
    didWrite()
  }

  // MARK: - Membership

  func addReason(mediaID: UUID, reason: MembershipReason, originID: String) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          INSERT OR IGNORE INTO membership_reasons (media_id, reason, origin_id)
          VALUES (?, ?, ?)
          """)
        statement.bind(1, mediaID.uuidString)
        statement.bind(2, reason.rawValue)
        statement.bind(3, originID)
        try statement.step()
      }
    }
    didWrite()
  }

  func removeReason(mediaID: UUID, reason: MembershipReason, originID: String) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          DELETE FROM membership_reasons
          WHERE media_id = ? AND reason = ? AND origin_id = ?
          """)
        statement.bind(1, mediaID.uuidString)
        statement.bind(2, reason.rawValue)
        statement.bind(3, originID)
        try statement.step()
      }
    }
    didWrite()
  }

  func removeReason(mediaID: UUID, reason: MembershipReason) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          DELETE FROM membership_reasons WHERE media_id = ? AND reason = ?
          """)
        statement.bind(1, mediaID.uuidString)
        statement.bind(2, reason.rawValue)
        try statement.step()
      }
    }
    didWrite()
  }

  func reasons(mediaID: UUID) async throws -> Set<MembershipReason> {
    try await perform { try self.reasonsLocked(mediaID: mediaID) }
  }

  private func reasonsLocked(mediaID: UUID) throws -> Set<MembershipReason> {
    let statement = try database.prepare(
      "SELECT reason FROM membership_reasons WHERE media_id = ?")
    statement.bind(1, mediaID.uuidString)
    var result: Set<MembershipReason> = []
    while try statement.step() {
      if let reason = MembershipReason(rawValue: statement.text(0) ?? "") {
        result.insert(reason)
      }
    }
    return result
  }

  func removeReasons(originID: String, reason: MembershipReason? = nil) async throws {
    try await perform {
      try self.database.transaction {
        let sql: String
        if reason != nil {
          sql = "DELETE FROM membership_reasons WHERE origin_id = ? AND reason = ?"
        } else {
          sql = "DELETE FROM membership_reasons WHERE origin_id = ?"
        }
        let statement = try self.database.prepare(sql)
        statement.bind(1, originID)
        if let reason { statement.bind(2, reason.rawValue) }
        try statement.step()
      }
    }
    didWrite()
  }

  // MARK: - Play state

  func playState(mediaID: UUID) async throws -> MediaPlayState? {
    try await perform { try self.playStateLocked(mediaID: mediaID) }
  }

  private func playStateLocked(mediaID: UUID) throws -> MediaPlayState? {
    let statement = try database.prepare("""
      SELECT media_id, observed_position, observed_duration, completed,
             manual_watched_override, last_manual_action_at,
             last_manual_action_kind, observed_at, revision
      FROM play_states WHERE media_id = ?
      """)
    statement.bind(1, mediaID.uuidString)
    guard try statement.step() else { return nil }
    return playState(from: statement)
  }

  private func playState(from statement: SQLiteStatement) -> MediaPlayState? {
    guard let mediaID = statement.text(0).flatMap(UUID.init(uuidString:)) else { return nil }
    return MediaPlayState(
      mediaID: mediaID,
      observedPosition: statement.double(1) ?? 0,
      observedDuration: statement.double(2),
      completed: statement.bool(3) ?? false,
      manualWatchedOverride: statement.bool(4),
      lastManualActionAt: statement.double(5).map(Date.init(timeIntervalSince1970:)),
      lastManualActionKind: statement.text(6).flatMap(ManualActionKind.init(rawValue:)),
      observedAt: Date(timeIntervalSince1970: statement.double(7) ?? 0),
      revision: statement.int64(8) ?? 0)
  }

  func savePlayState(_ state: MediaPlayState) async throws {
    try await perform {
      try self.savePlayStateLocked(state)
    }
    didWrite()
  }

  /// Enqueue a state write synchronously from the main thread. The write is
  /// ahead of any later quit flush in the same serial queue, so the last
  /// observation is not lost when the app terminates.
  func enqueuePlayState(_ state: MediaPlayState) {
    queue.async {
      // The fire-and-forget path must obey the same close contract as every
      // awaited operation.
      guard !self.closed else { return }
      do {
        try self.savePlayStateLocked(state)
        DispatchQueue.main.async {
          NotificationCenter.default.post(name: .mediaCatalogDidChange, object: nil)
        }
      } catch {
        Logger.log("Could not enqueue play state: \(error)", level: .error,
                   subsystem: Logger.Sub.mediaCatalog)
      }
    }
  }

  private func savePlayStateLocked(_ state: MediaPlayState) throws {
    try database.transaction {
      let existing = try playStateLocked(mediaID: state.mediaID)
      let merged = Self.mergePlayState(existing: existing, incoming: state)
      let statement = try database.prepare("""
        INSERT INTO play_states
          (media_id, observed_position, observed_duration, completed,
           manual_watched_override, last_manual_action_at,
           last_manual_action_kind, observed_at, revision)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(media_id) DO UPDATE SET
          observed_position = excluded.observed_position,
          observed_duration = excluded.observed_duration,
          completed = excluded.completed,
          manual_watched_override = excluded.manual_watched_override,
          last_manual_action_at = excluded.last_manual_action_at,
          last_manual_action_kind = excluded.last_manual_action_kind,
          observed_at = excluded.observed_at,
          revision = excluded.revision
        """)
      statement.bind(1, merged.mediaID.uuidString)
      statement.bind(2, merged.observedPosition)
      statement.bind(3, merged.observedDuration)
      statement.bind(4, merged.completed)
      if let override = merged.manualWatchedOverride {
        statement.bind(5, override)
      } else {
        statement.bind(5, nil as Bool?)
      }
      statement.bind(6, merged.lastManualActionAt?.timeIntervalSince1970)
      statement.bind(7, merged.lastManualActionKind?.rawValue)
      statement.bind(8, merged.observedAt.timeIntervalSince1970)
      statement.bind(9, merged.revision + 1)
      try statement.step()
    }
  }

  private static func mergePlayState(existing: MediaPlayState?,
                                     incoming: MediaPlayState) -> MediaPlayState {
    guard let existing else { return incoming }
    var result = incoming
    if existing.observedAt > incoming.observedAt {
      result.observedPosition = existing.observedPosition
      result.observedDuration = existing.observedDuration
      result.completed = existing.completed
      result.observedAt = existing.observedAt
    }
    if let existingManual = existing.lastManualActionAt,
       incoming.lastManualActionAt == nil || existingManual > incoming.lastManualActionAt! {
      result.manualWatchedOverride = existing.manualWatchedOverride
      result.lastManualActionAt = existingManual
      result.lastManualActionKind = existing.lastManualActionKind
    }
    result.revision = max(existing.revision, incoming.revision)
    return result
  }

  func markWatched(mediaID: UUID, watched: Bool) async throws {
    guard watched else {
      try await resetUnwatched(mediaID: mediaID)
      return
    }
    try await perform {
      try self.database.transaction {
        let now = Date()
        let state = MediaPlayState(
          mediaID: mediaID,
          observedPosition: watched ? 0 : 0,
          observedDuration: nil,
          completed: watched,
          manualWatchedOverride: watched,
          lastManualActionAt: now,
          lastManualActionKind: .watched,
          observedAt: now,
          revision: 0)
        let statement = try self.database.prepare("""
          INSERT INTO play_states
            (media_id, observed_position, observed_duration, completed,
             manual_watched_override, last_manual_action_at,
             last_manual_action_kind, observed_at, revision)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
          ON CONFLICT(media_id) DO UPDATE SET
            manual_watched_override = excluded.manual_watched_override,
            completed = excluded.completed,
            last_manual_action_at = excluded.last_manual_action_at,
            last_manual_action_kind = excluded.last_manual_action_kind,
            observed_at = excluded.observed_at,
            revision = play_states.revision + 1
          """)
        statement.bind(1, mediaID.uuidString)
        statement.bind(2, 0.0)
        statement.bind(3, nil as Double?)
        statement.bind(4, watched)
        if let override = state.manualWatchedOverride {
          statement.bind(5, override)
        } else {
          statement.bind(5, nil as Bool?)
        }
        statement.bind(6, now.timeIntervalSince1970)
        statement.bind(7, ManualActionKind.watched.rawValue)
        statement.bind(8, now.timeIntervalSince1970)
        try statement.step()
      }
    }
    didWrite()
  }

  func markWatched(mediaIDs: [UUID], watched: Bool) async throws {
    guard watched else {
      try await resetUnwatched(mediaIDs: mediaIDs)
      return
    }
    guard !mediaIDs.isEmpty else { return }
    try await perform {
      try self.database.transaction {
        let now = Date()
        let statement = try self.database.prepare("""
          INSERT INTO play_states
            (media_id, observed_position, observed_duration, completed,
             manual_watched_override, last_manual_action_at,
             last_manual_action_kind, observed_at, revision)
          VALUES (?, 0, NULL, ?, ?, ?, ?, ?, 1)
          ON CONFLICT(media_id) DO UPDATE SET
            manual_watched_override = excluded.manual_watched_override,
            completed = excluded.completed,
            last_manual_action_at = excluded.last_manual_action_at,
            last_manual_action_kind = excluded.last_manual_action_kind,
            observed_at = excluded.observed_at,
            revision = play_states.revision + 1
          """)
        for mediaID in mediaIDs {
          statement.reset()
          statement.bind(1, mediaID.uuidString)
          statement.bind(2, watched)
          if watched { statement.bind(3, true) } else { statement.bind(3, nil as Bool?) }
          statement.bind(4, now.timeIntervalSince1970)
          statement.bind(5, ManualActionKind.watched.rawValue)
          statement.bind(6, now.timeIntervalSince1970)
          try statement.step()
        }
      }
    }
    didWrite()
  }

  /// A one-time reset. It leaves no persistent false override.
  func resetUnwatched(mediaID: UUID) async throws {
    try await perform {
      try self.database.transaction {
        let now = Date()
        let statement = try self.database.prepare("""
          INSERT INTO play_states
            (media_id, observed_position, observed_duration, completed,
             manual_watched_override, last_manual_action_at,
             last_manual_action_kind, observed_at, revision)
          VALUES (?, 0, NULL, 0, NULL, ?, ?, ?, 1)
          ON CONFLICT(media_id) DO UPDATE SET
            observed_position = 0,
            completed = 0,
            manual_watched_override = NULL,
            last_manual_action_at = excluded.last_manual_action_at,
            last_manual_action_kind = excluded.last_manual_action_kind,
            observed_at = excluded.observed_at,
            revision = play_states.revision + 1
          """)
        statement.bind(1, mediaID.uuidString)
        statement.bind(2, now.timeIntervalSince1970)
        statement.bind(3, ManualActionKind.reset.rawValue)
        statement.bind(4, now.timeIntervalSince1970)
        try statement.step()
      }
    }
    didWrite()
  }

  func resetUnwatched(mediaIDs: [UUID]) async throws {
    guard !mediaIDs.isEmpty else { return }
    try await perform {
      try self.database.transaction {
        let now = Date()
        let statement = try self.database.prepare("""
          INSERT INTO play_states
            (media_id, observed_position, observed_duration, completed,
             manual_watched_override, last_manual_action_at,
             last_manual_action_kind, observed_at, revision)
          VALUES (?, 0, NULL, 0, NULL, ?, ?, ?, 1)
          ON CONFLICT(media_id) DO UPDATE SET
            observed_position = 0,
            completed = 0,
            manual_watched_override = NULL,
            last_manual_action_at = excluded.last_manual_action_at,
            last_manual_action_kind = excluded.last_manual_action_kind,
            observed_at = excluded.observed_at,
            revision = play_states.revision + 1
          """)
        for mediaID in mediaIDs {
          statement.reset()
          statement.bind(1, mediaID.uuidString)
          statement.bind(2, now.timeIntervalSince1970)
          statement.bind(3, ManualActionKind.reset.rawValue)
          statement.bind(4, now.timeIntervalSince1970)
          try statement.step()
        }
      }
    }
    didWrite()
  }

  func clearManualOverride(mediaID: UUID) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          UPDATE play_states SET manual_watched_override = NULL, revision = revision + 1
          WHERE media_id = ?
          """)
        statement.bind(1, mediaID.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  /// Replace one row's play state exactly, or delete it. Used only by Undo so
  /// an exact pre-action snapshot can be restored without manufacturing a new
  /// manual action timestamp.
  func replacePlayState(mediaID: UUID, state: MediaPlayState?) async throws {
    try await perform {
      try self.database.transaction {
        try self.replacePlayStateLocked(mediaID: mediaID, state: state)
      }
    }
    didWrite()
  }

  private func replacePlayStateLocked(mediaID: UUID, state: MediaPlayState?) throws {
    let delete = try database.prepare(
      "DELETE FROM play_states WHERE media_id = ?")
    delete.bind(1, mediaID.uuidString)
    try delete.step()
    guard let state else { return }
    let statement = try database.prepare("""
      INSERT INTO play_states
        (media_id, observed_position, observed_duration, completed,
         manual_watched_override, last_manual_action_at,
         last_manual_action_kind, observed_at, revision)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """)
    statement.bind(1, mediaID.uuidString)
    statement.bind(2, state.observedPosition)
    statement.bind(3, state.observedDuration)
    statement.bind(4, state.completed)
    statement.bind(5, state.manualWatchedOverride)
    statement.bind(6, state.lastManualActionAt?.timeIntervalSince1970)
    statement.bind(7, state.lastManualActionKind?.rawValue)
    statement.bind(8, state.observedAt.timeIntervalSince1970)
    statement.bind(9, state.revision)
    try statement.step()
  }

  /// Restore several exact play states in one transaction. Every row must still
  /// be at the revision the action produced before anything is written, so an
  /// Undo that spans a batch either returns all rows or none.
  func restorePlayStates(_ rows: [(mediaID: UUID, expectedRevision: Int64?,
                                   restore: MediaPlayState?)]) async throws {
    guard !rows.isEmpty else { return }
    try await perform {
      try self.database.transaction {
        for row in rows {
          let current = try self.playStateLocked(mediaID: row.mediaID)
          guard current?.revision == row.expectedRevision else {
            throw MediaSourceError.conflict
          }
        }
        for row in rows {
          try self.replacePlayStateLocked(mediaID: row.mediaID, state: row.restore)
        }
      }
    }
    didWrite()
  }

  func collectionIDs(for mediaID: UUID) async throws -> [UUID] {
    try await perform {
      let statement = try self.database.prepare(
        "SELECT collection_id FROM collection_items WHERE media_id = ?")
      statement.bind(1, mediaID.uuidString)
      var result: [UUID] = []
      while try statement.step() {
        if let value = statement.text(0), let uuid = UUID(uuidString: value) {
          result.append(uuid)
        }
      }
      return result
    }
  }

  /// Clear Playback History removes observed positions/completion while
  /// deliberate manual watched choices remain.
  func clearObservedHistory() async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          UPDATE play_states SET observed_position = 0, completed = 0,
            observed_at = ?, revision = revision + 1
          """)
        statement.bind(1, Date().timeIntervalSince1970)
        try statement.step()
      }
    }
    didWrite()
  }

  // MARK: - Collections

  func createCollection(name: String) async throws -> UUID {
    let id = UUID()
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          INSERT INTO collections (id, name, created_at) VALUES (?, ?, ?)
          """)
        statement.bind(1, id.uuidString)
        statement.bind(2, name)
        statement.bind(3, Date().timeIntervalSince1970)
        try statement.step()
      }
    }
    didWrite()
    return id
  }

  func collections() async throws -> [MediaCollection] {
    try await perform {
      let statement = try self.database.prepare("""
        SELECT c.id, c.name, c.created_at,
               (SELECT COUNT(*) FROM collection_items i WHERE i.collection_id = c.id)
        FROM collections c ORDER BY c.name COLLATE NOCASE
        """)
      var result: [MediaCollection] = []
      while try statement.step() {
        result.append(MediaCollection(
          id: try statement.uuid(0),
          name: statement.text(1) ?? "",
          createdAt: Date(timeIntervalSince1970: statement.double(2) ?? 0),
          itemCount: statement.int(3) ?? 0))
      }
      return result
    }
  }

  func collectionMediaIDs(id: UUID) async throws -> [UUID] {
    try await perform {
      let statement = try self.database.prepare("""
        SELECT media_id FROM collection_items WHERE collection_id = ?
        """)
      statement.bind(1, id.uuidString)
      var result: [UUID] = []
      while try statement.step() {
        if let value = statement.text(0), let uuid = UUID(uuidString: value) {
          result.append(uuid)
        }
      }
      return result
    }
  }

  func addToCollection(collectionID: UUID, mediaIDs: [UUID]) async throws {
    guard !mediaIDs.isEmpty else { return }
    try await perform {
      try self.database.transaction {
        let insert = try self.database.prepare("""
          INSERT OR IGNORE INTO collection_items (collection_id, media_id, added_at)
          VALUES (?, ?, ?)
          """)
        let reason = try self.database.prepare("""
          INSERT OR IGNORE INTO membership_reasons (media_id, reason, origin_id)
          VALUES (?, 'collection', ?)
          """)
        for mediaID in mediaIDs {
          insert.reset()
          insert.bind(1, collectionID.uuidString)
          insert.bind(2, mediaID.uuidString)
          insert.bind(3, Date().timeIntervalSince1970)
          try insert.step()
          reason.reset()
          reason.bind(1, mediaID.uuidString)
          reason.bind(2, collectionID.uuidString)
          try reason.step()
        }
      }
    }
    didWrite()
  }

  func removeFromCollection(collectionID: UUID, mediaIDs: [UUID]) async throws {
    guard !mediaIDs.isEmpty else { return }
    try await perform {
      try self.database.transaction {
        let delete = try self.database.prepare("""
          DELETE FROM collection_items WHERE collection_id = ? AND media_id = ?
          """)
        let reason = try self.database.prepare("""
          DELETE FROM membership_reasons
          WHERE media_id = ? AND reason = 'collection' AND origin_id = ?
          """)
        for mediaID in mediaIDs {
          delete.reset()
          delete.bind(1, collectionID.uuidString)
          delete.bind(2, mediaID.uuidString)
          try delete.step()
          // The reason is scoped to this collection; removing the link must
          // remove this origin even when the item remains in another
          // collection. Other collections keep their own reason rows.
          reason.reset()
          reason.bind(1, mediaID.uuidString)
          reason.bind(2, collectionID.uuidString)
          try reason.step()
        }
      }
    }
    didWrite()
  }

  func renameCollection(id: UUID, name: String) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("UPDATE collections SET name = ? WHERE id = ?")
        statement.bind(1, name)
        statement.bind(2, id.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  func deleteCollection(id: UUID) async throws {
    try await perform {
      try self.database.transaction {
        let ids = try self.database.prepare(
          "SELECT media_id FROM collection_items WHERE collection_id = ?")
        ids.bind(1, id.uuidString)
        var mediaIDs: [String] = []
        while try ids.step() {
          if let value = ids.text(0) { mediaIDs.append(value) }
        }
        for mediaID in mediaIDs {
          let reason = try self.database.prepare("""
            DELETE FROM membership_reasons
            WHERE media_id = ? AND reason = 'collection' AND origin_id = ?
            """)
          reason.bind(1, mediaID)
          reason.bind(2, id.uuidString)
          try reason.step()
        }
        let delete = try self.database.prepare("DELETE FROM collections WHERE id = ?")
        delete.bind(1, id.uuidString)
        try delete.step()
      }
    }
    didWrite()
  }

  // MARK: - Favorites

  func setFavorite(mediaID: UUID, favorite: Bool) async throws {
    if favorite {
      try await addReason(mediaID: mediaID, reason: .favorite, originID: "favorite")
    } else {
      try await removeReason(mediaID: mediaID, reason: .favorite, originID: "favorite")
    }
  }

  func setFavorite(mediaIDs: [UUID], favorite: Bool) async throws {
    guard !mediaIDs.isEmpty else { return }
    try await perform {
      try self.database.transaction {
        if favorite {
          let statement = try self.database.prepare("""
            INSERT OR IGNORE INTO membership_reasons (media_id, reason, origin_id)
            VALUES (?, 'favorite', 'favorite')
            """)
          for mediaID in mediaIDs {
            statement.reset()
            statement.bind(1, mediaID.uuidString)
            try statement.step()
          }
        } else {
          let statement = try self.database.prepare("""
            DELETE FROM membership_reasons
            WHERE media_id = ? AND reason = 'favorite' AND origin_id = 'favorite'
            """)
          for mediaID in mediaIDs {
            statement.reset()
            statement.bind(1, mediaID.uuidString)
            try statement.step()
          }
        }
      }
    }
    didWrite()
  }

  // MARK: - Merge and redirects

  func mergeMedia(retiredID: UUID, survivingID: UUID,
                  operationID: String) async throws -> UUID {
    guard retiredID != survivingID else { return survivingID }
    let survivor = try await perform {
      try self.mergeMediaLocked(retiredID: retiredID, survivingID: survivingID,
                                operationID: operationID)
    }
    didWrite()
    return survivor
  }

  /// Merge and return the survivor's exact snapshot from the same transaction,
  /// so a caller's Undo expectation cannot absorb a later change.
  func mergeMediaAndSnapshot(retiredID: UUID, survivingID: UUID,
                             operationID: String) async throws -> MediaRowSnapshot? {
    guard retiredID != survivingID else {
      return try await snapshot(mediaID: survivingID)
    }
    let result = try await perform {
      try self.database.transaction {
        let survivor = try self.mergeMediaLocked(retiredID: retiredID,
                                                 survivingID: survivingID,
                                                 operationID: operationID)
        return try self.snapshotLocked(mediaID: survivor)
      }
    }
    didWrite()
    return result
  }

  private func mergeMediaLocked(retiredID: UUID, survivingID: UUID,
                                operationID: String) throws -> UUID {
      try database.transaction {
        // Keep the redirect graph acyclic: if the survivor already redirects
        // to the retired row, stop rather than creating a loop.
        var current = survivingID
        var seen: Set<UUID> = []
        while true {
          if current == retiredID { throw MediaSourceError.invalidLocator }
          if !seen.insert(current).inserted { throw MediaSourceError.invalidLocator }
          let next = try self.resolveRedirectLocked(id: current)
          guard let next, next != current else { break }
          current = next
        }

        let reasons = try self.database.prepare("""
          INSERT OR IGNORE INTO membership_reasons (media_id, reason, origin_id)
          SELECT ?, reason, origin_id FROM membership_reasons WHERE media_id = ?
          """)
        reasons.bind(1, survivingID.uuidString)
        reasons.bind(2, retiredID.uuidString)
        try reasons.step()
        let deleteReasons = try self.database.prepare(
          "DELETE FROM membership_reasons WHERE media_id = ?")
        deleteReasons.bind(1, retiredID.uuidString)
        try deleteReasons.step()

        // Indexed membership is derived from the surviving row's root and
        // that root's current inclusion, not unioned from a second root.
        let deleteIndexed = try self.database.prepare("""
          DELETE FROM membership_reasons
          WHERE media_id = ? AND reason = 'indexed'
          """)
        deleteIndexed.bind(1, survivingID.uuidString)
        try deleteIndexed.step()
        let recomputeIndexed = try self.database.prepare("""
          INSERT OR IGNORE INTO membership_reasons (media_id, reason, origin_id)
          SELECT m.id, 'indexed', r.id
          FROM media_files m JOIN roots r ON r.id = m.root_id
          WHERE m.id = ? AND r.inclusion = 'indexed' AND r.detached_at IS NULL
          """)
        recomputeIndexed.bind(1, survivingID.uuidString)
        try recomputeIndexed.step()

        let items = try self.database.prepare("""
          INSERT OR IGNORE INTO collection_items (collection_id, media_id, added_at)
          SELECT collection_id, ?, added_at FROM collection_items WHERE media_id = ?
          """)
        items.bind(1, survivingID.uuidString)
        items.bind(2, retiredID.uuidString)
        try items.step()
        let deleteItems = try self.database.prepare(
          "DELETE FROM collection_items WHERE media_id = ?")
        deleteItems.bind(1, retiredID.uuidString)
        try deleteItems.step()

        let aliases = try self.database.prepare(
          "UPDATE locator_aliases SET media_id = ? WHERE media_id = ?")
        aliases.bind(1, survivingID.uuidString)
        aliases.bind(2, retiredID.uuidString)
        try aliases.step()

        let retiredState = try self.playStateLocked(mediaID: retiredID)
        let survivingState = try self.playStateLocked(mediaID: survivingID)
        if let retiredState {
          let merged = Self.mergePlayState(existing: survivingState, incoming: retiredState)
          let save = try self.database.prepare("""
            INSERT INTO play_states
              (media_id, observed_position, observed_duration, completed,
               manual_watched_override, last_manual_action_at,
               last_manual_action_kind, observed_at, revision)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(media_id) DO UPDATE SET
              observed_position = excluded.observed_position,
              observed_duration = excluded.observed_duration,
              completed = excluded.completed,
              manual_watched_override = excluded.manual_watched_override,
              last_manual_action_at = excluded.last_manual_action_at,
              last_manual_action_kind = excluded.last_manual_action_kind,
              observed_at = excluded.observed_at,
              revision = excluded.revision
            """)
          save.bind(1, survivingID.uuidString)
          save.bind(2, merged.observedPosition)
          save.bind(3, merged.observedDuration)
          save.bind(4, merged.completed)
          if let override = merged.manualWatchedOverride {
            save.bind(5, override)
          } else {
            save.bind(5, nil as Bool?)
          }
          save.bind(6, merged.lastManualActionAt?.timeIntervalSince1970)
          save.bind(7, merged.lastManualActionKind?.rawValue)
          save.bind(8, merged.observedAt.timeIntervalSince1970)
          save.bind(9, merged.revision + 1)
          try save.step()
        }
        let deleteState = try self.database.prepare("DELETE FROM play_states WHERE media_id = ?")
        deleteState.bind(1, retiredID.uuidString)
        try deleteState.step()

        let redirect = try self.database.prepare("""
          INSERT OR REPLACE INTO item_redirects
            (obsolete_media_id, surviving_media_id, operation_id, created_at)
          VALUES (?, ?, ?, ?)
          """)
        redirect.bind(1, retiredID.uuidString)
        redirect.bind(2, survivingID.uuidString)
        redirect.bind(3, operationID)
        redirect.bind(4, Date().timeIntervalSince1970)
        try redirect.step()

        // Older redirects may already point at the retired row. Re-point them
        // at the survivor so chained merges stay resolvable.
        let repoint = try self.database.prepare("""
          UPDATE item_redirects SET surviving_media_id = ?
          WHERE surviving_media_id = ?
          """)
        repoint.bind(1, survivingID.uuidString)
        repoint.bind(2, retiredID.uuidString)
        try repoint.step()

        // Hiding is a person's decision about the item, so it survives a merge
        // in either direction; the survivor's own timestamp wins when both are
        // hidden.
        let carryHidden = try self.database.prepare("""
          UPDATE media_files
          SET hidden_at = COALESCE(hidden_at,
                                   (SELECT hidden_at FROM media_files WHERE id = ?))
          WHERE id = ?
          """)
        carryHidden.bind(1, retiredID.uuidString)
        carryHidden.bind(2, survivingID.uuidString)
        try carryHidden.step()

        let deleteMedia = try database.prepare("DELETE FROM media_files WHERE id = ?")
        deleteMedia.bind(1, retiredID.uuidString)
        try deleteMedia.step()
        return survivingID
      }
  }

  func resolveRedirect(id: UUID) async throws -> UUID? {
    try await perform { try self.resolveRedirectLocked(id: id) }
  }

  func snapshot(mediaID: UUID) async throws -> MediaRowSnapshot? {
    try await perform { try self.snapshotLocked(mediaID: mediaID) }
  }

  private func snapshotLocked(mediaID: UUID) throws -> MediaRowSnapshot? {
      guard let media = try fetchMediaLocked(
        where: "m.id = ?", bind: { $0.bind(1, mediaID.uuidString) }).first else {
        return nil
      }
      let reasonStatement = try database.prepare(
        "SELECT reason, origin_id FROM membership_reasons WHERE media_id = ?")
      reasonStatement.bind(1, mediaID.uuidString)
      var reasonRows: [MediaReasonRow] = []
      while try reasonStatement.step() {
        guard let reason = MembershipReason(rawValue: reasonStatement.text(0) ?? "") else { continue }
        reasonRows.append(MediaReasonRow(reason: reason,
                                         originID: reasonStatement.text(1) ?? ""))
      }
      let collectionStatement = try self.database.prepare(
        "SELECT collection_id, added_at FROM collection_items WHERE media_id = ?")
      collectionStatement.bind(1, mediaID.uuidString)
      var collections: [UUID] = []
      while try collectionStatement.step() {
        if let value = collectionStatement.text(0), let uuid = UUID(uuidString: value) {
          collections.append(uuid)
        }
      }
      let aliasStatement = try self.database.prepare("""
        SELECT alias_kind, alias_value, observed_namespace, valid_from, retired_at
        FROM locator_aliases WHERE media_id = ?
        """)
      aliasStatement.bind(1, mediaID.uuidString)
      var aliases: [MediaAliasRow] = []
      while try aliasStatement.step() {
        aliases.append(MediaAliasRow(
          kind: aliasStatement.text(0) ?? "",
          value: aliasStatement.text(1) ?? "",
          namespace: aliasStatement.text(2) ?? "",
          validFrom: Date(timeIntervalSince1970: aliasStatement.double(3) ?? 0),
          retiredAt: aliasStatement.double(4).map(Date.init(timeIntervalSince1970:))))
      }
      let playState = try self.playStateLocked(mediaID: mediaID)
      let redirect = try self.resolveRedirectLocked(id: mediaID)
      let incomingStatement = try self.database.prepare(
        "SELECT obsolete_media_id FROM item_redirects WHERE surviving_media_id = ?")
      incomingStatement.bind(1, mediaID.uuidString)
      var incomingRedirects: [UUID] = []
      while try incomingStatement.step() {
        if let value = incomingStatement.text(0), let uuid = UUID(uuidString: value) {
          incomingRedirects.append(uuid)
        }
      }
      return MediaRowSnapshot(media: media, reasonRows: reasonRows,
                              collectionIDs: collections, aliases: aliases,
                              playState: playState, redirectID: redirect,
                              incomingRedirectIDs: incomingRedirects)
  }

  /// Restore one exact snapshot. Used by Undo after a merge; it is a normal
  /// transaction, so a failure leaves the current state untouched.
  func restore(_ snapshot: MediaRowSnapshot) async throws {
    try await restore([snapshot])
  }

  /// Restore several rows in one transaction. Undoing a merge must return both
  /// rows or neither: two separate transactions could leave the survivor
  /// restored while the retired row's locator never comes back. Any
  /// `expecting` snapshot is checked inside the same transaction, so a change
  /// that lands between the caller's check and the write still refuses.
  func restore(_ snapshots: [MediaRowSnapshot],
               expecting expected: [MediaRowSnapshot] = []) async throws {
    guard !snapshots.isEmpty else { return }
    let restoredIDs = Set(snapshots.map(\.media.id))
    try await perform {
      try self.database.transaction {
        for row in expected {
          guard let current = try self.snapshotLocked(mediaID: row.media.id),
                current.guards(row) else {
            throw MediaSourceError.conflict
          }
        }
        for snapshot in snapshots {
          try self.restoreLocked(snapshot)
        }
        // Redirects that point at a row this batch touched are handled after
        // every row exists again: restoring a row deletes it, and that cascade
        // removes the redirect rows a merge had re-pointed at it.
        for snapshot in snapshots {
          try self.restoreIncomingRedirectsLocked(snapshot, restoredIDs: restoredIDs)
        }
      }
    }
    didWrite()
  }

  /// Put back the redirects that referred to a restored row. A redirect now
  /// aimed at another row in the same batch was moved by the merge being
  /// undone; one aimed anywhere else belongs to a newer merge and is left
  /// alone. A missing redirect row was cascaded away with its target, so it is
  /// recreated — its obsolete row is normally deleted already, which is what a
  /// redirect records.
  private func restoreIncomingRedirectsLocked(_ snapshot: MediaRowSnapshot,
                                              restoredIDs: Set<UUID>) throws {
    guard !snapshot.incomingRedirectIDs.isEmpty else { return }
    let current = try database.prepare("""
      SELECT surviving_media_id FROM item_redirects WHERE obsolete_media_id = ?
      """)
    let update = try database.prepare("""
      UPDATE item_redirects SET surviving_media_id = ?, operation_id = 'restore'
      WHERE obsolete_media_id = ?
      """)
    let recreate = try database.prepare("""
      INSERT OR IGNORE INTO item_redirects
        (obsolete_media_id, surviving_media_id, operation_id, created_at)
      VALUES (?, ?, 'restore', ?)
      """)
    for obsolete in snapshot.incomingRedirectIDs {
      current.reset()
      current.bind(1, obsolete.uuidString)
      if try current.step(), let text = current.text(0),
         let target = UUID(uuidString: text) {
        guard target != snapshot.media.id, restoredIDs.contains(target) else { continue }
        update.reset()
        update.bind(1, snapshot.media.id.uuidString)
        update.bind(2, obsolete.uuidString)
        try update.step()
      } else {
        recreate.reset()
        recreate.bind(1, obsolete.uuidString)
        recreate.bind(2, snapshot.media.id.uuidString)
        recreate.bind(3, Date().timeIntervalSince1970)
        try recreate.step()
      }
    }
  }

  private func restoreLocked(_ snapshot: MediaRowSnapshot) throws {
        let media = snapshot.media
        // A different row may now occupy the retired locator. Replacing it
        // would cascade away that row's data, so refuse and let the caller
        // offer Relink instead.
        if let rootID = media.rootID, let comparisonKey = media.comparisonKey {
          let occupied = try self.database.prepare("""
            SELECT id FROM media_files
            WHERE root_id = ? AND comparison_key = ? AND id <> ?
            """)
          occupied.bind(1, rootID.uuidString)
          occupied.bind(2, comparisonKey)
          occupied.bind(3, media.id.uuidString)
          if try occupied.step(), let value = occupied.text(0),
             let existing = UUID(uuidString: value) {
            throw MediaSourceError.possibleAlias(existing: existing)
          }
        }
        let deleteRedirect = try self.database.prepare(
          "DELETE FROM item_redirects WHERE obsolete_media_id = ?")
        deleteRedirect.bind(1, media.id.uuidString)
        try deleteRedirect.step()

        let deleteMedia = try self.database.prepare(
          "DELETE FROM media_files WHERE id = ?")
        deleteMedia.bind(1, media.id.uuidString)
        try deleteMedia.step()

        let insert = try self.database.prepare("""
          INSERT INTO media_files
            (id, root_id, directory_id, relative_path, comparison_key,
             original_name, folded_search_text, provider_file_id, size, mtime,
             duration, first_discovered_at, presence, hidden_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """)
        insert.bind(1, media.id.uuidString)
        insert.bind(2, media.rootID?.uuidString)
        insert.bind(3, media.directoryID?.uuidString)
        insert.bind(4, media.relativePath)
        insert.bind(5, media.comparisonKey)
        insert.bind(6, media.name)
        insert.bind(7, media.foldedSearchText)
        insert.bind(8, media.providerFileID)
        insert.bind(9, media.size)
        insert.bind(10, media.modifiedAt?.timeIntervalSince1970)
        insert.bind(11, media.duration)
        insert.bind(12, media.firstDiscoveredAt.timeIntervalSince1970)
        insert.bind(13, media.presence.rawValue)
        insert.bind(14, media.hiddenAt?.timeIntervalSince1970)
        try insert.step()

        let reason = try self.database.prepare("""
          INSERT OR IGNORE INTO membership_reasons (media_id, reason, origin_id)
          VALUES (?, ?, ?)
          """)
        for row in snapshot.reasonRows {
          reason.reset()
          reason.bind(1, media.id.uuidString)
          reason.bind(2, row.reason.rawValue)
          reason.bind(3, row.originID)
          try reason.step()
        }

        for collectionID in snapshot.collectionIDs {
          let exists = try self.database.prepare(
            "SELECT COUNT(*) FROM collections WHERE id = ?")
          exists.bind(1, collectionID.uuidString)
          guard try exists.step(), (exists.int(0) ?? 0) > 0 else { continue }
          let item = try self.database.prepare("""
            INSERT OR IGNORE INTO collection_items (collection_id, media_id, added_at)
            VALUES (?, ?, ?)
            """)
          item.bind(1, collectionID.uuidString)
          item.bind(2, media.id.uuidString)
          item.bind(3, Date().timeIntervalSince1970)
          try item.step()
        }

        let alias = try self.database.prepare("""
          INSERT OR REPLACE INTO locator_aliases
            (alias_kind, alias_value, media_id, observed_namespace, valid_from, retired_at)
          VALUES (?, ?, ?, ?, ?, ?)
          """)
        for row in snapshot.aliases {
          alias.reset()
          alias.bind(1, row.kind)
          alias.bind(2, row.value)
          alias.bind(3, media.id.uuidString)
          alias.bind(4, row.namespace)
          alias.bind(5, row.validFrom.timeIntervalSince1970)
          alias.bind(6, row.retiredAt?.timeIntervalSince1970)
          try alias.step()
        }

        if let state = snapshot.playState {
          let play = try self.database.prepare("""
            INSERT OR REPLACE INTO play_states
              (media_id, observed_position, observed_duration, completed,
               manual_watched_override, last_manual_action_at,
               last_manual_action_kind, observed_at, revision)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
          play.bind(1, state.mediaID.uuidString)
          play.bind(2, state.observedPosition)
          play.bind(3, state.observedDuration)
          play.bind(4, state.completed)
          play.bind(5, state.manualWatchedOverride)
          play.bind(6, state.lastManualActionAt?.timeIntervalSince1970)
          play.bind(7, state.lastManualActionKind?.rawValue)
          play.bind(8, state.observedAt.timeIntervalSince1970)
          play.bind(9, state.revision)
          try play.step()
        }

        if let redirectID = snapshot.redirectID {
          let redirect = try self.database.prepare("""
            INSERT OR REPLACE INTO item_redirects
              (obsolete_media_id, surviving_media_id, operation_id, created_at)
            VALUES (?, ?, ?, ?)
            """)
          redirect.bind(1, media.id.uuidString)
          redirect.bind(2, redirectID.uuidString)
          redirect.bind(3, "restore")
          redirect.bind(4, Date().timeIntervalSince1970)
          try redirect.step()
        }
  }

  private func resolveRedirectLocked(id: UUID) throws -> UUID? {
    var current = id
    var seen: Set<UUID> = []
    var moved = false
    while true {
      guard seen.insert(current).inserted else { return nil }
      let statement = try database.prepare(
        "SELECT surviving_media_id FROM item_redirects WHERE obsolete_media_id = ?")
      statement.bind(1, current.uuidString)
      guard try statement.step(), let value = statement.text(0),
            let next = UUID(uuidString: value) else {
        return moved ? current : nil
      }
      current = next
      moved = true
    }
  }

  // MARK: - Scan runs and absence reviews

  func beginScanRun(rootID: UUID, generation: UInt64) async throws -> UUID {
    let id = UUID()
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          INSERT INTO scan_runs
            (id, root_id, generation, state, started_at, discovered, updated)
          VALUES (?, ?, ?, 'running', ?, 0, 0)
          """)
        statement.bind(1, id.uuidString)
        statement.bind(2, rootID.uuidString)
        statement.bind(3, UInt64(generation))
        statement.bind(4, Date().timeIntervalSince1970)
        try statement.step()
      }
    }
    didWrite()
    return id
  }

  func finishScanRun(id: UUID, state: String, discovered: Int, updated: Int,
                     errorCategory: String?) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          UPDATE scan_runs SET state = ?, ended_at = ?, discovered = ?,
            updated = ?, error_category = ? WHERE id = ?
          """)
        statement.bind(1, state)
        statement.bind(2, Date().timeIntervalSince1970)
        statement.bind(3, discovered)
        statement.bind(4, updated)
        statement.bind(5, errorCategory)
        statement.bind(6, id.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  func setPendingAbsenceReview(_ review: AbsenceReview?, scanRunID: UUID) async throws {
    let value: String?
    if let review {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      value = (try? encoder.encode(review)).flatMap { String(data: $0, encoding: .utf8) }
    } else {
      value = nil
    }
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare(
          "UPDATE scan_runs SET pending_absence_review = ? WHERE id = ?")
        statement.bind(1, value)
        statement.bind(2, scanRunID.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  func pendingAbsenceReview(rootID: UUID) async throws -> AbsenceReview? {
    try await perform {
      let statement = try self.database.prepare("""
        SELECT pending_absence_review FROM scan_runs
        WHERE root_id = ? AND pending_absence_review IS NOT NULL
        ORDER BY started_at DESC LIMIT 1
        """)
      statement.bind(1, rootID.uuidString)
      guard try statement.step(), let value = statement.text(0),
            let data = value.data(using: .utf8) else { return nil }
      return try JSONDecoder().decode(AbsenceReview.self, from: data)
    }
  }

  func clearPendingAbsenceReviews(rootID: UUID) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          UPDATE scan_runs SET pending_absence_review = NULL WHERE root_id = ?
          """)
        statement.bind(1, rootID.uuidString)
        try statement.step()
      }
    }
    didWrite()
  }

  /// Mark rows absent from a complete listing observed at `observedAt`. A
  /// directory observed by a newer visit — even a partial one, which advances
  /// only `listing_observed_at` — is skipped: its rows may already have been
  /// refreshed, and an older listing is not evidence about them.
  func applyAbsence(mediaIDs: [UUID], generation: UInt64,
                    observedAt: Date) async throws {
    guard !mediaIDs.isEmpty else { return }
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          UPDATE media_files SET presence = 'missing'
          WHERE id = ? AND NOT EXISTS (
            SELECT 1 FROM directories d
            WHERE d.id = media_files.directory_id
              AND ((d.last_successful_generation IS NOT NULL
                    AND d.last_successful_generation > ?)
                OR (d.listing_observed_at IS NOT NULL
                    AND d.listing_observed_at > ?))
          )
          """)
        for mediaID in mediaIDs {
          statement.reset()
          statement.bind(1, mediaID.uuidString)
          statement.bind(2, generation)
          statement.bind(3, observedAt.timeIntervalSince1970)
          try statement.step()
        }
      }
    }
    didWrite()
  }

  /// A directory confirmed absent from a complete listing derives absence for
  /// its retained descendants. Rows are kept; only presence and the ancestor
  /// marker change.
  func descendantMediaIDs(directoryID: UUID,
                          presentOnly: Bool = false) async throws -> [UUID] {
    try await perform {
      let select = try self.database.prepare("""
        WITH RECURSIVE subtree(id) AS (
          SELECT ?
          UNION ALL
          SELECT d.id FROM directories d JOIN subtree s ON d.parent_id = s.id
        )
        SELECT id FROM media_files
        WHERE directory_id IN (SELECT id FROM subtree)
          AND (? = 0 OR presence <> 'missing')
        """)
      select.bind(1, directoryID.uuidString)
      select.bind(2, presentOnly ? 1 : 0)
      var ids: [UUID] = []
      while try select.step() {
        if let value = select.text(0), let uuid = UUID(uuidString: value) {
          ids.append(uuid)
        }
      }
      return ids
    }
  }

  func descendantDirectoryIDs(directoryID: UUID) async throws -> [UUID] {
    try await perform {
      let select = try self.database.prepare("""
        WITH RECURSIVE subtree(id) AS (
          SELECT ?
          UNION ALL
          SELECT d.id FROM directories d JOIN subtree s ON d.parent_id = s.id
        )
        SELECT id FROM subtree
        """)
      select.bind(1, directoryID.uuidString)
      var ids: [UUID] = []
      while try select.step() {
        if let value = select.text(0), let uuid = UUID(uuidString: value) {
          ids.append(uuid)
        }
      }
      return ids
    }
  }

  /// Derive absence for a deleted directory's retained descendants. A
  /// descendant directory observed later — by a complete or a partial visit —
  /// keeps its rows and its marker; an older parent listing is not evidence
  /// about it.
  func markDirectoryAbsent(directoryID: UUID, ancestorPath: String,
                           generation: UInt64, observedAt: Date) async throws {
    try await perform {
      try self.database.transaction {
        let select = try self.database.prepare("""
          WITH RECURSIVE subtree(id) AS (
            SELECT ?
            UNION ALL
            SELECT d.id FROM directories d JOIN subtree s ON d.parent_id = s.id
          )
          SELECT id FROM subtree
          """)
        select.bind(1, directoryID.uuidString)
        var ids: [String] = []
        while try select.step() {
          if let value = select.text(0) { ids.append(value) }
        }
        let media = try self.database.prepare("""
          UPDATE media_files SET presence = 'missing'
          WHERE directory_id = ? AND NOT EXISTS (
            SELECT 1 FROM directories d
            WHERE d.id = ?
              AND ((d.last_successful_generation IS NOT NULL
                    AND d.last_successful_generation > ?)
                OR (d.listing_observed_at IS NOT NULL
                    AND d.listing_observed_at > ?))
          )
          """)
        let directory = try self.database.prepare("""
          UPDATE directories SET ancestor_absence = ?, snapshot_complete = 0
          WHERE id = ?
            AND (last_successful_generation IS NULL OR last_successful_generation <= ?)
            AND (listing_observed_at IS NULL OR listing_observed_at <= ?)
          """)
        for id in ids {
          media.reset()
          media.bind(1, id)
          media.bind(2, id)
          media.bind(3, generation)
          media.bind(4, observedAt.timeIntervalSince1970)
          try media.step()
          directory.reset()
          directory.bind(1, ancestorPath)
          directory.bind(2, id)
          directory.bind(3, generation)
          directory.bind(4, observedAt.timeIntervalSince1970)
          try directory.step()
        }
      }
    }
    didWrite()
  }

  func absenceReviewIsCurrent(_ review: AbsenceReview) async throws -> Bool {
    try await perform {
      for directoryID in review.directoryIDs {
        let statement = try self.database.prepare("""
          SELECT last_successful_generation, listing_observed_at
          FROM directories WHERE id = ?
          """)
        statement.bind(1, directoryID.uuidString)
        if try statement.step() {
          if let generation = statement.uint64(0), generation > review.generation {
            return false
          }
          if let observed = statement.double(1),
             observed > review.createdAt.timeIntervalSince1970 {
            return false
          }
        }
      }
      return true
    }
  }

  /// Apply a review only while it is still current. The check and the writes
  /// share one transaction so a newer directory visit cannot slip between them.
  func applyAbsenceReview(_ review: AbsenceReview) async throws {
    try await perform {
      try self.database.transaction {
        // The review must still be the persisted pending review. A dismissed
        // or superseded review must not be replayable.
        let pending = try self.database.prepare("""
          SELECT pending_absence_review FROM scan_runs
          WHERE root_id = ? AND pending_absence_review IS NOT NULL
          ORDER BY started_at DESC LIMIT 1
          """)
        pending.bind(1, review.rootID.uuidString)
        guard try pending.step(), let value = pending.text(0),
              let data = value.data(using: .utf8),
              let stored = try? JSONDecoder().decode(AbsenceReview.self, from: data),
              stored.token == review.token,
              Set(stored.missingMediaIDs) == Set(review.missingMediaIDs),
              Set(stored.directoryIDs) == Set(review.directoryIDs) else {
          throw MediaSourceError.cancelled
        }
        for directoryID in review.directoryIDs {
          let statement = try self.database.prepare("""
            SELECT last_successful_generation, listing_observed_at
            FROM directories WHERE id = ?
            """)
          statement.bind(1, directoryID.uuidString)
          if try statement.step() {
            if let generation = statement.uint64(0), generation > review.generation {
              throw MediaSourceError.cancelled
            }
            if let observed = statement.double(1),
               observed > review.createdAt.timeIntervalSince1970 {
              throw MediaSourceError.cancelled
            }
          }
        }
        for mediaID in review.missingMediaIDs {
          let statement = try self.database.prepare(
            "UPDATE media_files SET presence = 'missing' WHERE id = ?")
          statement.bind(1, mediaID.uuidString)
          try statement.step()
        }
        let clear = try self.database.prepare("""
          UPDATE scan_runs SET pending_absence_review = NULL WHERE root_id = ?
          """)
        clear.bind(1, review.rootID.uuidString)
        try clear.step()
      }
    }
    didWrite()
  }

  // MARK: - Migration state

  func migrationCompleted(_ key: String) async throws -> Bool {
    try await perform {
      let statement = try self.database.prepare(
        "SELECT completed_at FROM migration_state WHERE key = ?")
      statement.bind(1, key)
      guard try statement.step() else { return false }
      return statement.double(0) != nil
    }
  }

  func setMigrationCompleted(_ key: String, value: String? = nil) async throws {
    try await perform {
      try self.database.transaction {
        let statement = try self.database.prepare("""
          INSERT INTO migration_state (key, value, completed_at) VALUES (?, ?, ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value, completed_at = excluded.completed_at
          """)
        statement.bind(1, key)
        statement.bind(2, value)
        statement.bind(3, Date().timeIntervalSince1970)
        try statement.step()
      }
    }
    didWrite()
  }

  // MARK: - Queries

  func libraryMedia(includeHidden: Bool = false) async throws -> [CatalogMedia] {
    try await perform {
      let whereClause = includeHidden
        ? "EXISTS (SELECT 1 FROM membership_reasons mr WHERE mr.media_id = m.id)"
        : "EXISTS (SELECT 1 FROM membership_reasons mr WHERE mr.media_id = m.id) AND m.hidden_at IS NULL"
      return try self.fetchMediaLocked(where: whereClause)
    }
  }

  func directorySnapshot(directoryID: UUID) async throws -> DirectorySnapshot? {
    try await perform {
      guard let directory = try self.fetchDirectoriesLocked(
        where: "id = ?", bind: { $0.bind(1, directoryID.uuidString) }).first else {
        return nil
      }
      let subdirectories = try self.fetchDirectoriesLocked(
        where: "root_id = ? AND parent_id = ?") {
        $0.bind(1, directory.rootID.uuidString)
        $0.bind(2, directory.id.uuidString)
      }
      let items = try self.fetchMediaLocked(where: "m.directory_id = ?") {
        $0.bind(1, directory.id.uuidString)
      }
      return DirectorySnapshot(
        directory: directory,
        subdirectories: subdirectories,
        items: items,
        complete: directory.snapshotComplete,
        observedAt: directory.listingObservedAt,
        generation: directory.lastSuccessfulGeneration)
    }
  }

  func search(term: String, scope: CatalogSearchScope,
              filter: CatalogFilter = .all) async throws -> [CatalogMedia] {
    try await perform {
      let folded = Self.folded(term)
      var clauses: [String] = []
      switch scope {
      case .thisFolder(let directoryID):
        clauses.append("m.directory_id = '\(directoryID.uuidString)'")
      case .indexedRoot(let rootID):
        clauses.append("m.root_id = '\(rootID.uuidString)'")
        clauses.append("EXISTS (SELECT 1 FROM membership_reasons ir WHERE ir.media_id = m.id AND ir.reason = 'indexed')")
      case .allLibrary:
        clauses.append("EXISTS (SELECT 1 FROM membership_reasons ar WHERE ar.media_id = m.id)")
        clauses.append("m.hidden_at IS NULL")
      }
      if !folded.isEmpty {
        clauses.append("m.folded_search_text LIKE ? ESCAPE '\\'")
      }
      switch filter {
      case .all: break
      case .unfinished:
        clauses.append("""
          NOT (COALESCE(p.completed, 0) = 1
            OR COALESCE(p.manual_watched_override, 0) = 1
            OR COALESCE(p.observed_duration > 0
                        AND p.observed_position / p.observed_duration >= 0.97, 0))
          """)
      case .watched:
        // Parenthesized: the clauses are joined with AND, and an ungrouped OR
        // would let the completion test bypass scope and hidden filters.
        clauses.append("""
          (COALESCE(p.completed, 0) = 1
            OR COALESCE(p.manual_watched_override, 0) = 1
            OR COALESCE(p.observed_duration > 0
                        AND p.observed_position / p.observed_duration >= 0.97, 0))
          """)
      case .favorites:
        clauses.append("EXISTS (SELECT 1 FROM membership_reasons fr WHERE fr.media_id = m.id AND fr.reason = 'favorite')")
      case .missing:
        clauses.append("m.presence = 'missing'")
      }
      let whereClause = clauses.isEmpty ? "1" : clauses.joined(separator: " AND ")
      let statement = try self.database.prepare("""
        SELECT m.id, m.root_id, m.directory_id, m.relative_path, m.original_name,
               m.folded_search_text, m.provider_file_id, m.size, m.mtime, m.duration,
               m.first_discovered_at, m.presence, m.hidden_at,
               r.display_name, r.provider_kind, r.current_mount_hint, r.path_in_namespace,
               p.media_id, p.observed_position, p.observed_duration, p.completed,
               p.manual_watched_override, p.last_manual_action_at,
               p.last_manual_action_kind, p.observed_at, p.revision,
               m.comparison_key
        FROM media_files m
        LEFT JOIN roots r ON r.id = m.root_id
        LEFT JOIN play_states p ON p.media_id = m.id
        WHERE \(whereClause)
        ORDER BY m.original_name COLLATE NOCASE
        """)
      if !folded.isEmpty {
        statement.bind(1, "%" + Self.escapeLike(folded) + "%")
      }
      var result: [CatalogMedia] = []
      while try statement.step() {
        result.append(try self.catalogMedia(from: statement))
      }
      try self.attachReasons(to: &result)
      try self.attachLegacyLocators(to: &result)
      return result
    }
  }

  private func fetchMediaLocked(where clause: String,
                                bind: ((SQLiteStatement) -> Void)? = nil) throws -> [CatalogMedia] {
    let statement = try database.prepare("""
      SELECT m.id, m.root_id, m.directory_id, m.relative_path, m.original_name,
             m.folded_search_text, m.provider_file_id, m.size, m.mtime, m.duration,
             m.first_discovered_at, m.presence, m.hidden_at,
             r.display_name, r.provider_kind, r.current_mount_hint, r.path_in_namespace,
             p.media_id, p.observed_position, p.observed_duration, p.completed,
             p.manual_watched_override, p.last_manual_action_at,
             p.last_manual_action_kind, p.observed_at, p.revision,
             m.comparison_key
      FROM media_files m
      LEFT JOIN roots r ON r.id = m.root_id
      LEFT JOIN play_states p ON p.media_id = m.id
      WHERE \(clause)
      ORDER BY m.original_name COLLATE NOCASE
      """)
    bind?(statement)
    var result: [CatalogMedia] = []
    while try statement.step() {
      result.append(try catalogMedia(from: statement))
    }
    try attachReasons(to: &result)
    try attachLegacyLocators(to: &result)
    return result
  }

  /// Rows imported from history/recent documents have no saved root. Their
  /// current locator is the live alias, so the Library can still open them.
  private func attachLegacyLocators(to rows: inout [CatalogMedia]) throws {
    let ids = rows.filter { $0.url == nil }.map(\.id)
    guard !ids.isEmpty else { return }
    var locators: [UUID: (kind: String, value: String)] = [:]
    let chunkSize = 500
    var start = 0
    while start < ids.count {
      let end = min(start + chunkSize, ids.count)
      let chunk = Array(ids[start..<end])
      let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
      let statement = try database.prepare("""
        SELECT media_id, alias_kind, alias_value FROM locator_aliases
        WHERE media_id IN (\(placeholders)) AND retired_at IS NULL
        ORDER BY CASE alias_kind WHEN 'filePath' THEN 0 ELSE 1 END
        """)
      for (index, id) in chunk.enumerated() {
        statement.bind(Int32(index + 1), id.uuidString)
      }
      while try statement.step() {
        guard let value = statement.text(0), let mediaID = UUID(uuidString: value),
              locators[mediaID] == nil else { continue }
        locators[mediaID] = (statement.text(1) ?? "", statement.text(2) ?? "")
      }
      start = end
    }
    for index in rows.indices where rows[index].url == nil {
      guard let locator = locators[rows[index].id] else { continue }
      if locator.kind == "filePath" {
        rows[index].url = URL(fileURLWithPath: locator.value)
      } else {
        rows[index].url = URL(string: locator.value)
      }
    }
  }

  /// Reasons are materialized per row. They are fetched in bounded chunks so a
  /// 50k-row search stays a small number of prepared queries rather than one
  /// query per row.
  private func attachReasons(to rows: inout [CatalogMedia]) throws {
    guard !rows.isEmpty else { return }
    var reasons: [UUID: Set<MembershipReason>] = [:]
    let ids = rows.map(\.id)
    let chunkSize = 500
    var start = 0
    while start < ids.count {
      let end = min(start + chunkSize, ids.count)
      let chunk = Array(ids[start..<end])
      let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
      let statement = try database.prepare("""
        SELECT media_id, reason FROM membership_reasons
        WHERE media_id IN (\(placeholders))
        """)
      for (index, id) in chunk.enumerated() {
        statement.bind(Int32(index + 1), id.uuidString)
      }
      while try statement.step() {
        guard let value = statement.text(0), let mediaID = UUID(uuidString: value),
              let reason = MembershipReason(rawValue: statement.text(1) ?? "") else { continue }
        reasons[mediaID, default: []].insert(reason)
      }
      start = end
    }
    for index in rows.indices {
      rows[index].reasons = reasons[rows[index].id] ?? []
    }
  }

  private func catalogMedia(from statement: SQLiteStatement) throws -> CatalogMedia {
    let rootID = statement.text(1).flatMap(UUID.init(uuidString:))
    let mountHint = statement.text(15)
    let rootPath = statement.text(16)
    let relative = statement.text(3)
    var url: URL?
    if let mountHint, let relative {
      var base = URL(fileURLWithPath: mountHint, isDirectory: true)
      if let rootPath = rootPath, !rootPath.isEmpty {
        for component in SourcePath.normalized(rootPath).split(separator: "/") {
          base.appendPathComponent(String(component), isDirectory: true)
        }
      }
      for component in relative.split(separator: "/") {
        base.appendPathComponent(String(component))
      }
      url = base
    }
    let state: MediaPlayState?
    if let stateMediaID = statement.text(17).flatMap(UUID.init(uuidString:)) {
      state = MediaPlayState(
        mediaID: stateMediaID,
        observedPosition: statement.double(18) ?? 0,
        observedDuration: statement.double(19),
        completed: statement.bool(20) ?? false,
        manualWatchedOverride: statement.bool(21),
        lastManualActionAt: statement.double(22).map(Date.init(timeIntervalSince1970:)),
        lastManualActionKind: statement.text(23).flatMap(ManualActionKind.init(rawValue:)),
        observedAt: Date(timeIntervalSince1970: statement.double(24) ?? 0),
        revision: statement.int64(25) ?? 0)
    } else {
      state = nil
    }
    return CatalogMedia(
      id: try statement.uuid(0),
      rootID: rootID,
      directoryID: statement.text(2).flatMap(UUID.init(uuidString:)),
      relativePath: relative,
      comparisonKey: statement.text(26),
      name: statement.text(4) ?? "",
      foldedSearchText: statement.text(5) ?? "",
      providerFileID: statement.text(6),
      size: statement.int64(7),
      modifiedAt: statement.double(8).map(Date.init(timeIntervalSince1970:)),
      duration: statement.double(9),
      firstDiscoveredAt: Date(timeIntervalSince1970: statement.double(10) ?? 0),
      presence: MediaPresence(rawValue: statement.text(11) ?? "") ?? .unknown,
      hiddenAt: statement.double(12).map(Date.init(timeIntervalSince1970:)),
      reasons: [],
      playState: state,
      rootDisplayName: statement.text(13),
      rootKind: statement.text(14).flatMap(MediaSourceKind.init(rawValue:)),
      url: url)
  }

  // MARK: - Text folding

  static func folded(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
  }

  private static func escapeLike(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }
}
