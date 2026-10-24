import Foundation
import Network
import Darwin

protocol TorrentPieceProviding: Sendable {
  func mediaGeneration() async -> Int
  func mediaSnapshot(hash: String) async throws -> TorrentSnapshot
  func requestPiece(hash: String, piece: Int) async throws
  func mediaFile(snapshot: TorrentSnapshot, file: TorrentFile) async throws -> URL
}
extension TorrentPieceProviding { func mediaGeneration() async -> Int { 0 } }
extension TransmissionRuntime: TorrentPieceProviding {
  func mediaGeneration() async -> Int { runtimeGeneration() }
  func mediaSnapshot(hash: String) async throws -> TorrentSnapshot {
    guard let value = try await find(hash) else { throw TorrentFailure.cancelled }; return value
  }
  func requestPiece(hash: String, piece: Int) async throws {
    try await mutate("torrent_set",hash:hash,["sequential_download":true,"sequential_download_from_piece":piece])
  }
  func mediaFile(snapshot: TorrentSnapshot, file: TorrentFile) async throws -> URL { try secureFile(snapshot,file:file) }
}

/// One stream scheduling owner per hash. A new GET cancels the obsolete GET,
/// including a blocked network write; HEAD does not change piece demand.
final class TorrentMediaBridge: @unchecked Sendable {
  private let provider: any TorrentPieceProviding
  private let hash: String
  let file: TorrentFile
  private let listener: NWListener
  private let queue = DispatchQueue(label:"UniPlayerTorrentMedia")
  private let lock = NSLock()
  private var clients: [UUID: (NWConnection, Task<Void,Never>?)] = [:]
  private var pendingHeaders = Set<UUID>()
  var activeConnectionCount: Int { lock.withLock { clients.count } }
  private var activeRead: UUID?
  private var stopped = false
  private var epoch = 0
  private var localPort: UInt16 = 0
  private let capability = UUID().uuidString.replacingOccurrences(of:"-",with:"") + UUID().uuidString.replacingOccurrences(of:"-",with:"")
  private let readTimeout: TimeInterval
  var url: URL {
    let ext = (file.name as NSString).pathExtension.lowercased()
    return URL(string:"http://127.0.0.1:\(lock.withLock { localPort })/torrent-media/\(capability)/media.\(ext)")!
  }
  private var requestPath: String { URLComponents(url:url,resolvingAgainstBaseURL:false)!.percentEncodedPath }
  init(provider: any TorrentPieceProviding, hash: String, file: TorrentFile, readTimeout: TimeInterval = 60) throws {
    self.provider = provider; self.hash = hash; self.file = file; self.readTimeout = readTimeout
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
    listener = try NWListener(using:parameters)
  }
  func start() async throws {
    epoch = await provider.mediaGeneration()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
      let once = NSLock(); var completed = false
      let finish: (Result<Void,Error>) -> Void = { result in
        let first = once.withLock { if completed { return false }; completed = true; return true }
        if first { continuation.resume(with:result) }
      }
      listener.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          guard let self, let port = self.listener.port else { finish(.failure(TorrentFailure.cancelled)); return }
          self.lock.withLock { self.localPort = port.rawValue }; finish(.success(()))
        case .failed: finish(.failure(TorrentFailure.unavailable("Couldn’t start the local media stream.")))
        case .cancelled: finish(.failure(TorrentFailure.cancelled))
        default: break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
      listener.start(queue:queue)
      queue.asyncAfter(deadline:.now() + 5) { finish(.failure(TorrentFailure.timedOut)) }
    }
  }
  func stop() {
    let connections = lock.withLock { () -> [(NWConnection,Task<Void,Never>?)] in
      stopped = true; let values = Array(clients.values); clients.removeAll(); pendingHeaders.removeAll(); activeRead = nil; return values
    }
    connections.forEach { $0.1?.cancel(); $0.0.cancel() }; listener.cancel()
  }
  deinit { listener.cancel() }
  private func accept(_ connection: NWConnection) {
    let id = UUID()
    let allowed = lock.withLock { () -> Bool in
      guard !stopped, clients.count < 8 else { return false }; clients[id] = (connection,nil); pendingHeaders.insert(id); return true
    }
    guard allowed else { connection.cancel(); return }
    queue.asyncAfter(deadline:.now() + 5) { [weak self,weak connection] in
      guard let self else { return }
      self.lock.withLock { if self.pendingHeaders.contains(id) { self.clients[id]?.1?.cancel(); connection?.cancel() } }
    }
    connection.start(queue:queue)
    let task = Task { [weak self] in
      guard let self else { connection.cancel(); return }
      do { try await serve(connection,id:id) } catch { connection.cancel() }
      self.lock.withLock { self.clients[id] = nil; self.pendingHeaders.remove(id); if self.activeRead == id { self.activeRead = nil } }
      connection.cancel()
    }
    lock.withLock { if clients[id] != nil { clients[id]?.1 = task } else { task.cancel() } }
    connection.stateUpdateHandler = { [weak self] state in
      if case .failed = state { self?.lock.withLock { self?.clients[id]?.1?.cancel() } }
    }
  }
  private func receive(_ connection: NWConnection) async throws -> Data {
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength:1,maximumLength:16384) { data,_,complete,error in
          if error != nil || (complete && (data?.isEmpty ?? true)) { continuation.resume(throwing:TorrentFailure.cancelled) }
          else { continuation.resume(returning:data ?? Data()) }
        }
      }
    }, onCancel: { connection.cancel() })
  }
  private func send(_ bytes: Data, _ connection: NWConnection) async throws {
    try Task.checkCancellation()
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
        connection.send(content:bytes,completion:.contentProcessed { error in
          if error != nil { continuation.resume(throwing:TorrentFailure.cancelled) } else { continuation.resume() }
        })
      }
    }, onCancel: { connection.cancel() })
  }
  private func respond(_ code: Int, _ reason: String, _ connection: NWConnection, extra: String = "") async throws {
    try await send(Data("HTTP/1.1 \(code) \(reason)\r\nConnection: close\r\nContent-Length: 0\r\nCache-Control: no-store\r\n\(extra)\r\n".utf8),connection)
  }
  private func serve(_ connection: NWConnection, id: UUID) async throws {
    var bytes = Data()
    while bytes.range(of:Data("\r\n\r\n".utf8)) == nil {
      bytes += try await receive(connection)
      guard bytes.count <= 16384 else { try await respond(431,"Request Header Fields Too Large",connection); return }
    }
    lock.withLock { pendingHeaders.remove(id) }
    guard let text = String(data:bytes,encoding:.utf8), let header = text.components(separatedBy:"\r\n\r\n").first else { return }
    let lines = header.components(separatedBy:"\r\n")
    let first = lines[0].split(separator:" ")
    guard first.count == 3, ["GET","HEAD"].contains(String(first[0])), first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { try await respond(405,"Method Not Allowed",connection); return }
    guard String(first[1]) == requestPath else { try await respond(404,"Not Found",connection); return }
    var headers: [String:String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of:":") else { try await respond(400,"Bad Request",connection); return }
      let key = line[..<colon].lowercased(), value = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
      guard headers[key] == nil else { try await respond(400,"Bad Request",connection); return }; headers[key] = value
    }
    guard headers["origin"] == nil, headers["transfer-encoding"] == nil, headers["content-length"] == nil || headers["content-length"] == "0",
          headers["host"] == "127.0.0.1:\(lock.withLock { localPort })" else { try await respond(403,"Forbidden",connection); return }
    let range: TorrentByteRange
    do { range = try TorrentByteRange.parse(headers["range"],length:file.length) }
    catch { try await respond(416,"Range Not Satisfiable",connection,extra:"Content-Range: bytes */\(file.length)\r\n"); return }
    if first[0] == "HEAD" {
      try await send(Data(responseHeader(range).utf8),connection); return
    }
    let old = lock.withLock { () -> (NWConnection,Task<Void,Never>?)? in
      let previous = activeRead.flatMap { clients[$0] }; activeRead = id; return previous
    }
    old?.1?.cancel(); old?.0.cancel()
    // This read watches for disconnects while piece waits/writes are blocked.
    connection.receive(minimumIncompleteLength:1,maximumLength:1) { [weak self] _,_,complete,error in
      if complete || error != nil { self?.lock.withLock { self?.clients[id]?.1?.cancel() } }
    }
    var offset = range.start, sentHeader = false
    while offset <= range.end {
      try Task.checkCancellation()
      guard !lock.withLock({ stopped }) else { throw TorrentFailure.cancelled }
      let end = min(range.end,offset + 65535)
      let part = TorrentByteRange(start:offset,end:end,partial:true)
      let data = try await readVerified(part)
      if !sentHeader { try await send(Data(responseHeader(range).utf8),connection); sentHeader = true }
      try await send(data,connection); offset += Int64(data.count)
    }
  }
  private func responseHeader(_ range: TorrentByteRange) -> String {
    let ext = (file.name as NSString).pathExtension.lowercased()
    let mime = ["mp4":"video/mp4","m4v":"video/mp4","mkv":"video/x-matroska","webm":"video/webm","mov":"video/quicktime" ][ext] ?? "application/octet-stream"
    var text = "HTTP/1.1 \(range.partial ? "206 Partial Content" : "200 OK")\r\nAccept-Ranges: bytes\r\nContent-Length: \(range.count)\r\nContent-Type: \(mime)\r\nConnection: close\r\nCache-Control: no-store\r\nCross-Origin-Resource-Policy: same-origin\r\n"
    if range.partial { text += "Content-Range: bytes \(range.start)-\(range.end)/\(file.length)\r\n" }
    return text + "\r\n"
  }
  func readVerified(_ range: TorrentByteRange) async throws -> Data {
    guard range.start >= 0, range.end >= range.start, range.end < file.length, range.count <= 65536 else { throw TorrentFailure.invalidSource }
    let deadline = Date().addingTimeInterval(readTimeout)
    var requested: Int?
    while Date() < deadline {
      try Task.checkCancellation()
      guard await provider.mediaGeneration() == epoch else { throw TorrentFailure.cancelled }
      let snapshot = try await provider.mediaSnapshot(hash:hash)
      guard await provider.mediaGeneration() == epoch else { throw TorrentFailure.cancelled }
      guard snapshot.layoutVerified else { throw TorrentFailure.protocolMismatch }
      guard snapshot.hash == hash, snapshot.files.indices.contains(file.index), snapshot.files[file.index] == file else { throw TorrentFailure.cancelled }
      let pieces = try file.pieces(for:range,pieceSize:snapshot.pieceSize)
      if pieces.allSatisfy(snapshot.hasPiece) {
        let path = try await provider.mediaFile(snapshot:snapshot,file:file)
        let fd = Darwin.open(path.path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
          defer { close(fd) }
          var buffer = [UInt8](repeating:0,count:Int(range.count))
          let size = buffer.withUnsafeMutableBytes { pread(fd,$0.baseAddress!,Int(range.count),off_t(range.start)) }
          if size == Int(range.count) { return Data(buffer) }
        }
        // Completion renames and disk flush must become visible; never serve
        // optimistic zero bytes/EOF from an allocated incomplete file.
      } else if let piece = pieces.first(where:{ !snapshot.hasPiece($0) }), requested != piece {
        try await provider.requestPiece(hash:hash,piece:piece); requested = piece
      }
      try await Task.sleep(for:.milliseconds(100))
    }
    throw TorrentFailure.timedOut
  }
}
