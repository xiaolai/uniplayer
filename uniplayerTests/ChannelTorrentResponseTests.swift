//
//  ChannelTorrentResponseTests.swift
//  UniPlayerTests
//

import XCTest
@testable import UniPlayer

final class ChannelTorrentResponseTests: XCTestCase {
  private func response(_ url: String, headers: [String: String]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: headers)!
  }

  func testBittorrentMimeIsATorrent() {
    let value = response("https://api.m-team.cc/api/rss/dlv2?sign=x",
                         headers: ["Content-Type": "application/x-bittorrent"])
    XCTAssertTrue(ChannelTorrentResponse.isTorrent(value))
  }

  func testAttachmentFilenameIsATorrent() {
    let value = response("https://example.test/download/9f13",
                         headers: ["Content-Disposition": "attachment; filename=\"[M-TEAM][1276269]Mutiny.torrent\""])
    XCTAssertTrue(ChannelTorrentResponse.isTorrent(value))
  }

  func testTorrentPathIsATorrent() {
    let value = response("https://example.test/files/release.torrent", headers: [:])
    XCTAssertTrue(ChannelTorrentResponse.isTorrent(value))
  }

  func testHTMLResponseIsNotATorrent() {
    let value = response("https://example.test/login",
                         headers: ["Content-Type": "text/html", "Content-Disposition": "attachment; filename=\"login.html\""])
    XCTAssertFalse(ChannelTorrentResponse.isTorrent(value))
  }

  func testGenericBinaryIsNotATorrent() {
    let value = response("https://example.test/files/archive.zip",
                         headers: ["Content-Type": "application/zip"])
    XCTAssertFalse(ChannelTorrentResponse.isTorrent(value))
  }

  func testTitleStripsTheTorrentExtension() {
    XCTAssertEqual(
      ChannelTorrentResponse.title("[M-TEAM][1276269]Mutiny 2026.torrent", fallback: "Page"),
      "[M-TEAM][1276269]Mutiny 2026")
  }

  func testTitleFallsBackToThePageThenToAGenericName() {
    XCTAssertEqual(ChannelTorrentResponse.title(nil, fallback: "Detail page"), "Detail page")
    XCTAssertEqual(ChannelTorrentResponse.title("  ", fallback: "  "), "Torrent download")
  }
}
