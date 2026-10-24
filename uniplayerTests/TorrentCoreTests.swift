import XCTest
@testable import UniPlayer

final class TorrentSourceContractTests: XCTestCase {
  func testMagnetCanonicalizationAndUnsupportedV2() throws {
    let hash = String(repeating: "a", count: 40)
    XCTAssertEqual(try TorrentMagnet("magnet:?xt=urn:btih:" + hash.uppercased()).hash, hash)
    XCTAssertEqual(try TorrentMagnet("magnet:?xt=urn:btih:" + String(repeating: "A", count: 32)).hash, String(repeating: "0", count: 40))
    XCTAssertThrowsError(try TorrentMagnet("magnet:?xt=urn:btmh:1220abcdef"))
    XCTAssertThrowsError(try TorrentMagnet("magnet:?xt=urn:btih:bad"))
    XCTAssertThrowsError(try TorrentMagnet("https://example.test/?xt=urn:btih:" + hash))
  }
  func testV1MetainfoValidatesHashFilesAndPrivateFlag() throws {
    let data = TorrentFixture.metainfo()
    let descriptor = try TorrentMetainfo(data)
    XCTAssertEqual(descriptor.files.count, 1)
    XCTAssertEqual(descriptor.files[0].name, "example.mp4")
    XCTAssertEqual(descriptor.files[0].length, 16384)
    XCTAssertTrue(descriptor.isPrivate)
    XCTAssertEqual(descriptor.hash.count, 40)
    XCTAssertTrue(descriptor.files[0].playable)
  }
  func testMalformedMetainfoAndTraversalRejected() {
    for text in ["de", "i-0e", "d4:infoi1ee", "d1:ai1e1:ai2ee", "d1:bi1e1:ai2ee", "l" + String(repeating: "l", count: 40)] {
      XCTAssertThrowsError(try TorrentMetainfo(Data(text.utf8)))
    }
    XCTAssertThrowsError(try TorrentMetainfo(TorrentFixture.metainfo(name: "../escape.mp4")))
    XCTAssertThrowsError(try TorrentMetainfo(TorrentFixture.metainfo(name: "/absolute.mp4")))
    XCTAssertThrowsError(try TorrentMetainfo(TorrentFixture.metainfo(pieces: Data(count: 19))))
  }
  func testByteRangesAreExactAndBounded() throws {
    XCTAssertEqual(try TorrentByteRange.parse(nil, length: 100), TorrentByteRange(start: 0, end: 99, partial: false))
    XCTAssertEqual(try TorrentByteRange.parse("bytes=10-19", length: 100).count, 10)
    XCTAssertEqual(try TorrentByteRange.parse("bytes=90-", length: 100).start, 90)
    XCTAssertEqual(try TorrentByteRange.parse("bytes=-10", length: 100).start, 90)
    XCTAssertEqual(try TorrentByteRange.parse("bytes=90-200", length: 100).end, 99)
    for header in ["bytes=100-", "bytes=20-10", "bytes=-0", "bytes=0-1,5-6", "items=0-4", "bytes=999999999999999999999-"] {
      XCTAssertThrowsError(try TorrentByteRange.parse(header, length: 100))
    }
  }
  func testFileOffsetsMapAcrossPieceBoundaries() throws {
    let file = TorrentFile(index: 1, name: "episode.mkv", length: 100, offset: 50)
    XCTAssertEqual(try file.pieces(for: TorrentByteRange(start: 20, end: 79, partial: true), pieceSize: 64), 1...2)
    XCTAssertThrowsError(try file.pieces(for: TorrentByteRange(start: 0, end: 100, partial: true), pieceSize: 64))
  }
  func testStableIdentityAndLogRedaction() {
    let id = TorrentIdentity(hash: String(repeating: "a", count: 40), fileIndex: 2)
    XCTAssertEqual(TorrentIdentity(url: id.url), id)
    let secret = "sensitive-capability"
    let text = "open http://127.0.0.1:9999/torrent-media/" + secret + "/movie.mp4 and magnet:?xt=urn:btih:abc"
    let safe = TorrentPrivacy.redact(text)
    XCTAssertFalse(safe.contains(secret)); XCTAssertFalse(safe.contains("urn:btih"))
    XCTAssertFalse(TorrentPrivacy.redact("tracker https://example.test/a?passkey=private-value").contains("private-value"))
  }
  func testUnknownHealthIsNotZeroAndLocalPieceIsNotMinusOnePeer() throws {
    let snapshot = try TorrentSnapshot(json: ["hash_string": String(repeating: "a", count: 40), "name": "Example", "metadata_percent_complete": 1,
      "piece_count": 3, "piece_size": 16384, "pieces": Data([0x80]).base64EncodedString(), "availability": [-1, 2, 0],
      "tracker_stats": [["host":"tracker.test", "seeder_count": -1, "leecher_count": 0, "last_scrape_succeeded": false]], "files": [["name":"a.mp4","length":49152,"begin_piece":0,"end_piece":3]]])
    XCTAssertNil(snapshot.trackers.first?.seeds)
    XCTAssertTrue(snapshot.hasPiece(0)); XCTAssertFalse(snapshot.hasPiece(1))
    XCTAssertEqual(snapshot.availablePieces(in: 0...2), 2)
    XCTAssertEqual(snapshot.files[0].offset, 0)
  }
}

enum TorrentFixture {
  static func metainfo(name: String = "example.mp4", pieces: Data = Data(count: 20)) -> Data {
    TorrentBencode.encode(.dictionary(["announce": .bytes(Data("http://127.0.0.1:9/announce".utf8)),
      "info": .dictionary(["length": .integer(16384), "name": .bytes(Data(name.utf8)), "piece length": .integer(16384), "pieces": .bytes(pieces), "private": .integer(1)])]))
  }
}
