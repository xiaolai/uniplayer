//
//  CloudPlaybackEngineTests.swift
//  UniPlayerTests
//
//  Engine gate for cloud-drive playback: mpv 0.41 must send the per-file HTTP
//  options this app builds, and it must keep seeking. The probe drives mpv over
//  its JSON IPC socket, so it exercises the same command-node option map the
//  app uses without constructing a player window.
//

import XCTest
@testable import UniPlayer

private final class UnixJSONSocket {
  enum SocketError: Error { case create, path, connect }

  private let fd: Int32
  private let lock = NSLock()
  private var buffer = Data()
  private let available = DispatchSemaphore(value: 0)
  private let queue = DispatchQueue(label: "UniPlayer.CloudProbe.IPC")

  init(path: String) throws {
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError.create }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(fd)
      throw SocketError.path
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      close(fd)
      throw SocketError.connect
    }
    queue.async { [weak self] in self?.readLoop() }
  }

  deinit { close(fd) }

  func send(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(0x0A)
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var offset = 0
      while offset < raw.count {
        let written = write(fd, base.advanced(by: offset), raw.count - offset)
        if written <= 0 { return }
        offset += written
      }
    }
  }

  func next(timeout: TimeInterval) -> [String: Any]? {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      lock.lock()
      if let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer.subdata(in: 0..<newline)
        buffer.removeSubrange(0...newline)
        lock.unlock()
        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
          return object
        }
        continue
      }
      lock.unlock()
      let remaining = deadline.timeIntervalSinceNow
      if remaining <= 0 { return nil }
      _ = available.wait(timeout: .now() + remaining)
    }
  }

  func waitForEvent(_ name: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let remaining = deadline.timeIntervalSinceNow
      if remaining <= 0 { return false }
      guard let event = next(timeout: remaining) else { return false }
      if event["event"] as? String == name { return true }
      if event["event"] as? String == "end-file" { return false }
    }
  }

  func request(_ command: [Any], id: Int, timeout: TimeInterval = 5) -> [String: Any]? {
    send(["command": command, "request_id": id])
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let remaining = deadline.timeIntervalSinceNow
      if remaining <= 0 { return nil }
      guard let event = next(timeout: remaining) else { return nil }
      if event["request_id"] as? Int == id { return event }
    }
  }

  private func readLoop() {
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(fd, &chunk, chunk.count)
      if count <= 0 { return }
      lock.lock()
      buffer.append(contentsOf: chunk[0..<count])
      lock.unlock()
      available.signal()
    }
  }
}

final class CloudPlaybackEngineTests: XCTestCase {
  private let mpvPath = "/opt/homebrew/bin/mpv"
  private var process: Process?
  private var socketPath: String?
  private var server: CloudDriveFixtureServer?

  override func tearDown() {
    process?.terminate()
    process?.waitUntilExit()
    process = nil
    if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
    server?.stop()
    server = nil
    super.tearDown()
  }

  private func startMPV(socketPath: String, loop: Bool = false) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: mpvPath)
    process.arguments = [
      "--input-ipc-server=\(socketPath)",
      "--idle=yes", "--no-config", "--really-quiet",
      "--vo=null", "--ao=null", "--no-video", "--force-window=no",
      "--cache=no", "--demuxer-readahead-secs=0",
    ] + (loop ? ["--loop-file=inf"] : [])
    var environment = ProcessInfo.processInfo.environment
    for key in environment.keys where key.lowercased().contains("proxy") {
      environment.removeValue(forKey: key)
    }
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
  }

  private func waitForSocket(_ path: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: path) { return true }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return false
  }

  func testMpvSendsPerFileHTTPOptionsAndSeeks() throws {
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: mpvPath),
                      "mpv 0.41 is not installed at \(mpvPath)")

    let fixture = try CloudDriveFixtureServer()
    server = fixture
    // A UNIX socket path is limited to 104 bytes; the temporary directory path
    // on this Mac is long enough to exceed that with a UUID.
    let socketPath = "/tmp/uniplayer-cloud-\(UUID().uuidString.prefix(8)).sock"
    self.socketPath = socketPath
    process = try startMPV(socketPath: socketPath)
    guard waitForSocket(socketPath, timeout: 5) else {
      throw XCTSkip("mpv did not create its IPC socket")
    }

    let plan = PlaybackLoadPlan(
      mediaID: nil, url: fixture.baseURL.appendingPathComponent("media"),
      intent: .ordinaryOpen, startPosition: 0, suppressWatchLater: true,
      knownDuration: nil,
      http: PlaybackHTTPOptions(
        userAgent: "FixtureAgent/1",
        referrer: "https://pan.quark.cn/",
        headers: [
          PlaybackHTTPHeader(name: "X-Test", value: "a,b"),
          PlaybackHTTPHeader(name: "X-Quote", value: "\"q\""),
          PlaybackHTTPHeader(name: "X-Name", value: "文件"),
          PlaybackHTTPHeader(name: "Cookie", value: "sid=fixture"),
        ],
        expiresAt: nil, title: "Fixture Title"))
    let command = PlaybackEngineOptions.loadfileNodeArguments(
      path: plan.url.absoluteString, plan: plan).compactMap { $0 }

    let socket = try UnixJSONSocket(path: socketPath)
    let load = socket.request(command, id: 1)
    XCTAssertEqual(load?["error"] as? String, "success")

    // The fixture records mpv's real request, not a synthetic one.
    var recorded: CloudDriveFixtureServer.RecordedRequest?
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, recorded == nil {
      recorded = fixture.requests(matching: "/media").first
      if recorded == nil { Thread.sleep(forTimeInterval: 0.05) }
    }
    let request = try XCTUnwrap(recorded, "mpv never requested the fixture")
    XCTAssertEqual(request.headers["user-agent"], "FixtureAgent/1")
    XCTAssertEqual(request.headers["referer"], "https://pan.quark.cn/")
    XCTAssertEqual(request.headers["x-test"], "a,b",
                   "a comma inside a header value must survive mpv's string-list parser")
    XCTAssertEqual(request.headers["x-quote"], "\"q\"")
    XCTAssertEqual(request.headers["x-name"], "文件")
    XCTAssertEqual(request.headers["cookie"], "sid=fixture")

    XCTAssertTrue(socket.waitForEvent("file-loaded", timeout: 10),
                  "mpv did not finish loading the fixture")
    let mediaTitle = socket.request(["get_property", "media-title"], id: 4)
    XCTAssertEqual(mediaTitle?["data"] as? String, "Fixture Title",
                   "the resolved title must replace the signed URL in the player")
    let seek = socket.request(["seek", "1.5", "absolute"], id: 2)
    XCTAssertEqual(seek?["error"] as? String, "success")
    Thread.sleep(forTimeInterval: 0.4)
    let position = socket.request(["get_property", "time-pos"], id: 3)
    XCTAssertEqual(position?["error"] as? String, "success")
    let time = (position?["data"] as? NSNumber)?.doubleValue ?? 0
    XCTAssertGreaterThan(time, 1.0, "seek did not move playback")
  }

  /// The gate the fast probe cannot cover: the same signed URL must still
  /// serve a seeking player ten minutes later. Run explicitly with
  /// `CLOUD_DRIVE_LONG_PROBE=1`; the default suite stays fast.
  func testTenMinuteSessionSurvives() throws {
    // xcodebuild does not forward arbitrary shell variables to the test host,
    // so the opt-in is also a file sentinel.
    let optIn = ProcessInfo.processInfo.environment["CLOUD_DRIVE_LONG_PROBE"] == "1"
      || FileManager.default.fileExists(atPath: "/tmp/uniplayer-cloud-long-probe")
    try XCTSkipUnless(optIn, "Create /tmp/uniplayer-cloud-long-probe to run the ten-minute probe")
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: mpvPath),
                      "mpv 0.41 is not installed at \(mpvPath)")

    // A long stream, not a short loop: every seek must reach the server, so the
    // signed URL is exercised for the whole session.
    let fixture = try CloudDriveFixtureServer(media: CloudDriveFixtureServer.wav(duration: 700))
    server = fixture
    let socketPath = "/tmp/uniplayer-cloud-long-\(UUID().uuidString.prefix(8)).sock"
    self.socketPath = socketPath
    process = try startMPV(socketPath: socketPath)
    guard waitForSocket(socketPath, timeout: 5) else {
      throw XCTSkip("mpv did not create its IPC socket")
    }

    let expires = Int(Date().addingTimeInterval(660).timeIntervalSince1970)
    let url = try XCTUnwrap(URL(string: "\(fixture.baseURL.absoluteString)/signed?expires=\(expires)"))
    let plan = PlaybackLoadPlan(
      mediaID: nil, url: url, intent: .ordinaryOpen, startPosition: 0,
      suppressWatchLater: true, knownDuration: nil,
      http: PlaybackHTTPOptions(userAgent: "FixtureAgent/1", referrer: nil,
                                headers: [], expiresAt: nil))
    let command = PlaybackEngineOptions.loadfileNodeArguments(
      path: url.absoluteString, plan: plan).compactMap { $0 }
    let socket = try UnixJSONSocket(path: socketPath)
    let load = socket.request(command, id: 1)
    XCTAssertEqual(load?["error"] as? String, "success")
    XCTAssertTrue(socket.waitForEvent("file-loaded", timeout: 10))

    let deadline = Date().addingTimeInterval(600)
    var iteration = 0
    while Date() < deadline {
      Thread.sleep(forTimeInterval: 30)
      let target = 10.0 + Double(iteration) * 28.0
      let seek = socket.request(["seek", String(target), "absolute"], id: 100 + iteration)
      XCTAssertEqual(seek?["error"] as? String, "success",
                     "seek failed after \(iteration) intervals")
      let idle = socket.request(["get_property", "idle-active"], id: 500 + iteration)
      XCTAssertEqual(idle?["data"] as? Bool, false,
                     "playback stopped after \(iteration) intervals")
      Thread.sleep(forTimeInterval: 0.5)
      let position = socket.request(["get_property", "time-pos"], id: 700 + iteration)
      let time = (position?["data"] as? NSNumber)?.doubleValue ?? 0
      XCTAssertGreaterThan(time, target - 2,
                           "the stream did not reach \(target)s at interval \(iteration)")
      iteration += 1
    }
    XCTAssertGreaterThanOrEqual(iteration, 19)
    XCTAssertGreaterThan(fixture.requests(matching: "/signed").count, 20,
                         "the signed URL was not exercised across the session")
  }
}
