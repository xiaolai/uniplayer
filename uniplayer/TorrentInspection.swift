import AppKit
import SwiftUI
import WebKit

@MainActor final class TorrentInspection: ObservableObject {
  @Published var snapshot: TorrentSnapshot?
  @Published var selected = -1
  @Published var continueAfterClose = false
  @Published var message = "Resolving the selected source…"
  @Published var failure: String?
  @Published var busy = true
  @Published var playing = false
  @Published var confirmSwitch = false
  @Published var observedAt: Date?
  @Published var runtimeVersion = "Not started"
  let title: String
  let candidate: ChannelTorrentCandidate?
  private let runtime: TransmissionRuntime
  private weak var owner: TorrentPlaybackCoordinator?
  private var task: Task<Void,Never>?
  private var playTask: Task<Void,Never>?
  var cancelSource: (() -> Void)?
  private var ownsInspection = false
  private var hash: String?
  private var cancelled = false
  private let resolve: () async throws -> TorrentRuntimeSource
  var cleanupBegan: (() -> Void)?
  var cleanupFinished: (() -> Void)?
  var dismiss: (() -> Void)?
  init(title: String, candidate: ChannelTorrentCandidate? = nil, runtime: TransmissionRuntime = .shared,owner:TorrentPlaybackCoordinator? = nil, resolve: @escaping () async throws -> TorrentRuntimeSource) {
    self.title = title; self.candidate = candidate; self.runtime = runtime; self.owner = owner; self.resolve = resolve
  }
  var file: TorrentFile? { snapshot?.files.first { $0.index == selected && $0.playable && $0.length > 0 } }
  var canPlay: Bool { !playing && !cancelled && file != nil && snapshot?.metadataComplete == true && snapshot?.layoutVerified == true && snapshot?.clientVersionRejected != true }
  var playLabel: String { confirmSwitch ? "Switch File" : (snapshot?.peers ?? 0) > 0 ? "Play" : "Try Playback" }
  func begin() {
    guard task == nil, playTask == nil, !cancelled else { return }
    busy = true; failure = nil
    task = Task { [self] in
      defer { task = nil; if !playing { busy = false } }
      do {
        let source = try await resolve(); try Task.checkCancellation()
        hash = source.hash
        let (initial, existed) = try await runtime.add(source)
        hash = initial.hash
        let protected = owner?.protects(hash:initial.hash) ?? (TorrentPlaybackStore.shared.failure != nil || TorrentPlaybackStore.shared.records.contains { $0.identity.hash == initial.hash })
        ownsInspection = !existed || (!protected && initial.status == 0)
        guard !cancelled else { if ownsInspection { await runtime.discardInspection(initial.hash) }; return }
        runtimeVersion = await runtime.version
        update(initial)
        if !ownsInspection { message = "Existing owned transfer. Inspection does not change its download or seeding policy."; return }
        message = initial.metadataComplete ? "Checking tracker reports. No video files are selected for inspection." : "Metadata and small test pieces may download: 64 KiB/s, up to 20 seconds. The 2 MiB target is a soft limit."
        try await runtime.inspect(initial.hash,knownMetadata:initial.metadataComplete)
        let deadline = Date().addingTimeInterval(20); var metadataConfigured = initial.metadataComplete
        while Date() < deadline {
          try Task.checkCancellation()
          guard let current = try await runtime.find(initial.hash,fresh:true) else { throw TorrentFailure.cancelled }
          update(current)
          let received = max(0,current.downloaded-initial.downloaded)
          if received > 8*1024*1024 { throw TorrentFailure.unavailable("Inspection exceeded its transfer safety threshold and was stopped.") }
          if current.metadataComplete && !metadataConfigured { try await runtime.mutate("torrent_set",hash:current.hash,["files_unwanted":[]]); metadataConfigured = true }
          if received >= 2*1024*1024 { break }
          try await Task.sleep(for:.milliseconds(500))
        }
        try await runtime.stop(initial.hash)
        message = snapshot?.metadataComplete == true ? "Inspection stopped. Counts are observations, not a guarantee of playback. Play starts the selected file’s transfer." : "No metadata found yet. Availability is unknown. Retry or keep waiting."
      } catch {
        if ownsInspection, let hash { await runtime.stopInspection(hash) }
        if !cancelled && !playing { failure = (error as? TorrentFailure)?.localizedDescription ?? "The source could not be inspected. Open its original page, then retry." }
      }
    }
  }
  private func update(_ value:TorrentSnapshot) {
    snapshot = value; observedAt = Date()
    if selected < 0, let preferred = value.preferredFile {
      selected = preferred.index
      continueAfterClose = TorrentPlaybackStore.shared.records.first { $0.identity.hash == value.hash }?.continueAfterClose ?? value.isPrivate
    }
    if value.metadataComplete && value.preferredFile == nil { failure = TorrentFailure.unsupportedMedia.localizedDescription }
    if value.clientVersionRejected { failure = "Client Version Not Approved. The tracker rejected this genuine Transmission runtime. Use an actually approved version; identity overrides are not supported." }
    else if value.error { failure = value.fatalError ? "Transmission reports a local file or disk error. Stop the torrent and check its cache." : "Tracker warning. Availability may be unknown; an existing playback or seeding transfer continues." }
  }
  func retry() { guard !busy && !playing else { return }; begin() }
  func play() {
    guard canPlay, let snapshot, let file else { return }
    guard let owner else { failure = "The playback window owner is unavailable. Reopen the source."; return }
    if owner.requiresSwitch(hash:snapshot.hash,file:file), !confirmSwitch {
      confirmSwitch = true; message = "This torrent already has a player. Switch File closes that player after the selected source is prepared successfully."; return
    }
    playing = true; task?.cancel(); let previous = task
    playTask = Task { [self] in
      defer { busy = false; playTask = nil }
      await previous?.value
      guard !cancelled, !Task.isCancelled else { return }
      busy = true
      do {
        try await owner.play(snapshot:snapshot,file:file,origin:candidate,continueAfterClose:continueAfterClose,allowSwitch:confirmSwitch)
        ownsInspection = false; dismiss?()
      } catch { failure = (error as? TorrentFailure)?.localizedDescription ?? "Playback could not start. Retry the source."; playing = false }
    }
  }
  func cancel() {
    guard !cancelled else { return }; cancelled = true
    task?.cancel(); playTask?.cancel(); cancelSource?()
    let previous = task, previousPlay = playTask
    cleanupBegan?(); dismiss?()
    if hash == nil { cleanupFinished?(); return }
    // Keep ownership until cleanup finishes, without holding the sheet open.
    Task { [self] in
      await previous?.value; await previousPlay?.value
      if ownsInspection, let hash { await runtime.stopInspection(hash); await runtime.discardInspection(hash) }
      cleanupFinished?()
    }
  }
}

struct TorrentInspectionView: View {
  @ObservedObject var model: TorrentInspection
  @AppStorage("interface.textScale.v1") private var textScale = 1.0
  var body: some View {
    VStack(alignment:.leading,spacing:Tokens.Space.n16) {
      HStack(spacing:Tokens.Space.n12) {
        Image(systemName:"play.rectangle.on.rectangle").font(Tokens.Typography.detailTitleStrong.scaledFont(textScale))
        VStack(alignment:.leading,spacing:Tokens.Space.n4) {
          Text("Check & Play").font(Tokens.Typography.detailTitleStrong.scaledFont(textScale))
          Text(model.title).font(Tokens.Typography.body.scaledFont(textScale)).lineLimit(2)
        }
        Spacer()
        if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Checking torrent") }
      }
      Text("Transmission · \(model.runtimeVersion)").font(Tokens.Typography.caption.scaledFont(textScale)).foregroundStyle(Tokens.Palette.textSecondary.color)
      Text(model.message).font(Tokens.Typography.body.scaledFont(textScale)).accessibilityIdentifier("torrent.inspection.status")
      ScrollView {
        VStack(alignment:.leading,spacing:Tokens.Space.n12) {
          if let snapshot = model.snapshot {
            TimelineView(.periodic(from:.now,by:15)) { context in
              if context.date.timeIntervalSince(model.observedAt ?? .distantPast) < 60 {
                VStack(alignment:.leading,spacing:Tokens.Space.n8) {
                  LabeledContent("Connected peers",value:"\(snapshot.peers) (\(snapshot.completePeers) report complete)")
                  if snapshot.trackers.isEmpty { Text("Tracker seed totals: Unknown · DHT/peer observations only") }
                  ForEach(Array(snapshot.trackers.enumerated()),id:\.offset) { _, tracker in
                    VStack(alignment:.leading,spacing:Tokens.Space.n4) {
                      Text(tracker.host)
                      Text("Seeds: \(tracker.seeds.map(String.init) ?? "Unknown") · Leechers: \(tracker.leechers.map(String.init) ?? "Unknown")")
                      if let time = tracker.observedAt { Text(time,format:.dateTime.month().day().hour().minute()) }
                    }.font(Tokens.Typography.caption.scaledFont(textScale))
                  }
                }
              } else { Text("Availability observations expired. Retry to refresh; playback remains available for a valid file.") }
            }
            if snapshot.metadataComplete {
              Picker("Video file",selection:$model.selected) {
                ForEach(snapshot.files.filter { $0.playable && $0.length > 0 }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { file in
                  Text("\(file.name) · \(ByteCountFormatter.string(fromByteCount:file.length,countStyle:.file))").tag(file.index)
                }
              }
              Toggle("Continue downloading & seeding after closing the player",isOn:$model.continueAfterClose)
                .disabled(model.playing)
              Text(snapshot.isPrivate ? "Private torrent. Keep the original metainfo and follow your tracker’s rules. Playback downloads the selected file; Continue keeps that transfer seeding while the app runs. Group approval is not verified." : "Public transfer. Closing the player stops it unless Continue is selected.")
                .font(Tokens.Typography.caption.scaledFont(textScale)).foregroundStyle(Tokens.Palette.textSecondary.color)
              Text("Transfers stop when UniPlayer quits. Files are retained; nothing is automatically deleted.")
                .font(Tokens.Typography.caption.scaledFont(textScale)).foregroundStyle(Tokens.Palette.textSecondary.color)
            }
          }
          if let failure = model.failure { Label(failure,systemImage:"exclamationmark.triangle").foregroundStyle(Tokens.Palette.textPrimary.color) }
        }.font(Tokens.Typography.body.scaledFont(textScale))
      }
      Divider()
      HStack(spacing:Tokens.Space.n8) {
        Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
        if let source = model.candidate?.url, model.failure != nil {
          Button("Open Source") { NotificationCenter.default.post(name:TorrentPlaybackCoordinator.returnToSource,object:model.candidate); if source.scheme == "magnet" { return }; model.cancel() }
        }
        Button(model.snapshot == nil ? "Check" : "Retry / Keep Waiting") { model.retry() }.disabled(model.busy || model.playing)
        Spacer()
        Button(model.playLabel) { model.play() }.keyboardShortcut(.defaultAction).disabled(!model.canPlay)
          .accessibilityIdentifier("torrent.inspection.play")
      }
    }.onChange(of:model.selected) { _, _ in model.confirmSwitch = false }
      .padding(Tokens.Space.n24).frame(width:Tokens.Torrent.sheetWidth,height:Tokens.Torrent.sheetHeight)
      .preferredColorScheme(.dark)
  }
}
