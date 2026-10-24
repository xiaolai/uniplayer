import AppKit
import XCTest
import CryptoKit
import Darwin
import WebKit
import SwiftUI
@testable import UniPlayer

@MainActor final class TorrentAuditRegressionTests: XCTestCase {
  private func metainfo(name:String = "fixture.mp4",length:Int = 2*1024*1024,isPrivate:Bool = false)->Data {
    var info: [String:TorrentBencode] = ["name":.bytes(Data(name.utf8)),"length":.integer(Int64(length)),"piece length":.integer(16384),"pieces":.bytes(Data(count:20*((length+16383)/16384)))]
    if isPrivate { info["private"] = .integer(1) }
    return TorrentBencode.encode(.dictionary(["announce":.bytes(Data("http://127.0.0.1:9/announce".utf8)),"info":.dictionary(info)]))
  }
  private func root()->URL { FileManager.default.temporaryDirectory.appendingPathComponent("UniPlayerAudit-"+UUID().uuidString) }
  func testCancelledUnreachableMagnetCanBeInspectedAgainAndCancelIsImmediate() async throws {
    let folder = root(), runtime = TransmissionRuntime(root:root())
    let source = try TorrentRuntimeSource(magnet:"magnet:?xt=urn:btih:"+String(repeating:"b",count:40))
    do {
      _ = try await runtime.start()
      let client = try await runtime.start(); _ = try await client.call("session_set",["dht_enabled":false,"pex_enabled":false])
      for _ in 0..<2 {
        let model = TorrentInspection(title:"Unreachable fixture",runtime:runtime) { source }
        model.begin()
        for _ in 0..<100 { if model.snapshot != nil { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(model.busy)
        let done = expectation(description:"Owned inspection cleanup")
        var dismissed = false; model.dismiss = { dismissed = true }; model.cleanupFinished = { done.fulfill() }
        let start = Date(); model.cancel(); XCTAssertTrue(dismissed); XCTAssertLessThan(Date().timeIntervalSince(start),1)
        await fulfillment(of:[done],timeout:8)
        let jobs = try await runtime.all(); XCTAssertTrue(jobs.isEmpty)
      }
      await runtime.shutdown(); let owned = runtime.root; try? FileManager.default.removeItem(at:owned); try? FileManager.default.removeItem(at:folder)
    } catch { await runtime.shutdown(); throw error }
  }
  func testDaemonCrashReleasesProfileLockAndChangesGeneration() async throws {
    let folder = root(), runtime = TransmissionRuntime(root:root())
    do {
      _ = try await runtime.start(); let before = await runtime.runtimeGeneration()
      let supervisorValue = await runtime.supervisorProcessIdentifier(), supervisor = try XCTUnwrap(supervisorValue)
      let command = Process(); command.executableURL = URL(fileURLWithPath:"/usr/bin/pgrep"); command.arguments = ["-P",String(supervisor)]
      let pipe = Pipe(); command.standardOutput = pipe; try command.run(); command.waitUntilExit()
      let text = String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
      let pid = try XCTUnwrap(Int32(text.trimmingCharacters(in:.whitespacesAndNewlines)))
      XCTAssertEqual(kill(pid,SIGKILL),0)
      for _ in 0..<100 { if await !runtime.isRunning() { break }; try await Task.sleep(for:.milliseconds(20)) }
      let start = Date(); _ = try await runtime.start(); XCTAssertLessThan(Date().timeIntervalSince(start),3)
      let after = await runtime.runtimeGeneration(); XCTAssertGreaterThan(after,before)
      await runtime.finish()
      do { _ = try await runtime.start(); XCTFail("Terminated runtime relaunched") } catch {}
      try? FileManager.default.removeItem(at:runtime.root); try? FileManager.default.removeItem(at:folder)
    } catch { await runtime.shutdown(); throw error }
  }
  func testFailedPlayPreservesRetainedTransferAndStore() async throws {
    let folder = root(), runtime = TransmissionRuntime(root:root(),quotaBytes:1024*1024)
    let store = TorrentPlaybackStore(file:folder.appendingPathComponent("playback.json")), coordinator = TorrentPlaybackCoordinator(runtime:runtime,store:store)
    do {
      let value = try await runtime.add(TorrentRuntimeSource(metainfo:metainfo(isPrivate:true))).0
      try await runtime.inspect(value.hash,knownMetadata:true)
      for _ in 0..<100 { if try await runtime.find(value.hash,fresh:true)?.status == 6 { break }; try await Task.sleep(for:.milliseconds(20)) }
      let beforeValue = try await runtime.find(value.hash,fresh:true), before = try XCTUnwrap(beforeValue)
      do { try await coordinator.play(snapshot:before,file:before.files[0],origin:nil,continueAfterClose:true); XCTFail("Over-quota Play admitted") } catch {}
      let afterValue = try await runtime.find(value.hash,fresh:true), after = try XCTUnwrap(afterValue)
      XCTAssertEqual(after.status,before.status); XCTAssertEqual(after.wanted,before.wanted)
      XCTAssertTrue(store.records.isEmpty); XCTAssertTrue(coordinator.sessions.isEmpty)
      await coordinator.quit(); try? FileManager.default.removeItem(at:runtime.root); try? FileManager.default.removeItem(at:folder)
    } catch { await coordinator.quit(); throw error }
  }
  func testPublicRemoveRecoversQuotaAndProtectsPrivateAndActiveLeases() async throws {
    let folder = root(), runtime = TransmissionRuntime(root:root(),quotaBytes:3*1024*1024)
    do {
      let first = try await runtime.add(TorrentRuntimeSource(metainfo:metainfo(name:"first.mp4"))).0
      let second = try await runtime.add(TorrentRuntimeSource(metainfo:metainfo(name:"second.mp4"))).0
      let path = try await runtime.secureFile(first,file:first.files[0]); try Data(count:2*1024*1024).write(to:path)
      do { try await runtime.admit(second,file:second.files[0]); XCTFail("Full quota admitted") } catch {}
      try await runtime.prepare(first,file:first.files[0])
      do { try await runtime.removeStopped(first.hash,deleteData:true); XCTFail("Live writer removed") } catch {}
      try await runtime.stop(first.hash)
      try await runtime.removeStopped(first.hash,deleteData:true)
      XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
      try await runtime.admit(second,file:second.files[0])
      let privateJob = try await runtime.add(TorrentRuntimeSource(metainfo:metainfo(name:"private.mp4",length:1024,isPrivate:true))).0
      do { try await runtime.removeStopped(privateJob.hash,deleteData:true); XCTFail("Private data removed") } catch {}
      let retained = try await runtime.find(privateJob.hash,fresh:true); XCTAssertNotNil(retained)
      let unknown = try await runtime.add(TorrentRuntimeSource(magnet:"magnet:?xt=urn:btih:"+String(repeating:"c",count:40))).0
      XCTAssertFalse(unknown.metadataComplete)
      do { try await runtime.removeStopped(unknown.hash,deleteData:true); XCTFail("Unclassified data removed") } catch {}
      let unclassified = try await runtime.find(unknown.hash,fresh:true); XCTAssertNotNil(unclassified)
      await runtime.shutdown(); try? FileManager.default.removeItem(at:runtime.root); try? FileManager.default.removeItem(at:folder)
    } catch { await runtime.shutdown(); throw error }
  }
  func testCorruptOrFutureStoreIsPreservedAndWarningsAreNonfatal() throws {
    let folder = root(); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:folder) }
    let file = folder.appendingPathComponent("playback.json"), bytes = Data("{\"version\":99,\"records\":[]}".utf8)
    try bytes.write(to:file)
    let store = TorrentPlaybackStore(file:file)
    XCTAssertFalse(store.canWrite)
    let record = TorrentPlaybackRecord(identity:TorrentIdentity(hash:String(repeating:"a",count:40),fileIndex:0),file:TorrentFile(index:0,name:"a.mp4",length:1,offset:0),title:"a",position:0,duration:0,continueAfterClose:false,isPrivate:false)
    XCTAssertFalse(store.save(record)); XCTAssertEqual(try Data(contentsOf:file),bytes)
    let warning = try TorrentSnapshot(json:["hash_string":String(repeating:"a",count:40),"error":1])
    XCTAssertTrue(warning.error); XCTAssertFalse(warning.fatalError)
    let local = try TorrentSnapshot(json:["hash_string":String(repeating:"a",count:40),"error":3]); XCTAssertTrue(local.fatalError)
    XCTAssertFalse(TorrentPrivacy.redact("GET /torrent-media/private-cap/media.mp4 and https://tracker.test/private-passkey/announce").contains("private-cap"))
    XCTAssertFalse(TorrentPrivacy.redact("https://tracker.test/private-passkey/announce").contains("private-passkey"))
  }
  func testTransientOpenURLWindowDoesNotCancelPendingNativeCheck() async throws {
    let old = UserDefaults.standard.object(forKey:TorrentPreferences.enabledKey)
    UserDefaults.standard.set(true,forKey:TorrentPreferences.enabledKey)
    defer { UserDefaults.standard.set(old,forKey:TorrentPreferences.enabledKey) }
    let folder = root(), runtime = TransmissionRuntime(root:root())
    let coordinator = TorrentPlaybackCoordinator(runtime:runtime,store:TorrentPlaybackStore(file:folder.appendingPathComponent("playback.json")))
    let transient = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:200),styleMask:[.titled],backing:.buffered,defer:false)
    transient.isReleasedWhenClosed = false; transient.makeKeyAndOrderFront(nil)
    XCTAssertTrue(coordinator.route(URL(string:"magnet:?xt=urn:btih:"+String(repeating:"b",count:40))!))
    transient.close()
    let window = try XCTUnwrap(PlayerCore.first.initialWindow.window?.attachedSheet)
    let host = try XCTUnwrap(window.contentViewController as? NSHostingController<TorrentInspectionView>)
    XCTAssertFalse(host.rootView.model.busy); XCTAssertNil(host.rootView.model.snapshot)
    let running = await runtime.isRunning(); XCTAssertFalse(running,"An OS/browser entry requires an explicit native Check")
    host.rootView.model.cancel(); await coordinator.quit()
    try? FileManager.default.removeItem(at:runtime.root); try? FileManager.default.removeItem(at:folder)
  }
  func testPieceSpanMismatchFailsClosedAndTrackerCountsExpire() throws {
    let value = try TorrentSnapshot(json:["hash_string":String(repeating:"a",count:40),"metadata_percent_complete":1,
      "piece_size":16384,"piece_count":2,"pieces":"wA==","availability":[-1,-1],"files":[["name":"a.bin","length":3,"begin_piece":0,"end_piece":1],["name":"b.mp4","length":20000,"begin_piece":1,"end_piece":2]],
      "tracker_stats":[["host":"tracker.test","seeder_count":9,"leecher_count":0,"last_scrape_succeeded":true,"last_scrape_time":Date().addingTimeInterval(-600).timeIntervalSince1970]]])
    XCTAssertFalse(value.layoutVerified,"The second file actually begins in piece zero")
    XCTAssertNil(value.trackers.first?.seeds)
  }
  func testFeatureOffDoesNotInterceptAndOriginalBrowserLinksPassThrough() {
    let old = UserDefaults.standard.object(forKey:TorrentPreferences.enabledKey)
    defer { UserDefaults.standard.set(old,forKey:TorrentPreferences.enabledKey) }
    UserDefaults.standard.set(false,forKey:TorrentPreferences.enabledKey)
    XCTAssertFalse(TorrentPlaybackCoordinator.shared.route(URL(string:"magnet:?xt=urn:btih:"+String(repeating:"a",count:40))!))
    let bridge = ChannelTorrentBridge(), configuration = WKWebViewConfiguration()
    bridge.install(in:configuration); let web = WKWebView(frame:.zero,configuration:configuration); bridge.attach(to:web,channelID:{nil})
    UserDefaults.standard.set(true,forKey:TorrentPreferences.enabledKey)
    XCTAssertFalse(bridge.handleLink(URL(string:"https://example.test/file.torrent")!,in:web))
    XCTAssertFalse(bridge.handleLink(URL(string:"magnet:?xt=urn:btih:"+String(repeating:"a",count:40))!,in:web))
  }
}

@MainActor final class TorrentMultiFilePlaybackTests: XCTestCase {
  func testRealDaemonPaddingAndNonalignedSelectedFileRangesMatch() async throws {
    let checkout = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent(), media = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/torrent-fixture.mp4")
    guard FileManager.default.fileExists(atPath:media.path) else { throw XCTSkip("Generate the controlled sample first") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UniPlayerMultiFile-"+UUID().uuidString), fixture = FileManager.default.temporaryDirectory.appendingPathComponent("UniPlayerMultiSeed-"+UUID().uuidString)
    let child = Process(); child.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
    child.arguments = [checkout.appendingPathComponent("tests/torrent-runtime/swarm_fixture.py").path,Bundle.main.resourceURL!.appendingPathComponent("TorrentRuntime/transmission-daemon").path,fixture.path,media.path,"multi"]
    child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run(); let runtime = TransmissionRuntime(root:root)
    var bridge:TorrentMediaBridge?
    do {
      let ready = fixture.appendingPathComponent("ready.json")
      for _ in 0..<200 { if FileManager.default.fileExists(atPath:ready.path) { break }; try await Task.sleep(for:.milliseconds(100)) }
      let setup = try JSONSerialization.jsonObject(with:Data(contentsOf:ready)) as! [String:Any]
      let client = try await runtime.start(); _ = try await client.call("session_set",["dht_enabled":false,"pex_enabled":false,"utp_enabled":false])
      let value = try await runtime.add(TorrentRuntimeSource(metainfo:Data(base64Encoded:setup["metainfo"] as! String)!)).0
      XCTAssertEqual(value.files.count,3); XCTAssertEqual(value.files[2].offset,17780); XCTAssertTrue(value.layoutVerified)
      let file = value.files[2]; try await runtime.prepare(value,file:file)
      let session = try await client.call("session_get",["fields":["peer_port"]])
      _ = try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:\(setup["relayControlPort"] as! Int)/?port=\((session["peer_port"] as! NSNumber).intValue)")!)
      let server = try TorrentMediaBridge(provider:runtime,hash:value.hash,file:file); bridge = server; try await server.start()
      let source = try Data(contentsOf:media)
      var range = URLRequest(url:server.url); range.timeoutInterval = 40; range.setValue("bytes=50000-80000",forHTTPHeaderField:"Range")
      let (partial,response) = try await URLSession.shared.data(for:range)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,206); XCTAssertEqual(partial,source.subdata(in:50000..<80001))
      var suffix = URLRequest(url:server.url); suffix.timeoutInterval = 40; suffix.setValue("bytes=-4096",forHTTPHeaderField:"Range")
      let (tail,_) = try await URLSession.shared.data(for:suffix); XCTAssertEqual(tail,source.suffix(4096))
      var full = URLRequest(url:server.url); full.timeoutInterval = 60
      let (bytes,_) = try await URLSession.shared.data(for:full)
      XCTAssertEqual(SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined(),setup["sha256"] as? String)
      bridge?.stop(); await runtime.shutdown(); child.terminate()
      for _ in 0..<60 { if !child.isRunning { break }; try await Task.sleep(for:.milliseconds(100)) }
      if child.isRunning { child.interrupt() }
      try? FileManager.default.removeItem(at:root); try? FileManager.default.removeItem(at:fixture)
    } catch {
      bridge?.stop(); await runtime.shutdown(); if child.isRunning { child.terminate() }
      for _ in 0..<60 { if !child.isRunning { break }; try? await Task.sleep(for:.milliseconds(100)) }
      if child.isRunning { child.interrupt() }; throw error
    }
  }
}

@MainActor final class TorrentFinalAuditRegressionTests: XCTestCase {
  func testSupervisorDeathReapsOnlyItsOwnedDaemonAndRetainsProfileLease() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UniPlayerSupervisorAudit-"+UUID().uuidString), runtime = TransmissionRuntime(root:FileManager.default.temporaryDirectory.appendingPathComponent("UniPlayerSupervisorRuntime-"+UUID().uuidString))
    do {
      _ = try await runtime.start()
      let pidPath = runtime.root.appendingPathComponent("runtime/daemon.pid")
      let pid = try XCTUnwrap(Int32(try String(contentsOf:pidPath,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)))
      let daemon = try XCTUnwrap(TorrentProcessIdentity.capture(pid))
      XCTAssertTrue(daemon.holdsLock(runtime.root.appendingPathComponent("runtime/owner.lock")))
      let wrapperValue = await runtime.supervisorProcessIdentifier(), wrapper = try XCTUnwrap(wrapperValue)
      XCTAssertEqual(kill(wrapper,SIGKILL),0)
      for _ in 0..<100 { if await !runtime.isRunning() { break }; try await Task.sleep(for:.milliseconds(20)) }
      for _ in 0..<100 { if !daemon.isRunning { break }; try await Task.sleep(for:.milliseconds(50)) }
      XCTAssertFalse(daemon.isRunning,"Supervisor exit must reap its daemon without requiring another start")
      _ = try await runtime.start()
      XCTAssertFalse(daemon.isRunning,"An orphan must be reaped before this profile can restart")
      let replacement = try XCTUnwrap(Int32(try String(contentsOf:pidPath,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)))
      XCTAssertNotEqual(replacement,pid)
      await runtime.finish(); try? FileManager.default.removeItem(at:runtime.root); try? FileManager.default.removeItem(at:root)
    } catch { await runtime.finish(); throw error }
  }
  func testOverlappingLaunchShutdownAndRestartKeepOneGeneration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UniPlayerLaunchRace-"+UUID().uuidString), runtime = TransmissionRuntime(root:FileManager.default.temporaryDirectory.appendingPathComponent("UniPlayerRaceRuntime-"+UUID().uuidString))
    do {
      for _ in 0..<3 {
        let first = Task { try? await runtime.start() }, second = Task { try? await runtime.start() }
        try await Task.sleep(for:.milliseconds(10))
        await runtime.shutdown(); _ = await first.value; _ = await second.value
        async let a = runtime.start(); async let b = runtime.start(); _ = try await (a,b)
        let before = await runtime.runtimeGeneration(), pid = await runtime.supervisorProcessIdentifier()
        let live = try await runtime.start()
        let version = try await live.call("session_get",["fields":["version"]])
        XCTAssertTrue((version["version"] as? String)?.hasPrefix(TransmissionRuntime.requiredVersion) == true)
        let after = await runtime.runtimeGeneration(), next = await runtime.supervisorProcessIdentifier()
        XCTAssertEqual(before,after); XCTAssertEqual(pid,next)
        await runtime.shutdown()
      }
      await runtime.finish(); try? FileManager.default.removeItem(at:runtime.root); try? FileManager.default.removeItem(at:root)
    } catch { await runtime.finish(); throw error }
  }
  func testDedicatedCoreCannotEnableRawLogsOrMpvWatchLaterWrites() {
    let player = PlayerCore.makeTorrentPlayer()
    player.mpv.setFlag(MPVOption.WatchLater.savePositionOnQuit,true)
    player.mpv.setFlag(MPVOption.WatchLater.resumePlayback,true)
    player.mpv.setString(MPVOption.ProgramBehavior.logFile,"/tmp/uniplayer-must-not-write.log")
    player.mpv.setString(MPVOption.WatchLater.watchLaterDir,"/tmp/uniplayer-must-not-write-watchlater")
    XCTAssertFalse(player.mpv.getFlag(MPVOption.WatchLater.savePositionOnQuit))
    XCTAssertFalse(player.mpv.getFlag(MPVOption.WatchLater.resumePlayback))
    XCTAssertEqual(player.mpv.getString(MPVOption.ProgramBehavior.logFile),"")
    XCTAssertEqual(player.mpv.getString(MPVOption.WatchLater.watchLaterDir),"/dev/null")
    XCTAssertTrue(player.plugins.isEmpty)
  }
  func testGenuineDaemonAcceptsCleanedFilenamesWithoutLosingLayout() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UniPlayerNamesAudit-"+UUID().uuidString), runtime = TransmissionRuntime(root:FileManager.default.temporaryDirectory.appendingPathComponent("UniPlayerNamesRuntime-"+UUID().uuidString))
    do {
      var values:[Data] = ["A: B?.mkv"," lead.mkv"].map { name in TorrentFixture.metainfo(name:name) }
      values.append(TorrentBencode.encode(.dictionary(["info":.dictionary(["name":.bytes(Data("root".utf8)),"piece length":.integer(16384),"pieces":.bytes(Data(count:20)),"private":.integer(1),"files":.list([.dictionary(["length":.integer(16384),"path":.list([.bytes(Data("dir.".utf8)),.bytes(Data("x.mkv".utf8))])])])])])) )
      for data in values {
        let parsed = try TorrentMetainfo(data), result = try await runtime.add(TorrentRuntimeSource(metainfo:data))
        XCTAssertEqual(result.0.hash,parsed.hash); XCTAssertTrue(result.0.layoutVerified)
        XCTAssertEqual(result.0.files.map(\.length),parsed.files.map(\.length)); XCTAssertEqual(result.0.files.map(\.offset),parsed.files.map(\.offset))
      }
      await runtime.finish(); try? FileManager.default.removeItem(at:runtime.root); try? FileManager.default.removeItem(at:root)
    } catch { await runtime.finish(); throw error }
  }
}
