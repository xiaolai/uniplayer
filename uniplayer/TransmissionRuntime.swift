import Foundation
import CryptoKit
import Darwin

actor TransmissionRPCClient {
  private let endpoint: URL
  private let authorization: String
  private let session: URLSession
  private var sessionID = ""
  init(endpoint: URL, username: String, password: String, session: URLSession? = nil) {
    self.endpoint = endpoint
    authorization = "Basic " + Data((username + ":" + password).utf8).base64EncodedString()
    if let session { self.session = session } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
      configuration.timeoutIntervalForRequest = 3; configuration.timeoutIntervalForResource = 5
      self.session = URLSession(configuration: configuration)
    }
  }
  func call(_ method: String, _ parameters: [String: Any] = [:]) async throws -> [String: Any] {
    try Task.checkCancellation()
    if ["torrent_set","torrent_start","torrent_stop","torrent_remove"].contains(method) {
      guard let ids = parameters["ids"] as? [String], ids.count == 1, ids[0].count == 40, ids[0].allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw TorrentFailure.invalidSource }
    }
    guard ["session_get","session_set","torrent_get","torrent_add","torrent_set","torrent_start","torrent_stop","torrent_remove"].contains(method) else { throw TorrentFailure.protocolMismatch }
    for attempt in 0..<2 {
      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"; request.timeoutInterval = 3
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(authorization, forHTTPHeaderField: "Authorization")
      request.setValue(sessionID, forHTTPHeaderField: "X-Transmission-Session-Id")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":1, "method":method, "params":parameters])
      let (data, response) = try await session.data(for: request)
      try Task.checkCancellation()
      guard let response = response as? HTTPURLResponse else { throw TorrentFailure.protocolMismatch }
      if response.statusCode == 409, attempt == 0, let token = response.value(forHTTPHeaderField: "X-Transmission-Session-Id"), token.count < 256 {
        sessionID = token; continue
      }
      guard response.statusCode == 200, data.count <= 8 * 1024 * 1024,
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] == nil,
            let result = json["result"] as? [String: Any] else { throw TorrentFailure.unavailable("Transmission could not complete this request. Check the runtime and tracker status, then retry.") }
      return result
    }
    throw TorrentFailure.protocolMismatch
  }
  func mutate(_ method: String, hash: String, parameters: [String: Any] = [:]) async throws {
    guard hash.count == 40, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }), parameters["ids"] == nil,
          ["torrent_set","torrent_start","torrent_stop","torrent_remove"].contains(method) else { throw TorrentFailure.invalidSource }
    _ = try await call(method, parameters.merging(["ids":[hash]]) { _, required in required })
  }
}

struct TorrentRuntimeSource {
  let hash: String
  let magnet: String?
  let metainfo: Data?
  let isPrivate: Bool?
  init(magnet: String) throws { let parsed = try TorrentMagnet(magnet); hash = parsed.hash; self.magnet = parsed.uri; metainfo = nil; isPrivate = nil }
  init(metainfo: Data) throws { let parsed = try TorrentMetainfo(metainfo); hash = parsed.hash; self.metainfo = metainfo; magnet = nil; isPrivate = parsed.isPrivate }
}

actor TransmissionRuntime {
  static let shared = TransmissionRuntime()
  static let requiredVersion = "4.1.3"
  nonisolated let root: URL
  private let runtimeDirectory: URL
  private let usesPreferences: Bool
  private let quotaOverride: Int64?
  private let ownerToken = UUID().uuidString
  private var process: Process?
  private var shutdownTask: Task<Void,Never>?
  private var lockFD: Int32 = -1
  private var rpc: TransmissionRPCClient?
  private var startup: Task<TransmissionRPCClient, Error>?
  private var generation = 0
  private var stopping = false
  private var terminated = false
  private var reservations: [String: TorrentFile] = [:]
  private var snapshots: [String: (Date, TorrentSnapshot)] = [:]
  private(set) var version = ""
  init(root: URL? = nil, runtimeDirectory: URL? = nil,quotaBytes:Int64? = nil) {
    self.root = root ?? Utility.appSupportDirUrl.appendingPathComponent("TorrentPlayback/v1")
    usesPreferences = root == nil
    quotaOverride = quotaBytes
    self.runtimeDirectory = runtimeDirectory ?? Bundle.main.resourceURL!.appendingPathComponent("TorrentRuntime")
  }
  private func directory(_ url: URL) throws {
    if (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true { throw TorrentFailure.unsafePath }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
    try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: url.path)
  }
  func start() async throws -> TransmissionRPCClient {
    guard !terminated else { throw TorrentFailure.cancelled }
    guard !stopping else { throw TorrentFailure.unavailable("The torrent runtime is stopping. Retry in a moment.") }
    if let rpc, process?.isRunning == true { return rpc }
    if let startup { return try await startup.value }
    if process?.isRunning != true {
      process = nil; rpc = nil; snapshots.removeAll()
      if lockFD >= 0 { close(lockFD); lockFD = -1 }
    }
    generation += 1; let epoch = generation
    let task = Task { try await self.launch(epoch: epoch) }; startup = task
    do { let result = try await task.value; if generation == epoch { startup = nil }; return result }
    catch { if generation == epoch { startup = nil }; throw error }
  }
  private func launch(epoch: Int) async throws -> TransmissionRPCClient {
    let fm = FileManager.default
    let daemon = runtimeDirectory.appendingPathComponent("transmission-daemon")
    let supervisor = runtimeDirectory.appendingPathComponent("TorrentRuntimeSupervisor")
    guard fm.isExecutableFile(atPath: daemon.path), fm.isExecutableFile(atPath: supervisor.path),
          let data = try? Data(contentsOf: runtimeDirectory.appendingPathComponent("manifest.json")),
          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any], manifest["version"] as? String == Self.requiredVersion, manifest["commit"] as? String == "838877323facc4cc2b677fe817e203779c437bb1",
          manifest["patches"] as? [String] == [], let binaries = manifest["builtBinaries"] as? [String: [String: Any]] else {
      throw TorrentFailure.unavailable("The bundled Transmission runtime is missing or does not match this build. Reinstall a complete UniPlayer build.")
    }
    for path in [daemon, supervisor] {
      guard let expected = binaries[path.lastPathComponent]?["sha256"] as? String,
            SHA256.hash(data: try Data(contentsOf: path)).map({ String(format:"%02x",$0) }).joined() == expected else { throw TorrentFailure.protocolMismatch }
    }
    try directory(root)
    let profile = root.appendingPathComponent("runtime"); try directory(profile)
    if let orphan = TorrentProcessOwner.daemon(profile:profile,token:ownerToken) { await orphan.stop() }
    let fd = Darwin.open(profile.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw TorrentFailure.unavailable("Couldn’t lock the torrent runtime profile.") }
    var acquired = false
    for _ in 0..<40 {
      if flock(fd, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
      do { try await Task.sleep(for: .milliseconds(200)); try Task.checkCancellation() } catch { close(fd); throw error }
    }
    guard acquired else { close(fd); throw TorrentFailure.unavailable("Another UniPlayer torrent runtime is still stopping. Retry in a moment.") }
    guard generation == epoch, !stopping, !terminated, !Task.isCancelled else { close(fd); throw TorrentFailure.cancelled }
    lockFD = fd
    var launched:Process?
    do {
      guard let identity = TorrentProcessIdentity.capture(getpid()) else { throw TorrentFailure.cancelled }
      let ownerPath = profile.appendingPathComponent("owner.json")
      try JSONEncoder().encode(TorrentProcessOwner(app:identity,token:ownerToken)).write(to:ownerPath,options:.atomic)
      try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:ownerPath.path)
      try? fm.removeItem(at:profile.appendingPathComponent("daemon.pid"))
      let port = try Self.freePort()
      let password = UUID().uuidString + UUID().uuidString
      let downloadRoot = cacheRoot(); try directory(downloadRoot)
      let settings: [String: Any] = ["rpc_enabled":true,"rpc_bind_address":"127.0.0.1","rpc_port":port,
        "rpc_authentication_required":true,"rpc_username":"uniplayer","rpc_password":password,
        "rpc_whitelist_enabled":true,"rpc_whitelist":"127.0.0.1","rpc_host_whitelist_enabled":true,"rpc_host_whitelist":"localhost",
        "download_dir":downloadRoot.path,"incomplete_dir_enabled":false,"rename_partial_files":false,"preallocation":0,
        "start_added_torrents":false,"download_queue_enabled":false,"seed_queue_enabled":false,"port_forwarding_enabled":false,"peer_port_random_on_start":true,
        "umask":63,"dht_enabled":true,"pex_enabled":true,"lpd_enabled":false,"default_trackers":"","message_level":0]
      let file = profile.appendingPathComponent("settings.json")
      // The isolated profile belongs entirely to this runtime. Transient RPC
      // credentials are never passed in process arguments or persisted in history.
      try JSONSerialization.data(withJSONObject: settings).write(to: file, options: .atomic)
      try fm.setAttributes([.posixPermissions:0o600], ofItemAtPath:file.path)
      let child = Process(); child.executableURL = supervisor
      child.arguments = [String(getpid()), daemon.path, profile.path]
      child.environment = ["PATH":"/usr/bin:/bin", "HOME":profile.path]
      child.standardInput = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
      child.terminationHandler = { [weak self] exited in Task { await self?.supervisorExited(exited) } }
      try child.run(); process = child; launched = child
      let client = TransmissionRPCClient(endpoint: URL(string:"http://127.0.0.1:\(port)/transmission/rpc")!, username:"uniplayer", password:password)
      for _ in 0..<60 {
        guard child.isRunning, generation == epoch else { throw TorrentFailure.cancelled }
        do {
          let session = try await client.call("session_get", ["fields":["version","rpc_version_semver"]])
          guard let actual = session["version"] as? String, actual.hasPrefix(Self.requiredVersion + " "), session["rpc_version_semver"] as? String == "6.0.1" else { throw TorrentFailure.protocolMismatch }
          guard child.isRunning, generation == epoch, !stopping, !terminated, !Task.isCancelled else { throw TorrentFailure.cancelled }
          version = actual; rpc = client
          // --paused prevents previously retained jobs from silently resuming.
          return client
        } catch TorrentFailure.protocolMismatch { throw TorrentFailure.protocolMismatch }
        catch { try await Task.sleep(for: .milliseconds(100)) }
      }
      throw TorrentFailure.timedOut
    } catch {
      if let launched, generation == epoch, process === launched {
        if launched.isRunning { launched.terminate() }
        if let daemon = TorrentProcessOwner.daemon(profile:profile,token:ownerToken) { await daemon.stop() }
        if process === launched { process = nil; rpc = nil }
      }
      if generation == epoch, lockFD == fd { close(fd); lockFD = -1 }; throw error
    }
  }
  private func supervisorExited(_ child:Process) async {
    guard process === child else { return }
    let fd = lockFD
    if let daemon = TorrentProcessOwner.daemon(profile:root.appendingPathComponent("runtime"),token:ownerToken) { await daemon.stop() }
    guard process === child else { return }
    process = nil; rpc = nil; snapshots.removeAll()
    if lockFD == fd, fd >= 0 { close(fd); lockFD = -1 }
  }
  static func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw TorrentFailure.unavailable("Couldn’t create a local torrent endpoint.") }; defer { close(fd) }
    var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
    let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity:1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard status == 0 else { throw TorrentFailure.unavailable("Couldn’t bind a local torrent endpoint.") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    guard withUnsafeMutablePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity:1) { getsockname(fd,$0,&length) } }) == 0 else { throw TorrentFailure.invalidSource }
    return Int(UInt16(bigEndian:address.sin_port))
  }
  func supervisorProcessIdentifier() -> Int32? { process?.processIdentifier }
  func isRunning() -> Bool { process?.isRunning == true }
  func runtimeGeneration() -> Int { generation }
  func cacheRoot() -> URL {
    if usesPreferences, let custom = UserDefaults.standard.string(forKey: TorrentPreferences.cachePath), !custom.isEmpty { return URL(fileURLWithPath:custom, isDirectory:true).appendingPathComponent("UniPlayerTorrents", isDirectory:true) }
    return root.appendingPathComponent("cache", isDirectory:true)
  }
  func add(_ source: TorrentRuntimeSource) async throws -> (TorrentSnapshot, Bool) {
    let client = try await start()
    if let existing = try await find(source.hash, fresh: true) { return (existing, true) }
    let folder = cacheRoot().appendingPathComponent(source.hash, isDirectory:true); try directory(folder)
    var parameters: [String: Any] = ["paused":true,"download_dir":folder.path,"sequential_download":true,"peer_limit":30]
    if let bytes = source.metainfo { parameters["metainfo"] = bytes.base64EncodedString() }
    else if let uri = source.magnet { parameters["filename"] = uri }
    else { throw TorrentFailure.invalidSource }
    let response = try await client.call("torrent_add", parameters)
    let existed = response["torrent_duplicate"] != nil
    guard response["torrent_added"] != nil || existed, let value = try await find(source.hash, fresh:true) else { throw TorrentFailure.protocolMismatch }
    if let data = source.metainfo {
      let parsed = try TorrentMetainfo(data)
      guard parsed.files.count == value.files.count, zip(parsed.files,value.files).allSatisfy({ pair in pair.0.index == pair.1.index && pair.0.length == pair.1.length && pair.0.offset == pair.1.offset }) else { throw TorrentFailure.protocolMismatch }
    }
    return (value, existed)
  }
  func find(_ hash: String, fresh: Bool = false) async throws -> TorrentSnapshot? {
    guard hash.count == 40, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw TorrentFailure.invalidSource }
    if !fresh, let cached = snapshots[hash], Date().timeIntervalSince(cached.0) < 0.15 { return cached.1 }
    let client = try await start()
    let response = try await client.call("torrent_get", ["ids":[hash],"fields":TorrentSnapshot.fields])
    guard let values = response["torrents"] as? [[String:Any]], values.count <= 1 else { throw TorrentFailure.protocolMismatch }
    guard let value = values.first else { snapshots[hash] = nil; return nil }
    let snapshot = try TorrentSnapshot(json:value)
    guard !snapshot.metadataComplete || (snapshot.layoutVerified && snapshot.wanted.count == snapshot.files.count) else { throw TorrentFailure.protocolMismatch }
    snapshots[hash] = (Date(),snapshot); return snapshot
  }
  func all() async throws -> [TorrentSnapshot] {
    let client = try await start()
    let response = try await client.call("torrent_get", ["fields":TorrentSnapshot.fields])
    guard let values = response["torrents"] as? [[String:Any]], values.count <= 1000 else { throw TorrentFailure.protocolMismatch }
    return try values.map { value in
      let snapshot = try TorrentSnapshot(json:value)
      guard !snapshot.metadataComplete || (snapshot.layoutVerified && snapshot.wanted.count == snapshot.files.count) else { throw TorrentFailure.protocolMismatch }
      return snapshot
    }
  }
  func summaries(hash:String? = nil) async throws -> [TorrentTransferSummary] {
    let client = try await start()
    var parameters: [String:Any] = ["fields":TorrentTransferSummary.fields]
    if let hash {
      guard hash.count == 40, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw TorrentFailure.invalidSource }
      parameters["ids"] = [hash]
    }
    let response = try await client.call("torrent_get",parameters)
    guard let values = response["torrents"] as? [[String:Any]], values.count <= (hash == nil ? 1000 : 1) else { throw TorrentFailure.protocolMismatch }
    return try values.map(TorrentTransferSummary.init(json:))
  }
  func mutate(_ method: String, hash: String, _ parameters: [String:Any] = [:]) async throws {
    let client = try await start(); try await client.mutate(method, hash:hash, parameters:parameters); snapshots[hash] = nil
  }
  func inspect(_ hash: String, knownMetadata: Bool) async throws {
    let parameters: [String:Any] = knownMetadata ? ["files_unwanted":[]] : ["download_limited":true,"download_limit":64]
    try await mutate("torrent_set",hash:hash,parameters)
    try await mutate("torrent_start",hash:hash)
  }
  func prepare(_ snapshot: TorrentSnapshot, file: TorrentFile) async throws {
    guard !snapshot.clientVersionRejected else { throw TorrentFailure.unavailable("Client Version Not Approved. Use a genuine runtime version allowed by this tracker.") }
    try await admit(snapshot, file:file)
    reservations[snapshot.hash] = file
    try await mutate("torrent_set", hash:snapshot.hash,["files_unwanted":[],"download_limited":false,"sequential_download":true])
    try await mutate("torrent_set", hash:snapshot.hash,["files_wanted":[file.index],"sequential_download_from_piece":Int(file.offset / snapshot.pieceSize)])
    try await mutate("torrent_start", hash:snapshot.hash)
  }
  func admit(_ snapshot: TorrentSnapshot, file: TorrentFile) async throws {
    guard file.playable, file.length > 0 else { throw TorrentFailure.unsupportedMedia }
    let folder = cacheRoot(); try directory(folder)
    let attrs = try FileManager.default.attributesOfFileSystem(forPath:folder.path)
    let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    let quotaGiB = min(500,max(1, UserDefaults.standard.object(forKey:TorrentPreferences.quotaGiB) as? Int ?? 50))
    let quota = quotaOverride ?? Int64(quotaGiB) * 1024 * 1024 * 1024
    let usage = try Self.allocatedBytes(folder)
    // Already-allocated bytes for this file do not require a second reservation.
    let existing = (try? secureFile(snapshot, file:file).resourceValues(forKeys:[.totalFileAllocatedSizeKey]).totalFileAllocatedSize).map(Int64.init) ?? 0
    var remaining: Int64 = 0
    for (hash, reserved) in reservations where hash != snapshot.hash {
      let path = folder.appendingPathComponent(hash).appendingPathComponent(reserved.name)
      let allocated = Int64((try? path.resourceValues(forKeys:[.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
      let needed = max(0,reserved.length-allocated)
      guard remaining <= Int64.max-needed else { throw TorrentFailure.diskSpace }; remaining += needed
    }
    let needed = max(0,file.length-existing)
    guard remaining <= quota, needed <= quota-remaining, usage <= quota-remaining-needed, free > remaining+needed+2*1024*1024*1024 else { throw TorrentFailure.diskSpace }
  }
  func releaseReservation(_ hash: String) { reservations[hash] = nil }
  func checkDiskReserve() throws {
    let free = (try FileManager.default.attributesOfFileSystem(forPath:cacheRoot().path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    guard free > 2*1024*1024*1024 else { throw TorrentFailure.diskSpace }
  }
  func stop(_ hash: String) async throws {
    try await mutate("torrent_stop",hash:hash)
    for _ in 0..<50 {
      if try await find(hash,fresh:true)?.status ?? 0 == 0 { reservations[hash] = nil; return }
      try await Task.sleep(for:.milliseconds(100))
    }
    throw TorrentFailure.timedOut
  }
  func stopInspection(_ hash: String) async {
    guard process?.isRunning == true, !stopping else { return }
    // Cleanup must run even when the task that initiated inspection is cancelled.
    await Task { try? await self.stop(hash) }.value
  }
  static func allocatedBytes(_ directory: URL) throws -> Int64 {
    guard let files = FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.totalFileAllocatedSizeKey], options:[.skipsHiddenFiles]) else { return 0 }
    var total: Int64 = 0, count = 0
    for case let path as URL in files {
      count += 1; guard count <= 100000 else { throw TorrentFailure.diskSpace }
      let values = try path.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.totalFileAllocatedSizeKey])
      if values.isSymbolicLink == true { files.skipDescendants(); continue }
      if values.isRegularFile == true { total += Int64(values.totalFileAllocatedSize ?? 0) }
    }
    return total
  }
  func secureFile(_ snapshot: TorrentSnapshot, file: TorrentFile) throws -> URL {
    let expected = cacheRoot().appendingPathComponent(snapshot.hash, isDirectory:true).standardizedFileURL
    guard URL(fileURLWithPath:snapshot.downloadDirectory).standardizedFileURL == expected, TorrentFile.safePath(file.name) else { throw TorrentFailure.unsafePath }
    let path = expected.appendingPathComponent(file.name).standardizedFileURL
    guard path.path.hasPrefix(expected.path + "/") else { throw TorrentFailure.unsafePath }
    for folder in [cacheRoot(),expected] { if (try? folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true { throw TorrentFailure.unsafePath } }
    var part = expected
    for component in file.name.split(separator:"/") {
      part.appendPathComponent(String(component))
      if let values = try? part.resourceValues(forKeys:[.isSymbolicLinkKey]), values.isSymbolicLink == true { throw TorrentFailure.unsafePath }
    }
    return path
  }
  struct Configuration {
    let snapshot: TorrentSnapshot
    let reserved: TorrentFile?
  }
  func configuration(_ hash:String) async throws -> Configuration {
    guard let snapshot = try await find(hash,fresh:true) else { throw TorrentFailure.cancelled }
    return Configuration(snapshot:snapshot,reserved:reservations[hash])
  }
  func restore(_ configuration:Configuration) async throws {
    let value = configuration.snapshot
    try await mutate("torrent_set",hash:value.hash,["files_unwanted":[],"download_limited":value.downloadLimited,"download_limit":value.downloadLimit,"sequential_download":value.sequential,"sequential_download_from_piece":value.sequentialFromPiece])
    let wanted = value.wanted.enumerated().filter { $0.element }.map(\.offset)
    if !wanted.isEmpty { try await mutate("torrent_set",hash:value.hash,["files_wanted":wanted]) }
    if value.status == 0 { try await stop(value.hash) } else { try await mutate("torrent_start",hash:value.hash) }
    reservations[value.hash] = configuration.reserved
  }
  func discardInspection(_ hash:String) async {
    guard !terminated, !stopping, process?.isRunning == true, reservations[hash] == nil else { return }
    await Task {
      guard let value = try? await self.summaries(hash:hash).first, self.reservationFree(hash) else { return }
      try? await self.removeStopped(hash,deleteData:value.metadataComplete && !value.isPrivate)
    }.value
  }
  private func reservationFree(_ hash:String) -> Bool { reservations[hash] == nil }
  func removeStopped(_ hash:String,deleteData:Bool) async throws {
    guard reservations[hash] == nil, let value = try await summaries(hash:hash).first, value.status == 0 else { throw TorrentFailure.unavailable("Stop the torrent and close its player before removing it.") }
    let folder = cacheRoot().appendingPathComponent(hash,isDirectory:true).standardizedFileURL
    guard folder.path == value.downloadDirectory, (try? folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else { throw TorrentFailure.unsafePath }
    if deleteData && (!value.metadataComplete || value.isPrivate) { throw TorrentFailure.unavailable("Private or unclassified retained data is protected. Remove its client entry while keeping the files, or manage its files explicitly in Finder.") }
    try await mutate("torrent_remove",hash:hash,["delete_local_data":false])
    for _ in 0..<30 {
      if try await summaries(hash:hash).isEmpty {
        if deleteData && FileManager.default.fileExists(atPath:folder.path) { try FileManager.default.removeItem(at:folder) }
        return
      }
      try await Task.sleep(for:.milliseconds(100))
    }
    throw TorrentFailure.timedOut
  }
  func finish() async { terminated = true; await shutdown() }
  func shutdown() async {
    if let shutdownTask { await shutdownTask.value; return }
    stopping = true
    let task = Task { await self.performShutdown() }; shutdownTask = task
    await task.value
  }
  private func performShutdown() async {
    defer { shutdownTask = nil; stopping = false }
    generation += 1; startup?.cancel(); startup = nil; rpc = nil; snapshots.removeAll(); reservations.removeAll()
    let child = process; process = nil
    let profile = root.appendingPathComponent("runtime")
    var daemon = TorrentProcessOwner.daemon(profile:profile,token:ownerToken)
    daemon?.signal(SIGTERM)
    if child?.isRunning == true { child?.terminate() }
    for iteration in 0..<70 {
      if daemon == nil, let discovered = TorrentProcessOwner.daemon(profile:profile,token:ownerToken) { daemon = discovered; discovered.signal(SIGTERM) }
      if child?.isRunning != true && daemon?.isRunning != true && iteration >= 10 { break }
      try? await Task.sleep(for:.milliseconds(100))
    }
    if child?.isRunning == true { kill(child!.processIdentifier,SIGKILL) }
    daemon?.signal(SIGKILL)
    if lockFD >= 0 { close(lockFD); lockFD = -1 }
  }
}

enum TorrentPreferences {
  static let mini4KPosts = "torrent.playback.mini4KPosts.experimental.v1"
  static let crossOriginDownloads = "torrent.playback.crossOriginDownloads.unqualified.v1"
  static let enabledKey = "torrent.playback.enabled.v1"
  static let quotaGiB = "torrent.playback.quotaGiB.v1"
  static let cachePath = "torrent.playback.cachePath.v1"
  static let changed = Notification.Name("TorrentPlaybackSettingsChanged")
  static var enabled: Bool {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: enabledKey) != nil else { return true }
    return defaults.bool(forKey: enabledKey)
  }
  static var mini4KPostsEnabled: Bool {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: mini4KPosts) != nil else { return true }
    return defaults.bool(forKey: mini4KPosts)
  }
  static func allowed(host: String) -> Bool { let key = "torrent.playback.disabledHosts.v1"; return !(UserDefaults.standard.stringArray(forKey:key) ?? []).contains(host.lowercased()) }
}
