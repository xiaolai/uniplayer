//
//  CloudDriveFixtureServer.swift
//  UniPlayerTests
//
//  A loopback HTTP/1.1 server for cloud-drive tests. It never contacts a real
//  drive: it serves generated WAV bytes with Range support, a signed URL that
//  expires, and an endpoint that echoes the request headers it received.
//

import Foundation
import Network

final class CloudDriveFixtureServer {
  struct RecordedRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
  }

  enum FixtureError: Error {
    case cannotStart
  }

  private let listener: NWListener
  private let queue = DispatchQueue(label: "CloudDriveFixtureServer")
  private let lock = NSLock()
  private var recorded: [RecordedRequest] = []
  private var connections: [NWConnection] = []
  private let media: Data
  private(set) var port: UInt16 = 0

  var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

  init(media: Data = CloudDriveFixtureServer.wav(duration: 3)) throws {
    self.media = media
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    parameters.allowLocalEndpointReuse = true
    listener = try NWListener(using: parameters)

    var assigned: UInt16 = 0
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { [listener] state in
      switch state {
      case .ready:
        assigned = listener.port?.rawValue ?? 0
        ready.signal()
      case .failed:
        ready.signal()
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, assigned != 0 else {
      listener.cancel()
      throw FixtureError.cannotStart
    }
    self.port = assigned
  }

  deinit { stop() }

  func stop() {
    listener.cancel()
    lock.lock()
    let open = connections
    connections = []
    lock.unlock()
    open.forEach { $0.cancel() }
  }

  func requests(matching pathPrefix: String = "/") -> [RecordedRequest] {
    lock.lock(); defer { lock.unlock() }
    return recorded.filter { $0.path.hasPrefix(pathPrefix) }
  }

  // MARK: - Connections

  private func accept(_ connection: NWConnection) {
    lock.lock(); connections.append(connection); lock.unlock()
    connection.stateUpdateHandler = { [weak self] state in
      if case .ready = state { self?.receive(on: connection, buffer: Data()) }
    }
    connection.start(queue: queue)
  }

  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      if buffer.count > 1 * 1024 * 1024 {
        connection.cancel()
        return
      }
      if let request = Self.parse(buffer) {
        self.respond(request, on: connection)
        return
      }
      if isComplete || error != nil {
        connection.cancel()
        return
      }
      self.receive(on: connection, buffer: buffer)
    }
  }

  private struct ParsedRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
  }

  private static func parse(_ data: Data) -> ParsedRequest? {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerEnd = data.range(of: separator) else { return nil }
    let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
    let lines = head.components(separatedBy: "\r\n")
    guard let first = lines.first else { return nil }
    let parts = first.split(separator: " ")
    guard parts.count >= 2 else { return nil }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }

    let length = Int(headers["content-length"] ?? "0") ?? 0
    let start = headerEnd.upperBound
    guard data.count - start >= length else { return nil }
    return ParsedRequest(
      method: String(parts[0]), path: String(parts[1]), headers: headers,
      body: data.subdata(in: start..<(start + length)))
  }

  // MARK: - Routing

  private func respond(_ request: ParsedRequest, on connection: NWConnection) {
    lock.lock()
    recorded.append(RecordedRequest(
      method: request.method, path: request.path,
      headers: request.headers, body: request.body))
    lock.unlock()

    let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
    switch path {
    case "/echo":
      echo(request, on: connection)
    case "/media":
      mediaResponse(request, on: connection, requireExpiry: false)
    case "/signed":
      mediaResponse(request, on: connection, requireExpiry: true)
    case "/redirect":
      let query = URLComponents(string: "http://127.0.0.1" + request.path)?.queryItems ?? []
      let target = query.first { $0.name == "to" }?.value ?? "/echo"
      send(status: 302, reason: "Found", headers: ["Location": target],
           body: Data(), on: connection)
    default:
      send(status: 404, reason: "Not Found", headers: [:],
           body: Data("not found".utf8), on: connection)
    }
  }

  private func echo(_ request: ParsedRequest, on connection: NWConnection) {
    let payload: [String: Any] = [
      "method": request.method,
      "path": request.path,
      "headers": request.headers,
      "body": String(decoding: request.body, as: UTF8.self),
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    send(status: 200, reason: "OK", headers: ["Content-Type": "application/json"],
         body: data, on: connection)
  }

  private func mediaResponse(_ request: ParsedRequest, on connection: NWConnection,
                             requireExpiry: Bool) {
    if requireExpiry {
      let query = URLComponents(string: "http://127.0.0.1" + request.path)?.queryItems ?? []
      let expires = query.first { $0.name == "expires" }?.value.flatMap { Double($0) } ?? 0
      let deadline = expires > 100_000_000_000 ? expires / 1_000 : expires
      guard Date().timeIntervalSince1970 < deadline else {
        send(status: 403, reason: "Forbidden", headers: [:],
             body: Data("expired".utf8), on: connection)
        return
      }
    }

    let total = media.count
    var headers: [String: String] = [
      "Content-Type": "audio/wav",
      "Accept-Ranges": "bytes",
    ]
    var status = 200
    var reason = "OK"
    var body = media

    if let range = request.headers["range"] {
      guard let slice = Self.slice(media, range: range) else {
        send(status: 416, reason: "Range Not Satisfiable",
             headers: ["Content-Range": "bytes */\(total)"],
             body: Data(), on: connection)
        return
      }
      status = 206
      reason = "Partial Content"
      body = slice.data
      headers["Content-Range"] = "bytes \(slice.start)-\(slice.end)/\(total)"
    }

    send(status: status, reason: reason, headers: headers, body: body, on: connection)
  }

  private static func slice(_ data: Data, range: String) -> (start: Int, end: Int, data: Data)? {
    guard range.lowercased().hasPrefix("bytes=") else { return nil }
    let value = range.dropFirst("bytes=".count)
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let total = data.count
    if parts[0].isEmpty, let suffix = Int(parts[1]), suffix > 0 {
      let start = max(0, total - suffix)
      return (start, total - 1, data.subdata(in: start..<total))
    }
    guard let start = Int(parts[0]), start < total else { return nil }
    let end = parts[1].isEmpty ? total - 1 : min(total - 1, Int(parts[1]) ?? total - 1)
    guard end >= start else { return nil }
    return (start, end, data.subdata(in: start..<(end + 1)))
  }

  private func send(status: Int, reason: String, headers: [String: String],
                    body: Data, on connection: NWConnection) {
    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Connection: close\r\n"
    for (name, value) in headers { head += "\(name): \(value)\r\n" }
    head += "\r\n"
    var payload = Data(head.utf8)
    payload.append(body)
    connection.send(content: payload, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  // MARK: - Media

  /// A 16-bit mono PCM WAV. Generated in code so the test carries no binary
  /// asset and mpv gets a real seekable stream.
  static func wav(duration: Double, sampleRate: Int = 22_050) -> Data {
    let sampleCount = Int(duration * Double(sampleRate))
    let dataSize = sampleCount * 2
    var data = Data(capacity: 44 + dataSize)
    func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

    data.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + dataSize))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); append32(16)
    append16(1); append16(1)
    append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2))
    append16(2); append16(16)
    data.append(contentsOf: Array("data".utf8)); append32(UInt32(dataSize))
    for index in 0..<sampleCount {
      let sample = sin(Double(index) * 2 * .pi * 440 / Double(sampleRate)) * 0.1
      append16(UInt16(bitPattern: Int16(sample * Double(Int16.max))))
    }
    return data
  }
}
