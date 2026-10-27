//
//  CloudDriveTests.swift
//  UniPlayerTests
//

import WebKit
import XCTest
@testable import UniPlayer

private final class FakeCloudCookieStore: CloudCookieStore {
  var storage: [HTTPCookie]
  init(_ cookies: [HTTPCookie] = []) { storage = cookies }
  func cookies(for url: URL) async -> [HTTPCookie] { storage }
  func store(_ cookies: [HTTPCookie]) async { storage.append(contentsOf: cookies) }
}

final class CloudDrivePolicyTests: XCTestCase {
  private let provider = CloudDriveProvider(
    id: "fixture", displayName: "Fixture",
    pageHosts: [.exact("127.0.0.1")],
    apiHosts: [.exact("127.0.0.1")],
    mediaHosts: [.exact("127.0.0.1")],
    requestUserAgents: ["FixtureAgent/1"],
    mediaUserAgents: ["FixtureAgent/1"],
    adapter: "fixture")

  func testHostRulesMatchExactAndSubdomainOnly() {
    XCTAssertTrue(CloudHostRule.exact("pan.quark.cn").matches("PAN.QUARK.CN"))
    XCTAssertFalse(CloudHostRule.exact("quark.cn").matches("pan.quark.cn"))
    XCTAssertTrue(CloudHostRule.suffix("quark.cn").matches("pan.quark.cn"))
    XCTAssertTrue(CloudHostRule.suffix(".quark.cn").matches("quark.cn"))
    XCTAssertFalse(CloudHostRule.suffix("quark.cn").matches("notquark.cn"))
  }

  func testAliyunProviderIsReadyAndScoped() {
    let aliyun = CloudDrives.provider(id: "aliyun")!
    XCTAssertEqual(aliyun.adapter, "aliyun")
    XCTAssertTrue(aliyun.isResolutionReady)
    XCTAssertTrue(aliyun.ownsPage(host: "www.alipan.com"))
    XCTAssertTrue(aliyun.ownsPage(host: "www.aliyundrive.com"))
    XCTAssertTrue(aliyun.allowsAPI(host: "api.alipan.com"))
    XCTAssertTrue(aliyun.allowsMedia(host: "cdn.alipan.com"))
    XCTAssertTrue(aliyun.allowsMedia(host: "data.aliyunpds.com"))
    XCTAssertFalse(aliyun.allowsMedia(host: "pan.quark.cn"))
  }

  func testProviderLookupUsesThePageHost() {
    XCTAssertEqual(CloudDrives.provider(forPageURL: URL(string: "https://pan.quark.cn/list")!)?.id, "quark")
    XCTAssertEqual(CloudDrives.provider(forPageURL: URL(string: "https://www.alipan.com/drive")!)?.id, "aliyun")
    XCTAssertNil(CloudDrives.provider(forPageURL: URL(string: "https://example.test/")!))
  }

  func testMediaURLMustBeHTTPSOnADeclaredHost() {
    XCTAssertNotNil(CloudDrives.validatedMediaURL("https://cdn.quark.cn/file", provider: CloudDrives.provider(id: "quark")!))
    XCTAssertNil(CloudDrives.validatedMediaURL("http://cdn.quark.cn/file", provider: CloudDrives.provider(id: "quark")!))
    XCTAssertNil(CloudDrives.validatedMediaURL("https://evil.test/file", provider: CloudDrives.provider(id: "quark")!))
    XCTAssertNil(CloudDrives.validatedMediaURL("https://user:pass@cdn.quark.cn/file", provider: CloudDrives.provider(id: "quark")!))
  }

  func testHeaderValidationRefusesControlCharactersAndBackslashes() {
    XCTAssertEqual(CloudDrives.validatedHeaderName("X-Device-Id"), "X-Device-Id")
    XCTAssertNil(CloudDrives.validatedHeaderName("Bad Name"))
    XCTAssertNil(CloudDrives.validatedHeaderName("X\r\nInjected"))
    XCTAssertEqual(CloudDrives.validatedHeaderValue("a, b"), "a, b")
    XCTAssertNil(CloudDrives.validatedHeaderValue("a\r\nb"))
    XCTAssertNil(CloudDrives.validatedHeaderValue("a\\b"))
  }

  func testHeaderFieldsEscapeSeparators() {
    let options = PlaybackHTTPOptions(
      userAgent: nil, referrer: nil,
      headers: [
        PlaybackHTTPHeader(name: "X-Test", value: "a,b"),
        PlaybackHTTPHeader(name: "X-Quote", value: "\"q\""),
        PlaybackHTTPHeader(name: "X-Name", value: "文件"),
        PlaybackHTTPHeader(name: "Authorization", value: "Bearer x"),
      ],
      expiresAt: nil)
    XCTAssertEqual(options.headerFieldsValue,
                   "X-Test: a\\,b,X-Quote: \"q\",X-Name: 文件,Authorization: Bearer x")
  }

  func testOptionMapKeepsPlaybackAndHTTPOptionsTogether() {
    let plan = PlaybackLoadPlan(
      mediaID: nil, url: URL(string: "https://cdn.quark.cn/file")!,
      intent: .ordinaryOpen, startPosition: 12.5, suppressWatchLater: true,
      knownDuration: nil,
      http: PlaybackHTTPOptions(userAgent: "Agent/1", referrer: "https://pan.quark.cn/",
                                headers: [PlaybackHTTPHeader(name: "X-Test", value: "a,b")],
                                expiresAt: nil, title: "Episode 1"))
    let options = PlaybackEngineOptions.optionMap(for: plan)
    XCTAssertEqual(options?["resume-playback"], "no")
    XCTAssertEqual(options?["start"], "12.5")
    XCTAssertEqual(options?["user-agent"], "Agent/1")
    XCTAssertEqual(options?["referrer"], "https://pan.quark.cn/")
    XCTAssertEqual(options?["http-header-fields"], "X-Test: a\\,b")
    XCTAssertEqual(options?["force-media-title"], "Episode 1")
    XCTAssertTrue(PlaybackEngineOptions.requiresNodeLoad(plan))
    let command = PlaybackEngineOptions.loadfileNodeArguments(path: "u", plan: plan)
    XCTAssertEqual(command.count, 5)
    XCTAssertEqual(command.first as? String, "loadfile")
  }

  func testStringFormKeepsItsExistingShapeForPlansWithoutHTTPOptions() {
    let plan = PlaybackLoadPlan(
      mediaID: nil, url: URL(fileURLWithPath: "/tmp/a.mkv"),
      intent: .ordinaryOpen, startPosition: 3, suppressWatchLater: true,
      knownDuration: nil)
    XCTAssertEqual(PlaybackEngineOptions.loadfileOptions(for: plan),
                   "resume-playback=no,start=3.0")
    XCTAssertFalse(PlaybackEngineOptions.requiresNodeLoad(plan))
  }

  func testCommandLogRedactsSensitiveOptionValues() {
    let rendered = MPVCommandLog.arguments([
      "https://cdn.quark.cn/file?token=secret",
      "http-header-fields=Cookie: session=abc",
      "resume-playback=no",
    ])
    XCTAssertFalse(rendered.contains("secret"))
    XCTAssertFalse(rendered.contains("session=abc"))
    XCTAssertTrue(rendered.contains("[redacted]"))
    XCTAssertTrue(rendered.contains("resume-playback=no"))
  }

  func testMessagePolicyRequiresTheSameOriginAProviderAndVersionOne() {
    let page = URL(string: "https://pan.quark.cn/list")!
    let provider = CloudDrives.provider(id: "quark")!
    XCTAssertTrue(CloudDriveMessagePolicy.accepts(
      frameURL: page, currentURL: page, provider: provider, enabled: true, version: 1))
    XCTAssertFalse(CloudDriveMessagePolicy.accepts(
      frameURL: page, currentURL: page, provider: provider, enabled: false, version: 1))
    XCTAssertFalse(CloudDriveMessagePolicy.accepts(
      frameURL: page, currentURL: page, provider: nil, enabled: true, version: 1))
    XCTAssertFalse(CloudDriveMessagePolicy.accepts(
      frameURL: page, currentURL: page, provider: provider, enabled: true, version: 2))
    XCTAssertFalse(CloudDriveMessagePolicy.accepts(
      frameURL: URL(string: "https://evil.test/list")!, currentURL: page,
      provider: provider, enabled: true, version: 1))
    XCTAssertFalse(CloudDriveMessagePolicy.accepts(
      frameURL: URL(string: "http://pan.quark.cn/list")!, currentURL: page,
      provider: provider, enabled: true, version: 1))
    XCTAssertFalse(CloudDriveMessagePolicy.accepts(
      frameURL: URL(string: "https://pan.quark.cn:8443/list")!, currentURL: page,
      provider: provider, enabled: true, version: 1))
  }

  func testCookieMatchingAcceptsThePageOriginForAMediaHostElsewhere() {
    let media = URL(string: "https://cdn.quark.cn/file")!
    let page = URL(string: "https://pan.quark.cn/list")!
    func cookie(_ domain: String) -> HTTPCookie {
      HTTPCookie(properties: [
        .domain: domain, .path: "/", .name: "sid", .value: "1",
        .expires: Date().addingTimeInterval(600),
      ])!
    }
    let matched = CloudCookieScope.matching(
      [cookie(".quark.cn"), cookie(".other.test")], mediaURL: media, pageURL: page)
    XCTAssertEqual(matched.count, 1)
    XCTAssertEqual(matched.first?.name, "sid")
  }

  func testCookieScopeMatchesParentDomainAndRejectsOthers() {
    func cookie(_ domain: String, secure: Bool = false,
                expires: Date = Date().addingTimeInterval(60)) -> HTTPCookie {
      var properties: [HTTPCookiePropertyKey: Any] = [
        .domain: domain, .path: "/", .name: "sid", .value: "abc", .expires: expires,
      ]
      // Omitting the key is the only way to get a non-secure cookie; any value,
      // including "FALSE", marks it secure.
      if secure { properties[.secure] = true }
      return HTTPCookie(properties: properties)!
    }
    let url = URL(string: "https://drive-pc.quark.cn/1/clouddrive")!
    XCTAssertTrue(CloudCookieScope.matches(cookie(".quark.cn"), url: url))
    XCTAssertFalse(CloudCookieScope.matches(cookie(".alipan.com"), url: url))
    XCTAssertFalse(CloudCookieScope.matches(cookie(".quark.cn", secure: true),
                                            url: URL(string: "http://drive-pc.quark.cn/")!))
    XCTAssertFalse(CloudCookieScope.matches(cookie(".quark.cn", expires: Date().addingTimeInterval(-1)), url: url))
    XCTAssertEqual(CloudCookieScope.headerValue([cookie(".quark.cn")]), "sid=abc")
  }
}

final class CloudDriveAvailabilityTests: XCTestCase {
  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: CloudDrivePreferences.enabledKey)
    UserDefaults.standard.removeObject(forKey: CloudDrivePreferences.disabledHostsKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: CloudDrivePreferences.enabledKey)
    UserDefaults.standard.removeObject(forKey: CloudDrivePreferences.disabledHostsKey)
    super.tearDown()
  }

  func testAvailabilityRequiresTheSwitchAnAdapterAndAnAllowedHost() {
    let quark = CloudDrives.provider(id: "quark")!
    XCTAssertFalse(CloudDrives.isAvailable(quark, pageHost: "pan.quark.cn"),
                   "the feature is off by default")
    CloudDrivePreferences.setEnabled(true)
    XCTAssertTrue(CloudDrives.isAvailable(quark, pageHost: "pan.quark.cn"))
    XCTAssertFalse(CloudDrives.isAvailable(quark, pageHost: "example.test"))
    XCTAssertFalse(CloudDrives.isAvailable(quark, pageHost: nil))

    let aliyun = CloudDrives.provider(id: "aliyun")!
    XCTAssertTrue(CloudDrives.isAvailable(aliyun, pageHost: "www.alipan.com"),
                  "Aliyun now has an adapter")
    XCTAssertFalse(CloudDrives.isAvailable(aliyun, pageHost: "pan.quark.cn"))

    let baidu = CloudDrives.provider(id: "baidu")!
    XCTAssertFalse(CloudDrives.isAvailable(baidu, pageHost: "pan.baidu.com"),
                   "a provider without an adapter stays hidden")

    CloudDrivePreferences.setAllowed(false, host: "pan.quark.cn")
    XCTAssertFalse(CloudDrives.isAvailable(quark, pageHost: "pan.quark.cn"))
    CloudDrivePreferences.setAllowed(true, host: "pan.quark.cn")
    XCTAssertTrue(CloudDrives.isAvailable(quark, pageHost: "pan.quark.cn"))
  }
}

final class CloudDrivePlaybackStateTests: XCTestCase {
  func testExpiryNoteAppearsOnlyNearTheDeadline() {
    XCTAssertNil(CloudDriveExpiry.note(for: nil))
    XCTAssertNil(CloudDriveExpiry.note(for: Date().addingTimeInterval(600)))
    XCTAssertNotNil(CloudDriveExpiry.note(for: Date().addingTimeInterval(60)))
    XCTAssertNotNil(CloudDriveExpiry.note(for: Date().addingTimeInterval(-1)))
  }

  @MainActor
  func testResolvingFailureAndReset() {
    let coordinator = CloudDrivePlaybackCoordinator.shared
    coordinator.reset()
    XCTAssertEqual(coordinator.state, .idle)
    coordinator.begin()
    XCTAssertEqual(coordinator.state, .resolving)
    coordinator.fail("Select a file in the drive page first.")
    XCTAssertEqual(coordinator.state, .failed("Select a file in the drive page first."))
    coordinator.reset()
    XCTAssertEqual(coordinator.state, .idle)
  }
}

final class CloudDriveFixtureTests: XCTestCase {
  func testRangeRequestReturnsPartialContent() async throws {
    let server = try CloudDriveFixtureServer()
    defer { server.stop() }
    var request = URLRequest(url: server.baseURL.appendingPathComponent("media"))
    request.setValue("bytes=0-99", forHTTPHeaderField: "Range")
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertEqual(http.statusCode, 206)
    XCTAssertEqual(data.count, 100)
    XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"),
                   "bytes 0-99/\(CloudDriveFixtureServer.wav(duration: 3).count)")
  }

  func testExpiredSignedURLIsForbidden() async throws {
    let server = try CloudDriveFixtureServer()
    defer { server.stop() }
    let url = URL(string: "\(server.baseURL.absoluteString)/signed?expires=1")!
    let (_, response) = try await URLSession.shared.data(from: url)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
  }

  func testEchoReturnsReceivedHeaders() async throws {
    let server = try CloudDriveFixtureServer()
    defer { server.stop() }
    var request = URLRequest(url: server.baseURL.appendingPathComponent("echo"))
    request.httpMethod = "POST"
    request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
    request.httpBody = Data("{\"a\":1}".utf8)
    let (data, _) = try await URLSession.shared.data(for: request)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let headers = try XCTUnwrap(json["headers"] as? [String: String])
    XCTAssertEqual(headers["authorization"], "Bearer fixture")
    XCTAssertEqual(json["body"] as? String, "{\"a\":1}")
  }
}

final class CloudDriveBrokerTests: XCTestCase {
  private let provider = CloudDriveProvider(
    id: "fixture", displayName: "Fixture",
    pageHosts: [.exact("127.0.0.1")],
    apiHosts: [.exact("127.0.0.1")],
    mediaHosts: [.exact("127.0.0.1")],
    requestUserAgents: ["FixtureAgent/1"],
    mediaUserAgents: ["FixtureAgent/1"],
    adapter: "fixture")

  private func cookie(_ name: String, _ value: String, domain: String = "127.0.0.1") -> HTTPCookie {
    HTTPCookie(properties: [
      .domain: domain, .path: "/", .name: name, .value: value,
      .expires: Date().addingTimeInterval(600),
    ])!
  }

  func testBrokerSendsNativeCookiesAndProviderUserAgent() async throws {
    let server = try CloudDriveFixtureServer()
    defer { server.stop() }
    let store = FakeCloudCookieStore([cookie("sid", "abc")])
    let broker = CloudDriveRequestBroker(cookies: store)
    let body: [String: Any] = [
      "method": "GET",
      "url": "\(server.baseURL.absoluteString)/echo",
      "headers": ["Authorization": "Bearer fixture"],
    ]
    let request = try XCTUnwrap(CloudRequest(body: body, provider: provider))
    let response = try await broker.perform(
      request, provider: provider, defaultUserAgent: "Default/1")
    XCTAssertEqual(response.status, 200)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
    let headers = try XCTUnwrap(json["headers"] as? [String: String])
    XCTAssertEqual(headers["cookie"], "sid=abc")
    XCTAssertEqual(headers["user-agent"], "FixtureAgent/1")
    XCTAssertEqual(headers["authorization"], "Bearer fixture")
    XCTAssertNotNil(headers["accept"])
  }

  func testBrokerRefusesAForeignUserAgent() async throws {
    let server = try CloudDriveFixtureServer()
    defer { server.stop() }
    let broker = CloudDriveRequestBroker(cookies: FakeCloudCookieStore())
    let body: [String: Any] = [
      "method": "GET",
      "url": "\(server.baseURL.absoluteString)/echo",
      "headers": ["User-Agent": "Other/1"],
    ]
    let request = try XCTUnwrap(CloudRequest(body: body, provider: provider))
    do {
      _ = try await broker.perform(request, provider: provider, defaultUserAgent: nil)
      XCTFail("Foreign user agent admitted")
    } catch {
      XCTAssertEqual(error as? CloudDriveError,
                     .rejected("This drive's API does not accept that user agent."))
    }
  }

  func testRequestConstructionRejectsHostsHeadersAndCookieOverrides() {
    XCTAssertNil(CloudRequest(body: [
      "method": "GET", "url": "https://example.test/echo", "headers": [:]
    ], provider: provider))
    XCTAssertNil(CloudRequest(body: [
      "method": "GET", "url": "http://127.0.0.1:1/echo", "headers": ["X-Bad": "1"]
    ], provider: provider))
    XCTAssertNil(CloudRequest(body: [
      "method": "GET", "url": "http://127.0.0.1:1/echo", "headers": ["Cookie": "sid=abc"]
    ], provider: provider))
    XCTAssertNotNil(CloudRequest(body: [
      "method": "POST", "url": "http://127.0.0.1:1/echo", "headers": ["Content-Type": "application/json"]
    ], provider: provider))
  }

  func testRequestCapsRejectOversizedPayloads() {
    let longURL = "http://127.0.0.1/" + String(repeating: "a", count: 65_536)
    XCTAssertNil(CloudRequest(body: [
      "method": "GET", "url": longURL, "headers": [:]
    ], provider: provider))
    let oversized = String(repeating: "a", count: 2 * 1024 * 1024 + 1)
    XCTAssertNil(CloudRequest(body: [
      "method": "POST", "url": "http://127.0.0.1:1/echo", "headers": [:], "body": oversized
    ], provider: provider))
    XCTAssertNil(CloudDrives.validatedHeaderValue(String(repeating: "a", count: 8_193)))
  }

  func testWebKitCookieStoreRoundTripsAStoredCookie() async throws {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    let adapter = WebKitCloudCookieStore(
      store: configuration.websiteDataStore.httpCookieStore)
    let cookie = try XCTUnwrap(HTTPCookie(properties: [
      .domain: ".example.test", .path: "/", .name: "sid", .value: "abc",
      .expires: Date().addingTimeInterval(600),
    ]))
    await adapter.store([cookie])
    let cookies = await adapter.cookies(for: URL(string: "https://app.example.test/echo")!)
    XCTAssertTrue(cookies.contains { $0.name == "sid" && $0.value == "abc" })
    withExtendedLifetime(webView) {}
  }

  func testBrokerDoesNotFollowARedirectOutsideTheAllowlist() async throws {
    let server = try CloudDriveFixtureServer()
    defer { server.stop() }
    let broker = CloudDriveRequestBroker(cookies: FakeCloudCookieStore())
    let target = "http%3A%2F%2Fexample.test%2Fecho"
    let url = "\(server.baseURL.absoluteString)/redirect?to=\(target)"
    let request = try XCTUnwrap(CloudRequest(body: [
      "method": "GET", "url": url, "headers": [:],
    ], provider: provider))
    let response = try await broker.perform(
      request, provider: provider, defaultUserAgent: nil)
    XCTAssertEqual(response.status, 302, "the redirect must not be followed")
    XCTAssertTrue(server.requests(matching: "/echo").isEmpty)
  }
}
