import AppKit
import SwiftUI

struct TorrentSettingsContent: View {
  @AppStorage(TorrentPreferences.enabledKey) private var enabled = true
  @AppStorage(TorrentPreferences.resourcePosts) private var resourcePosts = true
  @AppStorage(TorrentPreferences.quotaGiB) private var quota = 50
  @ObservedObject private var store = TorrentPlaybackStore.shared
  @State private var jobs: [TorrentTransferSummary] = []
  @State private var usage = "Not measured"
  @State private var error: String?
  @State private var busy = false
  @State private var disabledHosts = Set(UserDefaults.standard.stringArray(forKey:"torrent.playback.disabledHosts.v1") ?? [])
  var body: some View {
    VStack(alignment:.leading,spacing:Tokens.Space.n12) {
      Toggle("Enable Torrent Playback (Preview)",isOn:$enabled)
        .onChange(of:enabled) { _, _ in NotificationCenter.default.post(name:TorrentPreferences.changed,object:nil) }
      Text("Adds Check & Play next to magnet and torrent links. Nothing is fetched until you activate an action. Public magnet inspection may download metadata and small test pieces. Transfers stop when UniPlayer quits.")
        .font(Tokens.Typography.caption.font).foregroundStyle(Tokens.Palette.textSecondary.color)
      Toggle("Enable resource-link actions (experimental)",isOn:$resourcePosts)
        .disabled(!enabled)
        .onChange(of:resourcePosts) { _, _ in NotificationCenter.default.post(name:TorrentPreferences.changed,object:nil) }
      Text("On any site, a link labelled as a torrent or shaped like a torrent post is checked when you press Check; only a single unambiguous magnet or .torrent is used. Cloud-only posts, sign-in and challenge pages still require the original site. Direct magnet and .torrent links work independently.")
        .font(Tokens.Typography.caption.font).foregroundStyle(Tokens.Palette.textSecondary.color)
      Text("Transmission \(TransmissionRuntime.requiredVersion) · Unmodified runtime · v1 torrents")
      Picker("Cache budget",selection:$quota) {
        ForEach([10,25,50,100,250,500],id:\.self) { value in Text("\(value) GiB").tag(value) }
      }
      HStack(spacing:Tokens.Space.n8) {
        Button("Choose Cache Location…") { Task { await chooseFolder() } }.disabled(busy || !jobs.isEmpty)
        Button("Refresh Transfers & Usage") { refresh() }.disabled(busy)
      }
      Text("Cache: \(UserDefaults.standard.string(forKey:TorrentPreferences.cachePath) ?? "Application Support/TorrentPlayback/v1/cache") · \(usage)")
        .font(Tokens.Typography.caption.font).textSelection(.enabled)
      Text("A 2 GiB free-space reserve is required. Change the location before adding torrents. Retained data counts toward the budget and is never automatically deleted.")
        .font(Tokens.Typography.caption.font).foregroundStyle(Tokens.Palette.textSecondary.color)
      ForEach(Array(Set(ChannelStore.shared.channels.compactMap { $0.url.host })).sorted(),id:\.self) { host in
        Toggle("Show actions on \(host)",isOn:Binding(get:{ !disabledHosts.contains(host) },set:{ on in
          if on { disabledHosts.remove(host) } else { disabledHosts.insert(host) }
          UserDefaults.standard.set(Array(disabledHosts),forKey:"torrent.playback.disabledHosts.v1")
          NotificationCenter.default.post(name:TorrentPreferences.changed,object:nil)
        }))
      }
      if !jobs.isEmpty { Text("Owned transfers").font(Tokens.Typography.bodyStrong.font) }
      ForEach(jobs,id:\.hash) { job in
        HStack(spacing:Tokens.Space.n8) {
          VStack(alignment:.leading,spacing:Tokens.Space.n4) {
            Text(job.title).lineLimit(2)
            if job.error { Text(job.fatalError ? "Local file or disk error" : "Tracker warning · existing transfer continues").font(Tokens.Typography.caption.font) }
            Text("\(job.status == 0 ? "Stopped" : "Active") · ↓ \(ByteCountFormatter.string(fromByteCount:job.downloaded,countStyle:.file)) · ↑ \(ByteCountFormatter.string(fromByteCount:job.uploaded,countStyle:.file))")
              .font(Tokens.Typography.caption.font)
          }
          Spacer()
          if job.status == 0 {
            Button("Resume Transfer") { Task { do { try await TorrentPlaybackCoordinator.shared.resumeTransfer(hash:job.hash); refresh() } catch { self.error = "Couldn’t resume this transfer. Open its original source to retry." } } }
            if job.metadataComplete && !job.isPrivate { Button("Remove…") { remove(job) } }
          }
          Button("Stop Torrent") { Task { await TorrentPlaybackCoordinator.shared.stop(hash:job.hash); refresh() } }.disabled(job.status == 0)
        }
      }
      if let error = error ?? store.failure { Text(error).font(Tokens.Typography.caption.font) }
    }.font(Tokens.Typography.body.font).padding(Tokens.Space.n12)
  }
  private func remove(_ job:TorrentTransferSummary) {
    let alert = NSAlert(); alert.messageText = "Remove this stopped public torrent?"
    alert.informativeText = "This removes its owned cached files and saved torrent playback state. Private retained data is not removed."
    alert.addButton(withTitle:"Remove Torrent & Data"); alert.addButton(withTitle:"Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task { do { try await TorrentPlaybackCoordinator.shared.remove(hash:job.hash,deleteData:true); refresh() } catch { self.error = (error as? TorrentFailure)?.localizedDescription ?? "Couldn’t remove this torrent." } }
  }
  private func refresh() {
    busy = true
    Task {
      do {
        jobs = try await TransmissionRuntime.shared.summaries()
        let root = await TransmissionRuntime.shared.cacheRoot()
        let bytes = try await Task.detached { try TransmissionRuntime.allocatedBytes(root) }.value
        usage = ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file); error = nil
      } catch { self.error = "Couldn’t read the owned runtime. Retry after stopping playback." }
      busy = false
      await TorrentPlaybackCoordinator.shared.releaseIdleRuntime()
    }
  }
  private func chooseFolder() async {
    busy = true; defer { busy = false }
    do {
      guard try await TransmissionRuntime.shared.summaries().isEmpty else { error = "The current cache contains torrents. Keep its location so retained data remains accessible."; return }
    } catch { self.error = "Couldn’t check retained torrents. Retry before changing the cache location."; return }
    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
    panel.prompt = "Choose Cache Folder"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    UserDefaults.standard.set(url.path,forKey:TorrentPreferences.cachePath)
  }
}
final class TorrentSettingsView: NSView {
  private let host = NSHostingView(rootView:TorrentSettingsContent())
  init() {
    super.init(frame:.zero); addSubview(host); host.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo:leadingAnchor),host.trailingAnchor.constraint(equalTo:trailingAnchor),host.topAnchor.constraint(equalTo:topAnchor),host.bottomAnchor.constraint(equalTo:bottomAnchor)])
  }
  required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
}
