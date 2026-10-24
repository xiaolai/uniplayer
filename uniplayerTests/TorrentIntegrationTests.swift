import XCTest
import WebKit
import CryptoKit
import Network
import SwiftUI
@testable import UniPlayer

private final class TorrentRPCProtocol: URLProtocol {
  static var requests: [[String:Any]] = []
  static var sessions: [String?] = []
  override class func canInit(with request:URLRequest)->Bool { true }
  override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
  override func startLoading() {
    Self.sessions.append(request.value(forHTTPHeaderField:"X-Transmission-Session-Id"))
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
      stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
      while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; data.append(contentsOf:buffer.prefix(n)) }
    }
    Self.requests.append((try? JSONSerialization.jsonObject(with:data) as? [String:Any]) ?? [:])
    let first = Self.requests.count == 1
    client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:first ? 409 : 200,httpVersion:nil,headerFields:["X-Transmission-Session-Id":"fixture-session"])!,cacheStoragePolicy:.notAllowed)
    client?.urlProtocol(self,didLoad:Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".utf8)); client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
final class TransmissionRPCClientTests: XCTestCase {
  func testCSRFHandshakeAndHashScopedMutations() async throws {
    TorrentRPCProtocol.requests = []; TorrentRPCProtocol.sessions = []
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TorrentRPCProtocol.self]
    let client = TransmissionRPCClient(endpoint:URL(string:"http://127.0.0.1:1234/transmission/rpc")!,username:"fixture",password:"fixture",session:URLSession(configuration:config))
    try await client.mutate("torrent_stop",hash:String(repeating:"a",count:40))
    XCTAssertEqual(TorrentRPCProtocol.requests.count,2)
    XCTAssertEqual(TorrentRPCProtocol.sessions.last!,"fixture-session")
    let params = TorrentRPCProtocol.requests.last?["params"] as? [String:Any]
    XCTAssertEqual(params?["ids"] as? [String],[String(repeating:"a",count:40)])
    do { try await client.mutate("torrent_stop",hash:"all"); XCTFail("Unscoped mutation admitted") } catch {}
    do { try await client.mutate("torrent_set",hash:String(repeating:"a",count:40),parameters:["ids":[1]]); XCTFail("Integer ids admitted") } catch {}
    do { _ = try await client.call("torrent_stop"); XCTFail("Unscoped raw mutation admitted") } catch {}
    XCTAssertEqual(TorrentRPCProtocol.requests.count,2)
  }
}

actor TorrentPieceFixture: TorrentPieceProviding {
  let bytes: Data; let url: URL; let hash = String(repeating:"a",count:40)
  var verified: Bool; var epoch = 0; var requested: [Int] = []
  init(verified: Bool = true) throws {
    self.verified = verified; bytes = Data((0..<131072).map { UInt8($0 % 251) })
    url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    try bytes.write(to:url)
  }
  func snapshot() throws -> TorrentSnapshot {
    try TorrentSnapshot(json:["hash_string":hash,"name":"fixture.mp4","metadata_percent_complete":1,"piece_size":16384,"piece_count":8,
      "pieces":Data([verified ? 255 : 0]).base64EncodedString(),"availability":[Int](repeating:0,count:8),"files":[["name":"fixture.mp4","length":bytes.count,"begin_piece":0,"end_piece":8]],"download_dir":url.deletingLastPathComponent().path])
  }
  func mediaSnapshot(hash:String) throws -> TorrentSnapshot { try snapshot() }
  func requestPiece(hash:String,piece:Int) { requested.append(piece) }
  func mediaFile(snapshot:TorrentSnapshot,file:TorrentFile)->URL { url }
  func mediaGeneration()->Int { epoch }
  func invalidate() { epoch += 1 }
  func cleanup() { try? FileManager.default.removeItem(at:url) }
}
final class TorrentMediaBridgeTests: XCTestCase {
  func testHTTPRangesExactBytesHeadAndRejections() async throws {
    let source = try TorrentPieceFixture(); let snapshot = try await source.snapshot()
    let bridge = try TorrentMediaBridge(provider:source,hash:snapshot.hash,file:snapshot.files[0]); try await bridge.start()
    defer { bridge.stop(); Task { await source.cleanup() } }
    let session = URLSession(configuration:.ephemeral)
    for (range,start,end) in [("bytes=17000-19000",17000,19000),("bytes=-17",131055,131071),("bytes=131000-",131000,131071)] {
      var request = URLRequest(url:bridge.url); request.setValue(range,forHTTPHeaderField:"Range")
      let (bytes,response) = try await session.data(for:request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,206)
      XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField:"Content-Range"),"bytes \(start)-\(end)/131072")
      let expected = await source.bytes.subdata(in:start..<(end+1))
      XCTAssertEqual(bytes,expected)
    }
    var head = URLRequest(url:bridge.url); head.httpMethod = "HEAD"
    let (empty,response) = try await session.data(for:head); XCTAssertTrue(empty.isEmpty); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
    var bad = URLRequest(url:bridge.url); bad.setValue("bytes=1-2,4-5",forHTTPHeaderField:"Range")
    let (_,rejected) = try await session.data(for:bad); XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode,416)
    var origin = URLRequest(url:bridge.url); origin.setValue("https://example.test",forHTTPHeaderField:"Origin")
    let (_,forbidden) = try await session.data(for:origin); XCTAssertEqual((forbidden as? HTTPURLResponse)?.statusCode,403)
    let wrong = bridge.url.deletingLastPathComponent().appendingPathComponent("wrong.mp4")
    let (_,missing) = try await session.data(from:wrong); XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode,404)
  }
  func testTwentyCancelledRangeWaitsReleaseTheirReaders() async throws {
    let source = try TorrentPieceFixture(verified:false); let snapshot = try await source.snapshot()
    let bridge = try TorrentMediaBridge(provider:source,hash:snapshot.hash,file:snapshot.files[0]); try await bridge.start()
    defer { bridge.stop(); Task { await source.cleanup() } }
    let session = URLSession(configuration:.ephemeral)
    for index in 0..<20 {
      var request = URLRequest(url:bridge.url)
      request.setValue("bytes=\((index % 8)*16384)-",forHTTPHeaderField:"Range")
      let task = Task { try? await session.data(for:request) }
      try await Task.sleep(for:.milliseconds(30)); task.cancel(); _ = await task.value
    }
    for _ in 0..<100 { if bridge.activeConnectionCount == 0 { break }; try await Task.sleep(for:.milliseconds(20)) }
    XCTAssertEqual(bridge.activeConnectionCount,0)
    let requested = await source.requested; XCTAssertGreaterThan(requested.count,1)
  }
  func testUnverifiedSparseBytesNeverServedAndGenerationInvalidates() async throws {
    let source = try TorrentPieceFixture(verified:false); let snapshot = try await source.snapshot()
    let bridge = try TorrentMediaBridge(provider:source,hash:snapshot.hash,file:snapshot.files[0],readTimeout:0.25); try await bridge.start()
    defer { bridge.stop(); Task { await source.cleanup() } }
    do { _ = try await bridge.readVerified(TorrentByteRange(start:16384,end:16400,partial:true)); XCTFail("Unverified data served") } catch {}
    let requested = await source.requested; XCTAssertEqual(requested,[1])
    await source.invalidate()
    do { _ = try await bridge.readVerified(TorrentByteRange(start:0,end:1,partial:true)); XCTFail("Stale generation served") } catch {}
    do { _ = try await bridge.readVerified(TorrentByteRange(start:0,end:65536,partial:true)); XCTFail("Unbounded read admitted") } catch {}
  }
}

@MainActor final class TorrentPlaybackHistoryTests: XCTestCase {
  func testStableRecordRoundTripAndSanitizedPostLocator() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:folder) }
    let file = folder.appendingPathComponent("playback.json"), store = TorrentPlaybackStore(file:file)
    let identity = TorrentIdentity(hash:String(repeating:"a",count:40),fileIndex:1)
    let page = TorrentPlaybackStore.sanitizedPage(URL(string:"https://www.mini4k.com/movies/123?passkey=secret#token"))
    XCTAssertEqual(page?.absoluteString,"https://www.mini4k.com/movies/123")
    XCTAssertNil(TorrentPlaybackStore.sanitizedPage(URL(string:"https://example.test/download/secret.torrent?key=secret")))
    let record = TorrentPlaybackRecord(identity:identity,file:TorrentFile(index:1,name:"season/episode1.mkv",length:100,offset:33),title:"Episode",position:44,duration:100,channelID:"mini",sourcePage:page,continueAfterClose:true,isPrivate:true)
    XCTAssertTrue(store.save(record)); XCTAssertEqual(TorrentPlaybackStore(file:file).record(identity),record)
    XCTAssertFalse(try String(contentsOf:file,encoding:.utf8).contains("secret"))
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    XCTAssertEqual(TorrentIdentity(url:identity.url),identity)
  }
}

@MainActor final class ChannelTorrentAdapterTests: XCTestCase {
  func testIsolatedDOMActionsDynamicDedupCloudAndUntrustedClick() async throws {
    let oldPostFlag = UserDefaults.standard.object(forKey:TorrentPreferences.mini4KPosts)
    UserDefaults.standard.set(true,forKey:TorrentPreferences.mini4KPosts)
    defer { UserDefaults.standard.set(oldPostFlag,forKey:TorrentPreferences.mini4KPosts) }
    let old = UserDefaults.standard.object(forKey:TorrentPreferences.enabledKey)
    UserDefaults.standard.set(true,forKey:TorrentPreferences.enabledKey)
    defer { if let old { UserDefaults.standard.set(old,forKey:TorrentPreferences.enabledKey) } else { UserDefaults.standard.removeObject(forKey:TorrentPreferences.enabledKey) } }
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    let bridge = ChannelTorrentBridge(); bridge.install(in:config)
    let web = WKWebView(frame:.zero,configuration:config); bridge.attach(to:web,channelID:{"fixture"})
    var calls = 0; bridge.present = { _,_,_ in calls += 1 }
    web.loadHTMLString("<html><head></head><body><table><tr id='torrent'><td><a class='link-user' href='/torrents/123'>Movie</a><a href='/torrents/123'>Again</a></td></tr><tr><td><a class='link-node' href='/torrents/456'>Cloud</a></td></tr></table><a href='magnet:?xt=urn:btih:\(String(repeating:"a",count:40))'>Magnet</a></body></html>",baseURL:URL(string:"https://www.mini4k.com/movies/123"))
    try await wait(web,"document.querySelectorAll('.uniplayer-torrent-action').length===2")
    let svgNamespace = try await web.evaluateJavaScript("document.querySelector('.uniplayer-torrent-action svg')?.namespaceURI") as? String
    XCTAssertEqual(svgNamespace,"http://www.w3.org/2000/svg")
    _ = try await web.evaluateJavaScript("document.querySelector('.uniplayer-torrent-action').click()")
    XCTAssertEqual(calls,0)
    _ = try await web.evaluateJavaScript("document.querySelector('#torrent a').remove()")
    try await wait(web,"document.querySelectorAll('.uniplayer-torrent-action').length===2")
    _ = try await web.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend','<a href=\"https://example.test/file.torrent?key=private\">File</a>')")
    try await wait(web,"document.querySelectorAll('.uniplayer-torrent-action').length===3")
    bridge.refresh()
    _ = try await web.evaluateJavaScript("globalThis.uniPlayerTorrentActions?.enable(false)",in:nil,in:ChannelTorrentBridge.world)
    try await wait(web,"document.querySelectorAll('.uniplayer-torrent-action').length===0")
  }
  private func wait(_ web:WKWebView,_ condition:String) async throws {
    let until = Date().addingTimeInterval(8)
    while Date() < until { if (try? await web.evaluateJavaScript(condition)) as? Bool == true { return }; try await Task.sleep(for:.milliseconds(50)) }
    XCTFail("DOM condition timed out: \(condition)")
  }
  func testThousandRowsUseBoundedChunksAndNoNativeRequests() async throws {
    let old = UserDefaults.standard.object(forKey:TorrentPreferences.enabledKey)
    UserDefaults.standard.set(true,forKey:TorrentPreferences.enabledKey)
    defer { UserDefaults.standard.set(old,forKey:TorrentPreferences.enabledKey) }
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    let bridge = ChannelTorrentBridge(); bridge.install(in:config)
    let web = WKWebView(frame:.zero,configuration:config); bridge.attach(to:web,channelID:{nil})
    var requests = 0; bridge.present = { _,_,_ in requests += 1 }
    let rows = (0..<1000).map { index in
      let hash = String(format:"%040x",index)
      return "<tr><td><a href='magnet:?xt=urn:btih:"+hash+"'>Film</a><a href='magnet:?xt=urn:btih:"+hash+"'>Duplicate</a></td></tr>"
    }.joined()
    web.loadHTMLString("<html><head></head><body><table>"+rows+"</table></body></html>",baseURL:URL(string:"https://fixture.example/"))
    try await wait(web,"document.querySelectorAll('.uniplayer-torrent-action').length===1000")
    let raw = try await web.callAsyncJavaScript("return JSON.stringify(globalThis.uniPlayerTorrentActions.inspect())",arguments:[:],in:nil,contentWorld:ChannelTorrentBridge.world)
    let encoded = try XCTUnwrap(raw as? String,"Isolated-world diagnostics: \(String(describing:raw))")
    let stats = try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(encoded.utf8)) as? [String:Any])
    XCTAssertLessThan(stats["maxChunk"] as? Double ?? 999,16)
    print("Torrent DOM 1000 rows: elapsed=\(stats["elapsed"] ?? -1) ms maxChunk=\(stats["maxChunk"] ?? -1) ms")
    XCTAssertEqual(requests,0)
  }
  func testCandidateValidationAndRouting() {
    let origin = URL(string:"https://www.mini4k.com/movies/123")!
    func candidate(_ url:String,_ kind:String)->ChannelTorrentCandidate? { ChannelTorrentCandidate(body:["version":1,"action":"inspect","url":url,"kind":kind,"title":"Fixture"],originURL:origin,channelID:"mini",generation:1) }
    XCTAssertNotNil(candidate("https://www.mini4k.com/torrents/123","resource"))
    XCTAssertNil(candidate("https://example.test/torrents/123","resource"))
    XCTAssertNil(candidate("javascript:alert(1)","torrent"))
    XCTAssertNil(candidate("https://user:secret@example.test/file.torrent","torrent"))
    XCTAssertTrue(TorrentPlaybackCoordinator.recognizes(URL(string:"magnet:?xt=urn:btih:bad")!))
    XCTAssertTrue(TorrentPlaybackCoordinator.recognizes(URL(fileURLWithPath:"/tmp/file.torrent")))
    XCTAssertFalse(TorrentPlaybackCoordinator.recognizes(URL(string:"https://example.test/movie.mp4")!))
  }
}

final class TorrentRuntimeIntegrationTests: XCTestCase {
  func testOwnedGenuineRuntimePausedMetadataStopAndProfileIsolation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UniPlayerRuntimeTest-"+UUID().uuidString)
    let runtime = TransmissionRuntime(root:root)
    do {
      let client = try await runtime.start()
      let effective = try await client.call("session_get",["fields":["lpd_enabled","start_added_torrents","peer_port_random_on_start"]])
      XCTAssertEqual(effective["lpd_enabled"] as? Bool,false); XCTAssertEqual(effective["start_added_torrents"] as? Bool,false); XCTAssertEqual(effective["peer_port_random_on_start"] as? Bool,true)
      let settings = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("runtime/settings.json"))) as! [String:Any]
      let port = try XCTUnwrap((settings["rpc_port"] ?? settings["rpc-port"]) as? Int)
      let config = URLSessionConfiguration.ephemeral; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
      var unauthorized = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/transmission/rpc")!); unauthorized.httpMethod = "POST"; unauthorized.httpBody = Data("{}".utf8)
      let (_,rejected) = try await URLSession(configuration:config).data(for:unauthorized)
      XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode,401)
      let result = try await runtime.add(TorrentRuntimeSource(metainfo:TorrentFixture.metainfo()))
      XCTAssertFalse(result.1); XCTAssertTrue(result.0.metadataComplete); XCTAssertTrue(result.0.isPrivate); XCTAssertEqual(result.0.status,0)
      XCTAssertTrue(result.0.downloadDirectory.hasPrefix(root.path+"/cache/"))
      let duplicate = try await runtime.add(TorrentRuntimeSource(metainfo:TorrentFixture.metainfo()))
      XCTAssertTrue(duplicate.1)
      try await runtime.inspect(result.0.hash,knownMetadata:true)
      await runtime.stopInspection(result.0.hash)
      let stopped = try await runtime.find(result.0.hash,fresh:true); XCTAssertEqual(stopped?.status,0)
      let profile = root.appendingPathComponent("runtime")
      XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:profile.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
      await runtime.shutdown()
      _ = try await runtime.start()
      let restored = try await runtime.find(result.0.hash,fresh:true); XCTAssertEqual(restored?.status,0)
      await runtime.shutdown(); try FileManager.default.removeItem(at:root)
    } catch { await runtime.shutdown(); try? FileManager.default.removeItem(at:root); throw error }
  }
}

@MainActor final class TorrentControlledPlaybackTests: XCTestCase {
  func testRealSwarmBridgeStandalonePlayerSeekResumeAndClose() async throws {
    var displays:UInt32 = 0
    CGGetActiveDisplayList(0,nil,&displays)
    guard displays > 0 else { throw XCTSkip("Native playback requires an awake display; CoreVideo reports zero active displays.") }
    let checkout = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
    let media = checkout.appendingPathComponent("build/torrent-fixture.mp4")
    guard FileManager.default.fileExists(atPath:media.path) else { throw XCTSkip("Generate the documented controlled video fixture first.") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UniPlayerSwarm-"+UUID().uuidString)
    let fixture = root.appendingPathComponent("fixture")
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let daemon = Bundle.main.resourceURL!.appendingPathComponent("TorrentRuntime/transmission-daemon")
    let child = Process(); child.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
    child.arguments = [checkout.appendingPathComponent("tests/torrent-runtime/swarm_fixture.py").path,daemon.path,fixture.path,media.path]
    child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run()
    var runtime = TransmissionRuntime(root:root.appendingPathComponent("owned"))
    let store = TorrentPlaybackStore(file:root.appendingPathComponent("playback.json"))
    let coordinator = TorrentPlaybackCoordinator(runtime:runtime,store:store)
    do {
      let ready = fixture.appendingPathComponent("ready.json")
      for _ in 0..<200 { if FileManager.default.fileExists(atPath:ready.path) { break }; try await Task.sleep(for:.milliseconds(100)) }
      let setup = try JSONSerialization.jsonObject(with:Data(contentsOf:ready)) as! [String:Any]
      let metainfo = Data(base64Encoded:setup["metainfo"] as! String)!
      let client = try await runtime.start()
      _ = try await client.call("session_set",["dht_enabled":false,"pex_enabled":false,"utp_enabled":false])
      let added = try await runtime.add(TorrentRuntimeSource(metainfo:metainfo))
      let before = PlayerCore.playerCores.map { $0.info.currentURL }
      try await coordinator.play(snapshot:added.0,file:added.0.files[0],origin:nil,continueAfterClose:false)
      let player = try XCTUnwrap(coordinator.sessions[added.0.hash]?.player)
      player.mpv.setFlag(MPVOption.Audio.mute,true)
      XCTAssertFalse(player.isInline)
      XCTAssertEqual(Array(PlayerCore.playerCores.prefix(before.count)).map { $0.info.currentURL },before)
      let session = try await client.call("session_get",["fields":["peer_port"]])
      let peerPort = (session["peer_port"] as! NSNumber).intValue
      _ = try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:\(setup["relayControlPort"] as! Int)/?port=\(peerPort)")!)
      let until = Date().addingTimeInterval(40)
      while player.info.videoDuration == nil && Date() < until { try await Task.sleep(for:.milliseconds(100)) }
      XCTAssertNotNil(player.info.videoDuration,"Actual native mpv failed to load controlled torrent video")
      XCTAssertEqual(player.info.currentURL?.scheme,"uniplayer-torrent")
      XCTAssertNotNil(player.mainWindow.window)
      player.seek(absoluteSecond:8)
      for _ in 0..<50 { if abs(player.mpv.getDouble(MPVProperty.timePos)-8) < 2 { break }; try await Task.sleep(for:.milliseconds(100)) }
      XCTAssertLessThan(abs(player.mpv.getDouble(MPVProperty.timePos)-8),2)
      // One scheduling owner: replay the same file focuses its existing core.
      try await coordinator.play(snapshot:added.0,file:added.0.files[0],origin:nil,continueAfterClose:false)
      XCTAssertTrue(coordinator.sessions[added.0.hash]?.player === player)
      player.info.videoPosition = VideoTime(8); coordinator.savePosition(player:player)
      let stable = TorrentIdentity(hash:added.0.hash,fileIndex:0)
      XCTAssertEqual(store.record(stable)?.position,8)
      player.mainWindow.close()
      for _ in 0..<70 { if coordinator.sessions.isEmpty, try await runtime.find(added.0.hash,fresh:true)?.status == 0 { break }; try await Task.sleep(for:.milliseconds(100)) }
      XCTAssertTrue(coordinator.sessions.isEmpty)
      let stopped = try await runtime.find(added.0.hash,fresh:true); XCTAssertEqual(stopped?.status,0)
      await coordinator.quit()
      // mpv has already decoded/searched an incomplete transfer. With its reader
      // closed, verify the complete HTTP body using a fresh, independent lease.
      runtime = TransmissionRuntime(root:root.appendingPathComponent("owned"))
      let restartedClient = try await runtime.start()
      let restoredValue = try await runtime.find(added.0.hash,fresh:true)
      let restored = try XCTUnwrap(restoredValue)
      try await runtime.prepare(restored,file:restored.files[0])
      let restartedSession = try await restartedClient.call("session_get",["fields":["peer_port"]])
      _ = try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:\(setup["relayControlPort"] as! Int)/?port=\((restartedSession["peer_port"] as! NSNumber).intValue)")!)
      let verification = try TorrentMediaBridge(provider:runtime,hash:restored.hash,file:restored.files[0])
      try await verification.start()
      var request = URLRequest(url:verification.url); request.timeoutInterval = 60
      let (downloaded,response) = try await URLSession.shared.data(for:request)
      verification.stop()
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
      XCTAssertEqual(SHA256.hash(data:downloaded).map { String(format:"%02x",$0) }.joined(),setup["sha256"] as? String)
      try await runtime.stop(restored.hash)
      let resumed = TorrentPlaybackCoordinator(runtime:runtime,store:store)
      try await resumed.play(snapshot:restored,file:restored.files[0],origin:nil,continueAfterClose:true)
      let resumedPlayer = try XCTUnwrap(resumed.sessions[restored.hash]?.player)
      let resumeDeadline = Date().addingTimeInterval(15)
      while resumedPlayer.info.videoDuration == nil && Date() < resumeDeadline { try await Task.sleep(for:.milliseconds(100)) }
      XCTAssertNotNil(resumedPlayer.info.videoDuration)
      XCTAssertEqual(resumedPlayer.torrentContext?.resumePosition,Preference.bool(for:.resumeLastPosition) ? 8 : 0)
      let savedTorrentPosition = store.record(stable)?.position
      resumedPlayer.openURL(media,shouldAutoLoad:false)
      for _ in 0..<100 { if PlayerCore.playerCores.contains(where:{ !$0.isTorrentDedicated && $0.info.currentURL == media && $0.info.videoDuration != nil }) { break }; try await Task.sleep(for:.milliseconds(50)) }
      XCTAssertNil(resumedPlayer.torrentContext)
      let ordinary = PlayerCore.playerCores.first { !$0.isTorrentDedicated && $0.info.currentURL == media }
      XCTAssertNotNil(ordinary)
      ordinary?.mainWindow.close()
      XCTAssertEqual(store.record(stable)?.position ?? -999,savedTorrentPosition ?? 0,accuracy:1)
      resumedPlayer.mainWindow.close()
      try await Task.sleep(for:.milliseconds(300))
      let retained = try await runtime.find(restored.hash,fresh:true)
      XCTAssertNotEqual(retained?.status,0,"Continue must retain the private transfer after the reader closes")
      await resumed.stop(hash:restored.hash)
      let explicitlyStopped = try await runtime.find(restored.hash,fresh:true); XCTAssertEqual(explicitlyStopped?.status,0)
      await resumed.quit()
      child.terminate()
      for _ in 0..<60 { if !child.isRunning { break }; try await Task.sleep(for:.milliseconds(100)) }
      if child.isRunning { child.interrupt() }
      try FileManager.default.removeItem(at:root)
    } catch {
      await coordinator.quit(); if child.isRunning { child.terminate() }
      for _ in 0..<60 { if !child.isRunning { break }; try? await Task.sleep(for:.milliseconds(100)) }
      if child.isRunning { child.interrupt() }
      throw error
    }
  }
}

private final class TorrentDownloadFixture: @unchecked Sendable {
  let listener: NWListener
  var port: UInt16 { listener.port!.rawValue }
  let bytes = TorrentFixture.metainfo()
  private let lock = NSLock()
  private(set) var authenticated = false
  init() throws {
    let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
    listener = try NWListener(using:parameters)
    listener.newConnectionHandler = { [weak self] connection in
      connection.start(queue:.global())
      connection.receive(minimumIncompleteLength:1,maximumLength:8192) { data,_,_,_ in
        guard let self, let data, let request = String(data:data,encoding:.utf8) else { connection.cancel(); return }
        let path = request.split(separator:" ").dropFirst().first.map(String.init) ?? "/"
        let authorized = request.lowercased().contains("fixture=allowed")
        self.lock.withLock { self.authenticated = self.authenticated || authorized }
        var body: Data; var headers: String
        if path == "/file.torrent", authorized {
          body = self.bytes; headers = "200 OK\r\nContent-Type: application/x-bittorrent\r\nContent-Disposition: attachment; filename=source.torrent"
        } else if path == "/html.torrent" {
          body = Data("<html><title>Login</title><input type=password></html>".utf8); headers = "200 OK\r\nContent-Type: text/html"
        } else if path == "/big.torrent" {
          body = Data(); headers = "200 OK\r\nContent-Type: application/x-bittorrent\r\nContent-Length: 11000000"
        } else {
          body = Data("<html><body data-ready='yes'>Fixture</body></html>".utf8); headers = "200 OK\r\nContent-Type: text/html"
        }
        if !headers.contains("Content-Length") { headers += "\r\nContent-Length: \(body.count)" }
        print("Torrent fixture response path="+path+" type="+headers.components(separatedBy:"\r\n").prefix(2).joined(separator:" "))
        let response = Data("HTTP/1.1 \(headers)\r\nConnection: close\r\n\r\n".utf8)+body
        connection.send(content:response,completion:.contentProcessed { _ in connection.cancel() })
      }
    }
    listener.start(queue:.global())
  }
  func stop() { listener.cancel() }
}
@MainActor final class ChannelTorrentResolverTests: XCTestCase {
  func testDownloadUsesExistingWebKitCookieStoreAndRejectsHTMLAndOversize() async throws {
    let server = try TorrentDownloadFixture(); defer { server.stop() }
    for _ in 0..<100 { if (server.listener.port?.rawValue ?? 0) > 0 { break }; try await Task.sleep(for:.milliseconds(20)) }
    let origin = URL(string:"http://127.0.0.1:\(server.port)/")!
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let cookie = try XCTUnwrap(HTTPCookie(properties:[.domain:"127.0.0.1",.path:"/",.name:"fixture",.value:"allowed"]))
    print("Torrent cookie fixture: setting cookie")
    await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
    let web = WKWebView(frame:NSRect(x:0,y:0,width:800,height:600),configuration:configuration)
    let window = NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false
    window.contentView = web
    defer { web.stopLoading(); window.close() }
    web.loadHTMLString("<html><body data-ready='yes'>Fixture</body></html>",baseURL:origin)
    for _ in 0..<100 { if (try? await web.evaluateJavaScript("document.body?.dataset.ready==='yes'")) as? Bool == true { break }; try await Task.sleep(for:.milliseconds(30)) }
    let documentReady = try? await web.evaluateJavaScript("document.body?.dataset.ready==='yes'")
    print("Torrent fixture document URL: " + (web.url?.absoluteString ?? "nil"))
    XCTAssertEqual(documentReady as? Bool,true,"Fixture document failed to load")
    let resolver = ChannelTorrentResolver(webView:web)
    func candidate(_ path:String)->ChannelTorrentCandidate {
      ChannelTorrentCandidate(body:["version":1,"action":"inspect","url":origin.appendingPathComponent(path).absoluteString,"title":"Fixture","kind":"torrent"],originURL:origin,channelID:"fixture",generation:0)!
    }
    print("Torrent cookie fixture: requesting protected file")
    let result = try await resolver.resolve(candidate("file.torrent"),isCurrent:{true})
    print("Torrent cookie fixture: protected file returned")
    XCTAssertEqual(result.metainfo,server.bytes)
    let nativeDownload = TorrentSourceDownload(webView:web,url:origin.appendingPathComponent("file.torrent"),origin:origin)
    let nativeBytes = try await nativeDownload.run()
    XCTAssertEqual(nativeBytes,server.bytes)
    XCTAssertTrue(server.authenticated)
    for path in ["html.torrent","big.torrent"] {
      print("Torrent cookie fixture: rejecting " + path)
      do { _ = try await ChannelTorrentResolver(webView:web).resolve(candidate(path),isCurrent:{true}); XCTFail("Invalid protected source admitted") } catch {}
    }
    do { _ = try await resolver.resolve(candidate("file.torrent"),isCurrent:{false}); XCTFail("Stale document admitted") } catch {}
  }
}

@MainActor final class TorrentInspectionPresentationTests: XCTestCase {
  func testMetadataGateUnknownHealthAndClientRejection() throws {
    let model = TorrentInspection(title:"Fixture") { throw TorrentFailure.invalidSource }
    XCTAssertFalse(model.canPlay)
    model.snapshot = try TorrentSnapshot(json:["hash_string":String(repeating:"a",count:40),"metadata_percent_complete":1,
      "piece_size":16384,"piece_count":1,"pieces":"AA==","availability":[0],"files":[["name":"fixture.mp4","length":16384,"begin_piece":0,"end_piece":1]]])
    model.selected = 0
    XCTAssertTrue(model.canPlay); XCTAssertEqual(model.playLabel,"Try Playback")
    model.selected = 99; XCTAssertFalse(model.canPlay)
    model.selected = 0
    model.snapshot = try TorrentSnapshot(json:["hash_string":String(repeating:"a",count:40),"metadata_percent_complete":1,
      "piece_size":16384,"piece_count":1,"pieces":"AA==","availability":[0],"files":[["name":"fixture.mp4","length":16384,"begin_piece":0,"end_piece":1]],
      "error":2,"error_string":"Client version not allowed https://tracker.test/secret/announce"])
    XCTAssertFalse(model.canPlay)
    XCTAssertTrue(model.snapshot!.clientVersionRejected)
  }
  func testNativeSheetRendersUnknownAndPrivatePolicy() async throws {
    let model = TorrentInspection(title:"Arrival · 2160p") { throw TorrentFailure.invalidSource }
    model.busy = false
    model.message = "Inspection stopped. Counts are observations, not a guarantee of playback."
    model.snapshot = try TorrentSnapshot(json:["hash_string":String(repeating:"a",count:40),"name":"Arrival","metadata_percent_complete":1,"is_private":true,
      "piece_size":16384,"piece_count":1,"pieces":"AA==","availability":[0],"peers_connected":0,"files":[["name":"Arrival.2160p.mkv","length":16384,"begin_piece":0,"end_piece":1]]])
    model.selected = 0; model.continueAfterClose = true
    let host = NSHostingView(rootView:TorrentInspectionView(model:model))
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:620),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named:.darkAqua); window.contentView = host
    window.orderBack(nil)
    defer { window.close() }
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    try await Task.sleep(for:.milliseconds(100))
    if let image = host.bitmapImageRepForCachingDisplay(in:host.bounds) {
      host.cacheDisplay(in:host.bounds,to:image)
      let checkout = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
      try image.representation(using:.png,properties:[:])?.write(to:checkout.appendingPathComponent("build/torrent-inspection-sheet.png"))
    } else { XCTFail("Native sheet did not render") }
    XCTAssertTrue(model.canPlay); XCTAssertTrue(model.continueAfterClose)
  }
}

@MainActor final class TorrentInspectionTests: XCTestCase {
  func testPublicMagnetInspectionHasBoundedTransferAndStops() async throws {
    let checkout = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
    let media = checkout.appendingPathComponent("build/torrent-fixture.mp4")
    guard FileManager.default.fileExists(atPath:media.path) else { throw XCTSkip("Generate controlled media first") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UniPlayerMagnetInspection-"+UUID().uuidString)
    let fixture = root.appendingPathComponent("fixture")
    let child = Process(); child.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
    child.arguments = [checkout.appendingPathComponent("tests/torrent-runtime/swarm_fixture.py").path,Bundle.main.resourceURL!.appendingPathComponent("TorrentRuntime/transmission-daemon").path,fixture.path,media.path,"public"]
    child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run()
    let runtime = TransmissionRuntime(root:root.appendingPathComponent("owned"))
    do {
      let ready = fixture.appendingPathComponent("ready.json")
      for _ in 0..<200 { if FileManager.default.fileExists(atPath:ready.path) { break }; try await Task.sleep(for:.milliseconds(100)) }
      let setup = try JSONSerialization.jsonObject(with:Data(contentsOf:ready)) as! [String:Any]
      let descriptor = try TorrentMetainfo(Data(base64Encoded:setup["metainfo"] as! String)!)
      let client = try await runtime.start()
      _ = try await client.call("session_set",["dht_enabled":false,"pex_enabled":false,"utp_enabled":false])
      let source = try TorrentRuntimeSource(magnet:"magnet:?xt=urn:btih:"+descriptor.hash)
      let model = TorrentInspection(title:"Public fixture",runtime:runtime) { source }
      let start = Date(); model.begin()
      for _ in 0..<100 { if try await runtime.find(source.hash,fresh:true) != nil { break }; try await Task.sleep(for:.milliseconds(50)) }
      let session = try await client.call("session_get",["fields":["peer_port"]])
      _ = try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:\(setup["relayControlPort"] as! Int)/?port=\((session["peer_port"] as! NSNumber).intValue)")!)
      while model.busy && Date().timeIntervalSince(start) < 30 { try await Task.sleep(for:.milliseconds(100)) }
      XCTAssertFalse(model.busy); XCTAssertTrue(model.snapshot?.metadataComplete == true)
      let final = try await runtime.find(source.hash,fresh:true)
      XCTAssertEqual(final?.status,0)
      XCTAssertLessThanOrEqual(final?.downloaded ?? Int64.max,8*1024*1024)
      XCTAssertLessThan(Date().timeIntervalSince(start),28)
      print("Controlled inspection: bytes=\(final?.downloaded ?? -1) elapsed=\(Date().timeIntervalSince(start)) metadata=\(final?.metadataComplete ?? false)")
      let ended = expectation(description:"Cancel resolves after inspection cleanup")
      model.cleanupFinished = { ended.fulfill() }; model.cancel()
      await fulfillment(of:[ended],timeout:6)
      let removed = try await runtime.find(source.hash,fresh:true); XCTAssertNil(removed)
      await runtime.shutdown(); child.terminate()
      for _ in 0..<60 { if !child.isRunning { break }; try await Task.sleep(for:.milliseconds(100)) }
      if child.isRunning { child.interrupt() }
      try FileManager.default.removeItem(at:root)
    } catch {
      await runtime.shutdown(); if child.isRunning { child.terminate() }
      for _ in 0..<60 { if !child.isRunning { break }; try? await Task.sleep(for:.milliseconds(100)) }
      if child.isRunning { child.interrupt() }; throw error
    }
  }
}
