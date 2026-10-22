//
//  UniPlayerTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

final class UniPlayerTests: XCTestCase {

  // MARK: - Filesystem containment

  func testPathContainmentAcceptsChildren() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let child = root.appendingPathComponent("video.mkv")
    XCTAssertTrue(child.isContained(in: root))
  }

  func testPathContainmentRejectsSiblingWithSharedPrefix() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-tests-\(UUID().uuidString)")
    let root = base.appendingPathComponent("root")
    let sibling = base.appendingPathComponent("root-other")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    XCTAssertFalse(sibling.appendingPathComponent("video.mkv").isContained(in: root))
  }

  func testPathContainmentRejectsSymlinkEscape() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-tests-\(UUID().uuidString)")
    let root = base.appendingPathComponent("root")
    let outside = base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertFalse(outside.appendingPathComponent("secret").isContained(in: root))
  }

  // MARK: - External URL queries

  func testDuplicateQueryNamesKeepFirstValue() {
    let items = [
      URLQueryItem(name: "url", value: "first"),
      URLQueryItem(name: "url", value: "second"),
      URLQueryItem(name: "pip", value: nil),
    ]
    let values = items.firstValueDictionary
    XCTAssertEqual(values["url"], "first")
    XCTAssertEqual(values["pip"], "")
  }

  // MARK: - Thumbnail cache records

  func testCacheBlockLengthValidation() {
    let timestamp = MemoryLayout<Double>.size
    XCTAssertEqual(
      ThumbnailCache.validatedJPEGLength(
        blockLength: Int64(timestamp + 100), remainingBytes: 100),
      100)
    XCTAssertNil(
      ThumbnailCache.validatedJPEGLength(
        blockLength: Int64(timestamp - 1), remainingBytes: 100))
    XCTAssertNil(
      ThumbnailCache.validatedJPEGLength(
        blockLength: Int64(timestamp + 100), remainingBytes: 99))
    XCTAssertNil(
      ThumbnailCache.validatedJPEGLength(
        blockLength: Int64.max, remainingBytes: UInt64.max))
  }

  // MARK: - mpv event values

  func testFlagUsesCIntLayout() {
    var flag: Int32 = 1
    let value = withUnsafeMutablePointer(to: &flag) {
      MPVEventValue.copy(format: .flag, data: UnsafeMutableRawPointer($0), name: "flag")
    }
    XCTAssertEqual(value as? Bool, true)

    var zero: Int32 = 0
    let falseValue = withUnsafeMutablePointer(to: &zero) {
      MPVEventValue.copy(format: .flag, data: UnsafeMutableRawPointer($0), name: "flag")
    }
    XCTAssertEqual(falseValue as? Bool, false)
  }

  func testNumericValuesAreCopied() {
    var integer: Int64 = 42
    let intValue = withUnsafeMutablePointer(to: &integer) {
      MPVEventValue.copy(format: .int64, data: UnsafeMutableRawPointer($0), name: "int")
    }
    XCTAssertEqual(intValue as? Int64, 42)

    var double: Double = 1.5
    let doubleValue = withUnsafeMutablePointer(to: &double) {
      MPVEventValue.copy(format: .double, data: UnsafeMutableRawPointer($0), name: "double")
    }
    XCTAssertEqual(doubleValue as? Double, 1.5)
  }

  func testStringIsCopiedFromCharPointer() {
    let source = strdup("hello")!
    defer { free(source) }
    var pointer: UnsafePointer<CChar>? = UnsafePointer(source)
    let value = withUnsafeMutablePointer(to: &pointer) {
      MPVEventValue.copy(format: .string, data: UnsafeMutableRawPointer($0), name: "string")
    }
    XCTAssertEqual(value as? String, "hello")
  }

  // MARK: - Permission boundaries

  func testHostAllowlistMatchesExactAndWildcardDomains() {
    XCTAssertTrue(JavascriptPluginInstance.hostAllowed("example.com", domains: ["example.com"]))
    XCTAssertFalse(JavascriptPluginInstance.hostAllowed("api.example.com", domains: ["example.com"]))
    XCTAssertTrue(JavascriptPluginInstance.hostAllowed("api.example.com", domains: ["*.example.com"]))
    XCTAssertFalse(JavascriptPluginInstance.hostAllowed("badexample.com", domains: ["*.example.com"]))
    XCTAssertTrue(JavascriptPluginInstance.hostAllowed("anything.invalid", domains: ["*"]))
  }

  // MARK: - Keychain identity

  func testGenericPasswordIdentityUsesServiceAndAccount() {
    let query = KeychainAccess.identityQuery(
      username: "user", service: .openSubAccount, server: nil, port: nil)
    XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
    XCTAssertEqual(query[kSecAttrService as String] as? String, "UniPlayer OpenSubtitles Account")
    XCTAssertEqual(query[kSecAttrAccount as String] as? String, "user")
    XCTAssertNil(query[kSecAttrServer as String])
  }

  func testInternetPasswordIdentityIncludesServerAndPort() {
    let query = KeychainAccess.identityQuery(
      username: "user", service: .httpAuth, server: "example.com", port: 443)
    XCTAssertEqual(query[kSecClass as String] as? String, kSecClassInternetPassword as String)
    XCTAssertEqual(query[kSecAttrServer as String] as? String, "example.com")
    XCTAssertEqual(query[kSecAttrPort as String] as? Int, 443)
  }

  // MARK: - Settings search

  func testSearchRequiresEveryTerm() {
    SettingsSearch.entries.removeAll()
    SettingsSearch.add(entry: .init(
      page: "test", anchor: 1, title: "Network Cache",
      isMain: true, section: nil, parent: nil))
    defer { SettingsSearch.entries.removeAll() }

    XCTAssertEqual(SettingsSearch.search("network cache")?.count, 1)
    XCTAssertEqual(SettingsSearch.search("network missing")?.count, 0)
  }

  // MARK: - History coding

  func testPlaybackHistoryRoundTrips() throws {
    let history = PlaybackHistory(
      url: URL(fileURLWithPath: "/tmp/movie.mkv"),
      duration: 123.5,
      name: "Movie.mkv",
      title: "Movie",
      mpvMd5: "test-\(UUID().uuidString)")

    let data = try NSKeyedArchiver.archivedData(
      withRootObject: history, requiringSecureCoding: true)
    let decoded = try XCTUnwrap(
      NSKeyedUnarchiver.unarchivedObject(ofClass: PlaybackHistory.self, from: data))

    XCTAssertEqual(decoded.url, history.url)
    XCTAssertEqual(decoded.name, history.name)
    XCTAssertEqual(decoded.title, history.title)
    XCTAssertEqual(decoded.duration.second, history.duration.second, accuracy: 0.001)
    XCTAssertTrue(decoded.played)
  }
}
