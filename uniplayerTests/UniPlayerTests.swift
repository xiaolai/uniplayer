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

  // MARK: - Channels

  func testDirectMediaHandoffDoesNotBecomeAChannelFailure() {
    XCTAssertTrue(ChannelNavigationFailure.isExpectedHandoff(
      NSError(domain: "WebKitErrorDomain", code: 204)))
    XCTAssertTrue(ChannelNavigationFailure.isExpectedHandoff(
      NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
    XCTAssertFalse(ChannelNavigationFailure.isExpectedHandoff(
      NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
    XCTAssertFalse(ChannelNavigationFailure.isExpectedHandoff(
      NSError(domain: "OtherDomain", code: 204)))
  }

  func testChannelURLValidation() {
    XCTAssertEqual(
      Channel.validatedURL("example.com")?.absoluteString,
      "https://example.com")
    XCTAssertEqual(
      Channel.validatedURL("https://example.com/watch?v=1")?.absoluteString,
      "https://example.com/watch?v=1")
    XCTAssertNil(Channel.validatedURL("javascript:alert(1)"))
    XCTAssertNil(Channel.validatedURL("file:///tmp/movie.mkv"))
    XCTAssertNil(Channel.validatedURL("ftp://example.com"))
    XCTAssertNil(Channel.validatedURL("   "))
  }

  func testChannelStoreSeedsAndPersistsUserChannels() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-channels-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("channels.json")

    let store = ChannelStore(fileURL: fileURL)
    XCTAssertEqual(store.channels.map(\.id), ["amazon", "netflix"])

    let added = try XCTUnwrap(store.add(name: "YouTube", urlString: "youtube.com"))
    XCTAssertEqual(added.url.absoluteString, "https://youtube.com")

    let reloaded = ChannelStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.channels.map(\.id), ["amazon", "netflix", added.id])

    var edited = added
    edited.name = "YouTube TV"
    edited.url = try XCTUnwrap(Channel.validatedURL("https://www.youtube.com/tv"))
    XCTAssertTrue(reloaded.update(edited))
    XCTAssertEqual(ChannelStore(fileURL: fileURL).channel(id: added.id)?.name, "YouTube TV")

    reloaded.remove(id: added.id)
    XCTAssertEqual(ChannelStore(fileURL: fileURL).channels.map(\.id), ["amazon", "netflix"])
  }

  func testChannelMovesPersistInBothDirections() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-channel-order-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("channels.json")
    let store = ChannelStore(fileURL: fileURL)
    let added = try XCTUnwrap(store.add(name: "YouTube", urlString: "youtube.com"))

    store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    XCTAssertEqual(store.channels.map(\.id), ["netflix", added.id, "amazon"])
    XCTAssertEqual(ChannelStore(fileURL: fileURL).channels, store.channels)

    store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
    XCTAssertEqual(store.channels.map(\.id), ["amazon", "netflix", added.id])
    XCTAssertEqual(ChannelStore(fileURL: fileURL).channels, store.channels)
    XCTAssertEqual(store.channel(id: added.id), added)
  }

  func testChannelMoveHandlesMultipleRowsAndMenuActions() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-channel-order-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("channels.json")
    let store = ChannelStore(fileURL: fileURL)
    let third = try XCTUnwrap(store.add(name: "Third", urlString: "third.example"))
    let fourth = try XCTUnwrap(store.add(name: "Fourth", urlString: "fourth.example"))

    store.move(fromOffsets: IndexSet([0, 2]), toOffset: 4)
    XCTAssertEqual(store.channels.map(\.id), ["netflix", fourth.id, "amazon", third.id])
    store.move(id: "amazon", by: -1)
    XCTAssertEqual(store.channels.map(\.id), ["netflix", "amazon", fourth.id, third.id])
    store.move(id: "amazon", by: 1)
    XCTAssertEqual(store.channels.map(\.id), ["netflix", fourth.id, "amazon", third.id])
    XCTAssertEqual(ChannelStore(fileURL: fileURL).channels, store.channels)
  }

  func testChannelMoveIgnoresBoundariesAndStaleRows() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-channel-order-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ChannelStore(fileURL: directory.appendingPathComponent("channels.json"))
    let original = store.channels

    store.move(id: "amazon", by: -1)
    store.move(id: "netflix", by: 1)
    store.move(id: "deleted", by: -1)
    store.move(fromOffsets: [], toOffset: 0)
    store.move(fromOffsets: IndexSet(integer: 0), toOffset: 1)
    store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
    store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    XCTAssertEqual(store.channels, original)

    for channel in original { store.remove(id: channel.id) }
    store.move(fromOffsets: IndexSet(integer: 0), toOffset: 0)
    XCTAssertTrue(store.channels.isEmpty)
  }

  // MARK: - Private diagnostic data

  func testDiagnosticRedactionRemovesAuthenticatedURLsAndLocalPaths() {
    let message = "Open https://user:fixture@example.test/video?token=fixture#position and file:///tmp/Private%20Movie.mkv"
    let redacted = Logger.redactedMessage(message)
    for value in ["user", "fixture", "example.test", "Private", "token", "position"] {
      XCTAssertFalse(redacted.contains(value))
    }
    XCTAssertEqual(Logger.redactedMessage("Opening /Users/example/Movies/Private Movie.mkv"),
                   "Opening [redacted path]")
    XCTAssertEqual(Logger.redactedMessage("Read 3 history entries"), "Read 3 history entries")
  }

  func testHistoryDescriptionDoesNotExposeViewingDetails() {
    let entry = PlaybackHistory(url: URL(string: "https://example.test/private?token=fixture")!,
                                duration: 120, title: "Private Title", mpvMd5: "fixture")
    XCTAssertEqual(entry.description, "Playback history entry")
  }

  func testSubtitleApplicationHeadersRequireAnExplicitKey() throws {
    XCTAssertThrowsError(try OpenSubClient.applicationHeaders(apiKey: "", userAgent: "fixture"))
    XCTAssertThrowsError(try OpenSubClient.applicationHeaders(apiKey: "  ", userAgent: "fixture"))
    let headers = try OpenSubClient.applicationHeaders(apiKey: "fixture-key", userAgent: "fixture")
    XCTAssertEqual(headers["Api-Key"], "fixture-key")
    XCTAssertEqual(headers["User-Agent"], "fixture")
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
