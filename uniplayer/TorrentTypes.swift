import Foundation
import CryptoKit

/// Source and transport failures are deliberately free of tracker/session URLs.
enum TorrentFailure: Error, LocalizedError, Equatable {
  case invalidSource, unsupportedV2, invalidMetainfo, unsupportedMedia, needsVerification
  case unavailable(String), cancelled, timedOut, diskSpace, unsafePath, protocolMismatch
  var errorDescription: String? {
    switch self {
    case .invalidSource: return "This is not a valid torrent source."
    case .unsupportedV2: return "This Transmission version does not support pure BitTorrent v2. Use a v1 torrent or a supported hybrid."
    case .invalidMetainfo: return "The torrent metadata is invalid or exceeds the supported limits."
    case .unsupportedMedia: return "No supported video or audio file was found. This post may contain cloud-drive links."
    case .needsVerification: return "Complete the website’s login or verification in the Channel, then retry."
    case .unavailable(let text): return text
    case .cancelled: return "The torrent action was cancelled."
    case .timedOut: return "No response yet. You can retry or keep waiting."
    case .diskSpace: return "The selected file exceeds the available disk space or torrent cache budget. Raise the cache budget or remove stopped public torrents in Settings. Choose a new location after removing owned jobs."
    case .unsafePath: return "The torrent contains an unsafe file path."
    case .protocolMismatch: return "The bundled Transmission runtime does not match the required version or capabilities."
    }
  }
}

struct TorrentMagnet: Equatable {
  let uri: String
  let hash: String
  let displayName: String?
  init(_ raw: String) throws {
    guard raw.utf8.count <= 65536, let parts = URLComponents(string: raw), parts.scheme?.lowercased() == "magnet" else { throw TorrentFailure.invalidSource }
    let exact = parts.queryItems?.filter { $0.name == "xt" }.compactMap(\.value) ?? []
    let hashes = exact.filter { $0.lowercased().hasPrefix("urn:btih:") }.compactMap { Self.decodeHash(String($0.dropFirst(9))) }
    guard let hash = hashes.first, Set(hashes).count == 1 else {
      if exact.contains(where: { $0.lowercased().hasPrefix("urn:btmh:") }) { throw TorrentFailure.unsupportedV2 }
      throw TorrentFailure.invalidSource
    }
    self.hash = hash; uri = raw
    displayName = parts.queryItems?.first { $0.name == "dn" }?.value.map { String($0.prefix(300)) }
  }
  static func decodeHash(_ raw: String) -> String? {
    if raw.count == 40, raw.allSatisfy({ $0.isASCII && $0.isHexDigit }) { return raw.lowercased() }
    guard raw.count == 32 else { return nil }
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var accumulator: UInt32 = 0, bits = 0, bytes: [UInt8] = []
    for char in raw.uppercased() {
      guard let value = alphabet.firstIndex(of: char) else { return nil }
      accumulator = (accumulator << 5) | UInt32(value); bits += 5
      if bits >= 8 { bits -= 8; bytes.append(UInt8((accumulator >> bits) & 255)) }
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }
}

indirect enum TorrentBencode: Equatable {
  case bytes(Data), integer(Int64), list([TorrentBencode]), dictionary([String: TorrentBencode])
  var number: Int64? { if case .integer(let n) = self { return n }; return nil }
  var data: Data? { if case .bytes(let d) = self { return d }; return nil }
  var text: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
  var dict: [String: TorrentBencode]? { if case .dictionary(let d) = self { return d }; return nil }
  var array: [TorrentBencode]? { if case .list(let a) = self { return a }; return nil }
  static func encode(_ value: TorrentBencode) -> Data {
    switch value {
    case .integer(let n): return Data("i\(n)e".utf8)
    case .bytes(let b): return Data("\(b.count):".utf8) + b
    case .list(let a): return Data([108]) + a.reduce(into: Data()) { $0 += encode($1) } + Data([101])
    case .dictionary(let d): return Data([100]) + d.keys.sorted().reduce(into: Data()) { $0 += encode(.bytes(Data($1.utf8))); $0 += encode(d[$1]!) } + Data([101])
    }
  }
  static func decode(_ data: Data) throws -> (TorrentBencode, Data?) {
    guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else { throw TorrentFailure.invalidMetainfo }
    let bytes = [UInt8](data); var index = 0, entries = 0; var infoBytes: Data?
    func parse(_ depth: Int) throws -> TorrentBencode {
      guard depth < 32, index < bytes.count, entries < 100000 else { throw TorrentFailure.invalidMetainfo }; entries += 1
      let marker = bytes[index]
      if marker == 105 {
        index += 1; let start = index
        while index < bytes.count, bytes[index] != 101 { index += 1 }
        guard index < bytes.count, let value = String(bytes: bytes[start..<index], encoding: .ascii), let n = Int64(value), String(n) == value else { throw TorrentFailure.invalidMetainfo }
        index += 1; return .integer(n)
      }
      if marker == 108 || marker == 100 {
        index += 1; var list: [TorrentBencode] = [], dict: [String: TorrentBencode] = [:]; var previous: Data?
        while index < bytes.count, bytes[index] != 101 {
          if marker == 108 { list.append(try parse(depth + 1)) }
          else {
            guard let keyBytes = try parse(depth + 1).data, let key = String(data: keyBytes, encoding: .utf8), previous == nil || previous!.lexicographicallyPrecedes(keyBytes) else { throw TorrentFailure.invalidMetainfo }
            previous = keyBytes; let start = index; dict[key] = try parse(depth + 1)
            if depth == 0, key == "info" { infoBytes = Data(bytes[start..<index]) }
          }
        }
        guard index < bytes.count else { throw TorrentFailure.invalidMetainfo }; index += 1
        return marker == 108 ? .list(list) : .dictionary(dict)
      }
      guard (48...57).contains(marker) else { throw TorrentFailure.invalidMetainfo }
      let start = index
      while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
      guard index < bytes.count, bytes[index] == 58, let lengthText = String(bytes: bytes[start..<index], encoding: .ascii), let length = Int(lengthText), String(length) == lengthText, length >= 0 else { throw TorrentFailure.invalidMetainfo }
      index += 1; guard length <= bytes.count - index else { throw TorrentFailure.invalidMetainfo }
      let result = Data(bytes[index..<(index + length)]); index += length; return .bytes(result)
    }
    let value = try parse(0); guard index == bytes.count else { throw TorrentFailure.invalidMetainfo }; return (value, infoBytes)
  }
}

struct TorrentFile: Codable, Equatable, Identifiable {
  let index: Int; let name: String; let length: Int64; let offset: Int64
  var id: Int { index }
  var playable: Bool { ["mp4","m4v","mkv","mov","avi","webm","ts","m2ts","mpg","mpeg","wmv","flv","ogv","mp3","flac","m4a","aac","wav","ogg"].contains((name as NSString).pathExtension.lowercased()) }
  var sample: Bool { (name as NSString).lastPathComponent.lowercased().range(of: #"(^|[._ -])(sample|trailer)([._ -]|$)"#, options: .regularExpression) != nil }
  func pieces(for range: TorrentByteRange, pieceSize: Int64) throws -> ClosedRange<Int> {
    guard pieceSize > 0, offset >= 0, length > 0, range.start >= 0, range.end >= range.start, range.end < length, offset <= Int64.max - range.end else { throw TorrentFailure.invalidMetainfo }
    return Int((offset + range.start) / pieceSize)...Int((offset + range.end) / pieceSize)
  }
  static func safePath(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 4096 && !name.hasPrefix("/") && !name.contains("\0") && !name.contains("\\") && name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}

struct TorrentMetainfo {
  let hash: String; let files: [TorrentFile]; let isPrivate: Bool; let pieceSize: Int64
  init(_ bytes: Data) throws {
    let (value, rawInfo) = try TorrentBencode.decode(bytes)
    guard let info = value.dict?["info"]?.dict, let rawInfo else { throw TorrentFailure.invalidMetainfo }
    if info["meta version"]?.number == 2, info["pieces"]?.data == nil { throw TorrentFailure.unsupportedV2 }
    guard let size = info["piece length"]?.number, size >= 16384, size <= 32 * 1024 * 1024, size & (size - 1) == 0,
          let name = info["name.utf-8"]?.text ?? info["name"]?.text, TorrentFile.safePath(name), !name.contains("/") else { throw TorrentFailure.unsafePath }
    var result: [TorrentFile] = [], offset: Int64 = 0
    if let list = info["files"]?.array {
      guard !list.isEmpty, list.count <= 10000 else { throw TorrentFailure.invalidMetainfo }
      for (index, value) in list.enumerated() {
        guard let file = value.dict, let length = file["length"]?.number, length >= 0,
              let path = (file["path.utf-8"] ?? file["path"])?.array else { throw TorrentFailure.invalidMetainfo }
        let components = try path.map { part -> String in guard let text = part.text, TorrentFile.safePath(text), !text.contains("/") else { throw TorrentFailure.unsafePath }; return text }
        guard !components.isEmpty, offset <= Int64.max - length else { throw TorrentFailure.invalidMetainfo }
        result.append(TorrentFile(index: index, name: ([name] + components).joined(separator: "/"), length: length, offset: offset)); offset += length
      }
    } else {
      guard let length = info["length"]?.number, length > 0 else { throw TorrentFailure.invalidMetainfo }
      result = [TorrentFile(index: 0, name: name, length: length, offset: 0)]; offset = length
    }
    guard offset > 0, let pieces = info["pieces"]?.data, pieces.count % 20 == 0, Int64(pieces.count / 20) == (offset - 1) / size + 1 else { throw TorrentFailure.invalidMetainfo }
    hash = Insecure.SHA1.hash(data: rawInfo).map { String(format: "%02x", $0) }.joined()
    files = result; isPrivate = info["private"]?.number != nil && info["private"]?.number != 0; pieceSize = size
  }
}

struct TorrentByteRange: Equatable {
  let start: Int64; let end: Int64; let partial: Bool
  var count: Int64 { end - start + 1 }
  static func parse(_ header: String?, length: Int64) throws -> Self {
    guard length > 0 else { throw TorrentFailure.invalidSource }
    guard let header else { return Self(start: 0, end: length - 1, partial: false) }
    guard header.hasPrefix("bytes="), !header.contains(",") else { throw TorrentFailure.invalidSource }
    let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2 else { throw TorrentFailure.invalidSource }
    func number(_ s: Substring) -> Int64? { guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }; return Int64(s) }
    if parts[0].isEmpty {
      guard let count = number(parts[1]), count > 0 else { throw TorrentFailure.invalidSource }
      return Self(start: max(0, length - count), end: length - 1, partial: true)
    }
    guard let start = number(parts[0]), start < length else { throw TorrentFailure.invalidSource }
    let end: Int64
    if parts[1].isEmpty { end = length - 1 } else { guard let value = number(parts[1]), value >= start else { throw TorrentFailure.invalidSource }; end = min(value, length - 1) }
    return Self(start: start, end: end, partial: true)
  }
}

struct TorrentIdentity: Codable, Equatable {
  let hash: String; let fileIndex: Int
  var url: URL { URL(string: "uniplayer-torrent://\(hash)/\(fileIndex)")! }
  private enum CodingKeys: String,CodingKey { case hash,fileIndex }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy:CodingKeys.self)
    let hash = try values.decode(String.self,forKey:.hash), index = try values.decode(Int.self,forKey:.fileIndex)
    guard hash.count == 40, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }), index >= 0, index < 10000 else { throw TorrentFailure.invalidSource }
    self.hash = hash.lowercased(); fileIndex = index
  }
  init(hash: String, fileIndex: Int) { self.hash = hash; self.fileIndex = fileIndex }
  init?(url: URL) {
    guard url.scheme == "uniplayer-torrent", let h = url.host, h.count == 40, h.allSatisfy({ $0.isASCII && $0.isHexDigit }), let index = Int(url.path.dropFirst()), index >= 0, index < 10000 else { return nil }
    hash = h.lowercased(); fileIndex = index
  }
}

enum TorrentPrivacy {
  static func redact(_ message: String) -> String {
    var text = message.replacingOccurrences(of: #"http://127\.0\.0\.1:\d+/torrent-media/[^\s\"'<>]+"#, with: "torrent-media:[private]", options: .regularExpression)
    text = text.replacingOccurrences(of: #"/torrent-media/[^\s\"'<>]+"#, with: "/torrent-media/[private]", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(?i)magnet:\?[^\s\"'<>]+"#, with: "magnet:[private]", options: .regularExpression)
    if let regex = try? NSRegularExpression(pattern:#"https?://[^\s\"'<>]+"#,options:.caseInsensitive) {
      for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).reversed() {
        guard let range = Range(match.range,in:text) else { continue }
        var safe = "web:[private]"
        if var parts = URLComponents(string:String(text[range])), parts.host != nil {
          parts.path = "/[private]"; parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
          safe = parts.url?.absoluteString ?? safe
        }
        text.replaceSubrange(range,with:safe)
      }
    }
    return text
  }
}

struct TorrentTracker: Equatable {
  let host: String; let seeds: Int?; let leechers: Int?; let observedAt: Date?; let success: Bool
}
struct TorrentSnapshot {
  let hash: String; let title: String; let files: [TorrentFile]; let isPrivate: Bool
  let metadataComplete: Bool; let status: Int; let peers: Int; let completePeers: Int
  let trackers: [TorrentTracker]; let pieceSize: Int64; let pieceCount: Int; let pieces: Data; let availability: [Int]
  let downloaded: Int64; let uploaded: Int64; let downloadRate: Int64; let uploadRate: Int64; let downloadDirectory: String
  let wanted: [Bool]
  let downloadLimited: Bool; let downloadLimit: Int; let sequential: Bool; let sequentialFromPiece: Int
  let layoutVerified: Bool
  let errorCode: Int
  var fatalError: Bool { errorCode == 3 }
  let error: Bool
  let clientVersionRejected: Bool
  init(json: [String: Any]) throws {
    guard let hash = json["hash_string"] as? String, hash.count == 40, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw TorrentFailure.protocolMismatch }
    self.hash = hash.lowercased(); title = String((json["name"] as? String ?? "Torrent").prefix(300))
    metadataComplete = ((json["metadata_percent_complete"] as? NSNumber)?.doubleValue ?? 0) >= 1
    isPrivate = json["is_private"] as? Bool ?? false; status = json["status"] as? Int ?? 0
    let peerList = json["peers"] as? [[String: Any]] ?? []
    peers = json["peers_connected"] as? Int ?? 0
    completePeers = peerList.filter { ($0["progress"] as? Double ?? 0) >= 1 }.count
    pieceSize = (json["piece_size"] as? NSNumber)?.int64Value ?? 0
    pieceCount = json["piece_count"] as? Int ?? 0
    pieces = Data(base64Encoded: json["pieces"] as? String ?? "") ?? Data()
    availability = json["availability"] as? [Int] ?? []
    downloaded = (json["downloaded_ever"] as? NSNumber)?.int64Value ?? 0
    uploaded = (json["uploaded_ever"] as? NSNumber)?.int64Value ?? 0
    downloadRate = (json["rate_download"] as? NSNumber)?.int64Value ?? 0
    uploadRate = (json["rate_upload"] as? NSNumber)?.int64Value ?? 0
    downloadDirectory = json["download_dir"] as? String ?? ""
    wanted = (json["wanted"] as? [NSNumber] ?? []).map(\.boolValue)
    downloadLimited = json["download_limited"] as? Bool ?? false; downloadLimit = json["download_limit"] as? Int ?? 64
    sequential = json["sequential_download"] as? Bool ?? false; sequentialFromPiece = json["sequential_download_from_piece"] as? Int ?? 0
    errorCode = json["error"] as? Int ?? 0
    error = errorCode != 0
    let reason = String((json["error_string"] as? String ?? "").prefix(2000))
    clientVersionRejected = error && reason.range(of:#"(?i)(client.*(not (allowed|approved|supported)|banned)|unsupported client)"#,options:.regularExpression) != nil
    var verified = true
    var offset: Int64 = 0, fileList: [TorrentFile] = []
    let values = json["files"] as? [[String: Any]] ?? []
    guard values.count <= 10000 else { throw TorrentFailure.invalidMetainfo }
    for (index, raw) in values.enumerated() {
      guard let name = raw["name"] as? String, TorrentFile.safePath(name), let length = (raw["length"] as? NSNumber)?.int64Value,
            length >= 0, offset <= Int64.max - length else { throw TorrentFailure.unsafePath }
      if length > 0 {
        guard pieceSize > 0 else { throw TorrentFailure.protocolMismatch }
        let begin = Int(offset / pieceSize), end = Int((offset+length-1) / pieceSize)+1
        if raw["begin_piece"] as? Int != begin || raw["end_piece"] as? Int != end { verified = false }
      }
      fileList.append(TorrentFile(index: index, name: name, length: length, offset: offset)); offset += length
    }
    files = fileList
    layoutVerified = verified && (!metadataComplete || (offset > 0 && pieceCount == Int((offset-1)/max(1,pieceSize))+1))
    trackers = (json["tracker_stats"] as? [[String: Any]] ?? []).map { raw in
      func count(_ key: String) -> Int? { guard let n = raw[key] as? Int, n >= 0 else { return nil }; return n }
      let timestamp = max((raw["last_scrape_time"] as? Double ?? 0), (raw["last_announce_time"] as? Double ?? 0))
      let scraped = raw["last_scrape_time"] as? Double ?? 0
      let fresh = scraped > 0 && Date().timeIntervalSince1970-scraped < 60 && raw["last_scrape_succeeded"] as? Bool == true
      let success = raw["last_scrape_succeeded"] as? Bool == true || raw["last_announce_succeeded"] as? Bool == true
      return TorrentTracker(host: String((raw["host"] as? String ?? "Tracker").prefix(200)), seeds: fresh ? count("seeder_count") : nil,
        leechers: fresh ? count("leecher_count") : nil, observedAt: timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil, success: success)
    }
    if metadataComplete { guard pieceSize > 0, pieceCount > 0, pieceCount <= 20_000_000, pieces.count >= (pieceCount + 7) / 8, availability.count == pieceCount else { throw TorrentFailure.protocolMismatch } }
  }
  func hasPiece(_ index: Int) -> Bool { index >= 0 && index < pieceCount && index / 8 < pieces.count && pieces[index / 8] & (128 >> (index % 8)) != 0 }
  func availablePieces(in range: ClosedRange<Int>) -> Int { range.filter { hasPiece($0) || ($0 >= 0 && $0 < availability.count && availability[$0] > 0) }.count }
  var preferredFile: TorrentFile? { files.filter { $0.playable && $0.length > 0 && !$0.sample }.max { $0.length < $1.length } ?? files.first { $0.playable && $0.length > 0 } }
  static let fields = ["hash_string","name","metadata_percent_complete","is_private","status","peers_connected","peers","files","pieces","piece_count","piece_size","availability","tracker_stats","downloaded_ever","uploaded_ever","rate_download","rate_upload","download_dir","error","error_string","wanted","download_limited","download_limit","sequential_download","sequential_download_from_piece"]
}

/// Small transfer-list contract. Large file/piece arrays never enter the monitor.
struct TorrentTransferSummary: Identifiable {
  let hash:String; let title:String; let status:Int; let isPrivate:Bool
  let downloaded:Int64; let uploaded:Int64; let errorCode:Int
  let downloadDirectory:String; let metadataComplete:Bool
  var id:String { hash }
  var error:Bool { errorCode != 0 }
  var fatalError:Bool { errorCode == 3 }
  init(json:[String:Any]) throws {
    guard let hash = json["hash_string"] as? String, hash.count == 40, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }),
          let status = json["status"] as? Int else { throw TorrentFailure.protocolMismatch }
    self.hash = hash.lowercased(); self.status = status; title = String((json["name"] as? String ?? "Torrent").prefix(300))
    isPrivate = json["is_private"] as? Bool ?? false; errorCode = json["error"] as? Int ?? 0
    downloaded = (json["downloaded_ever"] as? NSNumber)?.int64Value ?? 0; uploaded = (json["uploaded_ever"] as? NSNumber)?.int64Value ?? 0
    downloadDirectory = json["download_dir"] as? String ?? ""; metadataComplete = ((json["metadata_percent_complete"] as? NSNumber)?.doubleValue ?? 0) >= 1
  }
  static let fields = ["hash_string","name","status","is_private","downloaded_ever","uploaded_ever","error","download_dir","metadata_percent_complete"]
}
