import Foundation

struct TorrentPlaybackRecord: Codable, Equatable, Identifiable {
  let identity: TorrentIdentity
  let file: TorrentFile
  var title: String
  var position: Double
  var duration: Double
  var channelID: String?
  var sourcePage: URL?
  var continueAfterClose: Bool
  var isPrivate: Bool
  var id: String { identity.url.absoluteString }
}

/// No magnets, signed download URLs, tracker credentials or HTTP capabilities.
/// Engine metainfo/resume files remain in the separate protected runtime profile.
@MainActor final class TorrentPlaybackStore: ObservableObject {
  static let shared = TorrentPlaybackStore()
  @Published private(set) var records: [TorrentPlaybackRecord] = []
  @Published private(set) var failure: String?
  private let file: URL
  private(set) var canWrite = true
  private struct Envelope: Codable { let version:Int; let records:[TorrentPlaybackRecord] }
  init(file: URL = Utility.appSupportDirUrl.appendingPathComponent("TorrentPlayback/v1/playback.json")) {
    self.file = file
    if FileManager.default.fileExists(atPath:file.path) {
      do {
        let data = try Data(contentsOf:file)
        if let envelope = try? JSONDecoder().decode(Envelope.self,from:data) {
          guard envelope.version == 1 else { throw TorrentFailure.invalidSource }; records = envelope.records
        } else { records = try JSONDecoder().decode([TorrentPlaybackRecord].self,from:data) }
        guard records.allSatisfy({ TorrentFile.safePath($0.file.name) && $0.identity.fileIndex == $0.file.index && $0.position.isFinite && $0.duration.isFinite }) else { throw TorrentFailure.invalidSource }
      } catch { canWrite = false; failure = "Playback state is unreadable or uses a newer format. The original file is preserved; repair or back it up before saving new torrent state." }
    }
  }

  static func sanitizedPage(_ url: URL?) -> URL? {
    guard let url, ChannelTorrentCandidate.isMini4K(url), url.path.range(of:#"^/(movies|torrents)/[0-9]+/?$"#,options:.regularExpression) != nil,
          var parts = URLComponents(url:url,resolvingAgainstBaseURL:false) else { return nil }
    parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil; return parts.url
  }
  func record(_ identity: TorrentIdentity) -> TorrentPlaybackRecord? { records.first { $0.identity == identity } }
  @discardableResult func save(_ record: TorrentPlaybackRecord) -> Bool {
    var values = records
    if let index = values.firstIndex(where:{ $0.identity == record.identity }) { values[index] = record } else { values.append(record) }
    return write(values)
  }
  @discardableResult func remove(_ identity:TorrentIdentity) -> Bool { write(records.filter { $0.identity != identity }) }
  @discardableResult func remove(hash:String) -> Bool { write(records.filter { $0.identity.hash != hash }) }
  private func write(_ values:[TorrentPlaybackRecord]) -> Bool {
    guard canWrite else { return false }
    do {
      let root = file.deletingLastPathComponent()
      try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
      try JSONEncoder().encode(Envelope(version:1,records:values)).write(to:file,options:.atomic)
      try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
      records = values; failure = nil; return true
    } catch { failure = "Couldn’t save torrent playback state. Check the application support folder permissions."; return false }
  }
}
