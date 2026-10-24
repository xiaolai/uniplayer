import AppKit
import SwiftUI
import WebKit

final class TorrentPlayerContext {
  let record: TorrentPlaybackRecord
  let transportURL: URL
  let resumePosition: Double
  weak var owner: TorrentPlaybackCoordinator?
  var resumed = false
  init(record: TorrentPlaybackRecord, resume: Bool, owner: TorrentPlaybackCoordinator,transportURL:URL) { self.record = record; self.transportURL = transportURL; resumePosition = resume && (record.duration <= 0 || record.position < record.duration-3) ? record.position : 0; self.owner = owner }
}

@MainActor final class TorrentPlaybackCoordinator: NSObject {
  static let shared = TorrentPlaybackCoordinator()
  static let returnToSource = Notification.Name("TorrentReturnToSource")
  struct Session {
    let player: PlayerCore; let bridge: TorrentMediaBridge; let record: TorrentPlaybackRecord; let generation:Int
  }
  private let runtime: TransmissionRuntime
  private let store: TorrentPlaybackStore
  init(runtime: TransmissionRuntime = .shared, store: TorrentPlaybackStore = .shared) {
    self.runtime = runtime; self.store = store; super.init()
  }
  private(set) var sessions: [String:Session] = [:]
  private var sheet: NSWindow?
  private var inspectionCleanup = 0
  private var inspection: TorrentInspection?
  private var switching = Set<String>()
  private var sourceWindows: [String:WeakWindow] = [:]
  private var originWindow: WeakWindow?
  private var parentObserver: NSObjectProtocol?
  private var monitor: Task<Void,Never>?
  private(set) var quitting = false
  nonisolated static func recognizes(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "magnet" || url.scheme == "uniplayer-torrent" || url.pathExtension.lowercased() == "torrent"
  }
  @discardableResult func route(_ url: URL) -> Bool {
    guard Self.recognizes(url) else { return false }
    guard TorrentPreferences.enabled else { return false }
    if let identity = TorrentIdentity(url:url) {
      Task {
        do {
          guard let record = store.record(identity), let snapshot = try await runtime.find(identity.hash,fresh:true),
                snapshot.files.contains(record.file) else { throw TorrentFailure.unavailable("This torrent is no longer in the owned cache. Open its original source again.") }
          try await play(snapshot:snapshot,file:record.file,origin:nil,continueAfterClose:record.continueAfterClose)
        } catch { showError((error as? TorrentFailure)?.localizedDescription ?? "Couldn’t reopen this torrent.") }
      }
      return true
    }
    PlayerCore.first.initialWindow.showWindow(nil)
    if url.isFileURL {
      present(title:url.lastPathComponent,parent:PlayerCore.first.initialWindow.window) {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 10 * 1024 * 1024 else { throw TorrentFailure.invalidMetainfo }
        return try TorrentRuntimeSource(metainfo:Data(contentsOf:url))
      }
    } else if url.scheme?.lowercased() == "magnet" {
      present(title:(try? TorrentMagnet(url.absoluteString).displayName) ?? "Magnet source",parent:PlayerCore.first.initialWindow.window) { try TorrentRuntimeSource(magnet:url.absoluteString) }
    } else {
      showError("Open protected torrent links from their logged-in Channel, or download the .torrent file and open it locally.")
    }
    return true
  }
  func present(_ candidate: ChannelTorrentCandidate, web: WKWebView, isCurrent: @escaping () -> Bool) {
    let resolver = ChannelTorrentResolver(webView:web)
    present(title:candidate.title,candidate:candidate,parent:web.window,autoStart:false, cancel:{ resolver.cancel() }) {
      try await resolver.resolve(candidate,isCurrent:isCurrent)
    }
  }
  private func present(title: String,candidate: ChannelTorrentCandidate? = nil,parent: NSWindow? = nil,autoStart:Bool = false,cancel: @escaping () -> Void = {},resolve: @escaping () async throws -> TorrentRuntimeSource) {
    guard !quitting else { return }
    guard inspectionCleanup == 0 else { showError("The previous inspection is stopping. Retry in a moment."); return }
    guard sheet == nil else { sheet?.makeKeyAndOrderFront(nil); return }
    let parent = parent ?? NSApp.keyWindow ?? PlayerCore.first.initialWindow.window
    guard parent?.attachedSheet == nil else { showError("Finish the current dialog before inspecting another source."); return }
    let model = TorrentInspection(title:title,candidate:candidate,runtime:runtime,owner:self,resolve:resolve)
    model.cleanupBegan = { [weak self] in self?.inspectionCleanup += 1 }
    model.cleanupFinished = { [weak self] in
      guard let self else { return }; self.inspectionCleanup = max(0,self.inspectionCleanup-1)
      Task { await self.releaseIdleRuntime() }
    }
    model.cancelSource = cancel
    let window = NSWindow(contentViewController:NSHostingController(rootView:TorrentInspectionView(model:model)))
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named:.darkAqua); window.title = "Check & Play"
    sheet = window; inspection = model
    model.dismiss = { [weak self,weak parent,weak window] in
      cancel()
      if let window { parent?.endSheet(window); window.orderOut(nil) }
      self?.sheet = nil; self?.inspection = nil
      if let observer = self?.parentObserver { NotificationCenter.default.removeObserver(observer); self?.parentObserver = nil }
      Task { await self?.releaseIdleRuntime() }
    }
    if let parent { parent.beginSheet(window) } else { window.center(); window.makeKeyAndOrderFront(nil) }
    originWindow = candidate == nil ? nil : WeakWindow(parent)
    if let parent {
      parentObserver = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:parent,queue:.main) { [weak model] _ in
        Task { @MainActor in model?.cancel() }
      }
    }
    if autoStart { model.begin() } else { model.busy = false; model.message = "Check retrieves metadata and may download small test pieces for up to 20 seconds at 64 KiB/s. Select Check to continue." }
  }
  func protects(hash:String) -> Bool { !store.canWrite || store.records.contains { $0.identity.hash == hash } }
  func requiresSwitch(hash:String,file:TorrentFile) -> Bool { sessions[hash].map { $0.record.file != file } ?? false }
  func play(snapshot: TorrentSnapshot,file: TorrentFile,origin: ChannelTorrentCandidate?,continueAfterClose: Bool,allowSwitch:Bool = false) async throws {
    guard !quitting, !switching.contains(snapshot.hash) else { throw TorrentFailure.unavailable("This torrent is already switching files. Retry in a moment.") }
    if let session = sessions[snapshot.hash], session.record.file == file {
      session.player.mainWindow.showWindow(nil); session.player.mainWindow.window?.makeKeyAndOrderFront(nil); return
    }
    guard !requiresSwitch(hash:snapshot.hash,file:file) || allowSwitch else { throw TorrentFailure.unavailable("This torrent already has a different file playing. Use Check & Play to confirm Switch File.") }
    switching.insert(snapshot.hash); defer { switching.remove(snapshot.hash) }
    if let previous = sessions[snapshot.hash] { savePosition(player:previous.player) }
    let configuration = try await runtime.configuration(snapshot.hash)
    guard configuration.snapshot.files.contains(file), configuration.snapshot.layoutVerified else { throw TorrentFailure.protocolMismatch }
    let identity = TorrentIdentity(hash:snapshot.hash,fileIndex:file.index)
    let old = store.record(identity)
    let record = TorrentPlaybackRecord(identity:identity,file:file,title:(file.name as NSString).lastPathComponent,
      position:old?.position ?? 0,duration:old?.duration ?? 0,channelID:origin?.channelID ?? old?.channelID,
      sourcePage:TorrentPlaybackStore.sanitizedPage(origin?.originURL) ?? old?.sourcePage,
      continueAfterClose:continueAfterClose,isPrivate:configuration.snapshot.isPrivate)
    guard store.save(record) else { throw TorrentFailure.unavailable(store.failure ?? "Couldn’t save playback state.") }
    let generation = await runtime.runtimeGeneration()
    let bridge: TorrentMediaBridge
    do { bridge = try TorrentMediaBridge(provider:runtime,hash:snapshot.hash,file:file) }
    catch { if let old { store.save(old) } else { store.remove(identity) }; throw error }
    do {
      try Task.checkCancellation()
      try await bridge.start()
      try await runtime.prepare(configuration.snapshot,file:file)
      try Task.checkCancellation()
      guard await runtime.runtimeGeneration() == generation else { throw TorrentFailure.cancelled }
    } catch {
      bridge.stop()
      let restored = await Task { do { try await runtime.restore(configuration); return true } catch { return false } }.value
      if let old { store.save(old) } else { store.remove(identity) }
      guard restored else { throw TorrentFailure.unavailable("Playback did not start and the previous transfer state could not be restored. Files are retained. Check Torrent Playback settings before retrying.") }
      throw error
    }
    if let previous = sessions.removeValue(forKey:snapshot.hash) {
      previous.bridge.stop(); previous.player.mainWindow.close()
    }
    // Always create a dedicated existing PlayerCore. Never borrow the Library's inline core.
    let player = PlayerCore.makeTorrentPlayer()
    player.torrentContext = TorrentPlayerContext(record:record,resume:Preference.bool(for:.resumeLastPosition),owner:self,transportURL:bridge.url)
    player.mpv.setFlag(MPVOption.WatchLater.resumePlayback,false)
    player.mpv.setFlag(MPVOption.WatchLater.savePositionOnQuit,false)
    player.mpv.setString("force-media-title",record.title)
    if origin != nil { sourceWindows[snapshot.hash] = originWindow }
    sessions[snapshot.hash] = Session(player:player,bridge:bridge,record:record,generation:generation)
    player.openURL(bridge.url,shouldAutoLoad:false)
    installCommands(player)
    startMonitor()
  }
  private func installCommands(_ player: PlayerCore) {
    // Window menu commands use the current standalone player; no titlebar changes.
    guard let menu = NSApp.windowsMenu, menu.items.first(where:{ $0.action == #selector(returnFromMenu) }) == nil else { return }
    let back = NSMenuItem(title:"Return to Torrent Source",action:#selector(returnFromMenu),keyEquivalent:""); back.target = self
    let stop = NSMenuItem(title:"Stop Torrent",action:#selector(stopFromMenu),keyEquivalent:""); stop.target = self
    menu.addItem(.separator()); menu.addItem(back); menu.addItem(stop)
  }
  @objc private func returnFromMenu() {
    guard let record = PlayerCore.active.torrentContext?.record else { return }
    returnTo(record)
  }
  @objc private func stopFromMenu() { if let hash = PlayerCore.active.torrentContext?.record.identity.hash { Task { await stop(hash:hash) } } }
  func returnTo(_ record: TorrentPlaybackRecord) {
    let original = sourceWindows[record.identity.hash]?.value
    let window = original ?? PlayerCore.first.initialWindow.window
    if original == nil { PlayerCore.first.initialWindow.showWindow(nil) }
    window?.makeKeyAndOrderFront(nil)
    NotificationCenter.default.post(name:Self.returnToSource,object:record,userInfo:window.map { ["window":$0] })
  }
  func savePosition(player: PlayerCore) {
    guard let context = player.torrentContext else { return }
    var record = context.record
    let position = player.info.videoPosition?.second ?? record.position
    if context.resumePosition > 0 && (!context.resumed || abs(position-context.resumePosition) > 3 && position < 1) { return }
    record.position = max(0,position)
    record.duration = max(0,player.info.videoDuration?.second ?? record.duration)
    guard record.position.isFinite, record.duration.isFinite else { return }
    store.save(record)
  }
  func detach(player: PlayerCore) {
    guard let context = player.torrentContext else { return }
    let session = sessions[context.record.identity.hash].flatMap { $0.player === player ? $0 : nil }
    savePosition(player:player)
    if let session { sessions[context.record.identity.hash] = nil; session.bridge.stop() }
    player.torrentContext = nil
    // This core remains dedicated; ordinary playback uses a normal core.
    player.mpv.setFlag(MPVOption.WatchLater.resumePlayback,false)
    player.mpv.setFlag(MPVOption.WatchLater.savePositionOnQuit,false)
    player.mpv.setString("force-media-title","")
    if let session, !session.record.continueAfterClose || quitting {
      Task { guard !quitting else { return }; try? await runtime.stop(session.record.identity.hash); await runtime.releaseReservation(session.record.identity.hash); await releaseIdleRuntime() }
    }
  }
  func stop(hash: String) async {
    if let session = sessions.removeValue(forKey:hash) {
      savePosition(player:session.player); session.bridge.stop(); session.player.mainWindow.close()
    }
    do { try await runtime.stop(hash); await runtime.releaseReservation(hash) }
    catch { showError("Couldn’t stop the torrent. Quit UniPlayer to stop its owned runtime, then retry.") }
  }
  func remove(hash:String,deleteData:Bool) async throws {
    guard sessions[hash] == nil, !switching.contains(hash), inspection == nil, inspectionCleanup == 0 else { throw TorrentFailure.unavailable("Close the player and inspection sheet before removing a torrent.") }
    try await runtime.removeStopped(hash,deleteData:deleteData)
    store.remove(hash:hash)
  }
  func resumeTransfer(hash:String) async throws {
    guard !quitting, !switching.contains(hash), let record = store.records.first(where:{ $0.identity.hash == hash }), let snapshot = try await runtime.find(hash,fresh:true), snapshot.files.contains(record.file) else { throw TorrentFailure.invalidSource }
    try await runtime.prepare(snapshot,file:record.file); startMonitor()
  }
  func releaseIdleRuntime() async {
    guard inspection == nil, inspectionCleanup == 0, sessions.isEmpty, switching.isEmpty, !quitting, await runtime.isRunning() else { return }
    guard let jobs = try? await runtime.summaries(), jobs.allSatisfy({ $0.status == 0 }), inspection == nil, inspectionCleanup == 0, sessions.isEmpty, switching.isEmpty else { return }
    await runtime.shutdown()
  }
  func quit() async {
    quitting = true; inspection?.cancel(); monitor?.cancel(); monitor = nil
    for session in sessions.values { savePosition(player:session.player); session.bridge.stop() }
    sessions.removeAll(); await runtime.finish()
  }
  private func startMonitor() {
    guard monitor == nil else { return }
    monitor = Task { [weak self] in
      var failures = 0
      while !Task.isCancelled {
        try? await Task.sleep(for:.seconds(5)); guard let self, !Task.isCancelled, !quitting else { return }
        do {
          let active = try await runtime.summaries().filter { $0.status != 0 }
          failures = 0
          let generation = await runtime.runtimeGeneration()
          if sessions.values.contains(where:{ $0.generation != generation }) {
            for session in Array(sessions.values) { session.bridge.stop(); session.player.mainWindow.close() }
            showError("The torrent runtime restarted. Transfers are paused and files are retained. Reopen the source to retry playback.")
          }
          for value in active {
            if value.fatalError { await stop(hash:value.hash); showError("Transmission reported a local file or disk error. Files are retained. Check the cache in Settings, then reopen the source to retry."); continue }
            do { try await runtime.checkDiskReserve() }
            catch { await stop(hash:value.hash); showError(TorrentFailure.diskSpace.localizedDescription) }
          }
          if active.isEmpty && sessions.isEmpty && inspection == nil && switching.isEmpty && inspectionCleanup == 0 { await runtime.shutdown(); monitor = nil; return }
        } catch {
          failures += 1; if failures < 3 { continue }
          await runtime.shutdown()
          for session in Array(sessions.values) { session.bridge.stop(); session.player.mainWindow.close() }
          showError("The torrent runtime stopped. Your files are retained; reopen the source to retry."); monitor = nil; return
        }
      }
    }
  }
  private func showError(_ text: String) { let alert = NSAlert(); alert.messageText = "Torrent Playback"; alert.informativeText = text; alert.runModal() }
  private final class WeakWindow { weak var value: NSWindow?; init(_ value: NSWindow?) { self.value = value } }
}
