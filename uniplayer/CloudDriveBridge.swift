//
//  CloudDriveBridge.swift
//  uniplayer
//
//  The native half of a cloud-drive channel. An adapter injected into the
//  drive page reads the page's own selection, asks this broker for the API
//  calls it needs, and presents one resolved source. The page is untrusted:
//  every host, header, URL and payload crossing this boundary is validated
//  here, and cookies never travel back into JavaScript.
//

import Foundation
import WebKit

struct CloudMediaSource: Equatable, Sendable {
  let url: URL
  let title: String
  let headers: [PlaybackHTTPHeader]
  let userAgent: String?
  let referrer: String?
  let expiresAt: Date?
}

enum CloudDriveError: Error, Equatable {
  case rejected(String)
  case network
  case tooLarge

  var message: String {
    switch self {
    case .rejected(let reason): return reason
    case .network: return "The drive could not be reached."
    case .tooLarge: return "The drive returned more data than a resolution request may carry."
    }
  }
}

// MARK: - Cookies

protocol CloudCookieStore: AnyObject {
  func cookies(for url: URL) async -> [HTTPCookie]
  func store(_ cookies: [HTTPCookie]) async
}

final class WebKitCloudCookieStore: CloudCookieStore {
  private let store: WKHTTPCookieStore

  init(store: WKHTTPCookieStore) { self.store = store }

  func cookies(for url: URL) async -> [HTTPCookie] {
    await withCheckedContinuation { continuation in
      store.getAllCookies { continuation.resume(returning: $0) }
    }
  }

  func store(_ cookies: [HTTPCookie]) async {
    for cookie in cookies {
      await withCheckedContinuation { continuation in
        store.setCookie(cookie) { continuation.resume() }
      }
    }
  }
}

enum CloudCookieScope {
  static func matches(_ cookie: HTTPCookie, url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard !domain.isEmpty, host == domain || host.hasSuffix("." + domain) else { return false }
    if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
    if let expires = cookie.expiresDate, expires <= Date() { return false }
    let path = url.path.isEmpty ? "/" : url.path
    return path.hasPrefix(cookie.path.isEmpty ? "/" : cookie.path)
  }

  static func headerValue(_ cookies: [HTTPCookie]) -> String? {
    guard !cookies.isEmpty else { return nil }
    return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
  }

  /// A drive may keep its session on the page origin while the media is
  /// served from a sibling host. Accept a cookie for either origin, and for
  /// nothing else. This is the one policy both the API broker and the player
  /// handoff use.
  static func matching(_ cookies: [HTTPCookie], mediaURL: URL,
                       pageURL: URL?) -> [HTTPCookie] {
    cookies.filter { cookie in
      matches(cookie, url: mediaURL)
        || (pageURL.map { matches(cookie, url: $0) } ?? false)
    }
  }
}

// MARK: - Broker request and response

struct CloudRequest {
  let method: String
  let url: URL
  let headers: [String: String]
  let body: Data?

  init?(body: Any, provider: CloudDriveProvider) {
    guard let value = body as? [String: Any],
          let method = value["method"] as? String, ["GET", "POST"].contains(method),
          let rawURL = value["url"] as? String,
          let url = CloudDrives.validatedAPIURL(rawURL, provider: provider) else { return nil }

    var headers: [String: String] = [:]
    if let rawHeaders = value["headers"] as? [String: Any] {
      guard rawHeaders.count <= 32 else { return nil }
      for (name, rawValue) in rawHeaders {
        guard let headerValue = rawValue as? String else { return nil }
        let key = name.lowercased()
        guard key != "cookie", CloudDrives.requestHeaderAllowlist.contains(key),
              let validName = CloudDrives.validatedHeaderName(name),
              let validValue = CloudDrives.validatedHeaderValue(headerValue) else { return nil }
        headers[validName] = validValue
      }
    }

    var bodyData: Data?
    if let text = value["body"] as? String {
      guard text.utf8.count <= 2 * 1024 * 1024 else { return nil }
      bodyData = Data(text.utf8)
    }

    self.method = method
    self.url = url
    self.headers = headers
    self.body = bodyData
  }
}

struct CloudResponse {
  let status: Int
  let headers: [String: String]
  let body: String

  var dictionary: [String: Any] {
    ["status": status, "headers": headers, "body": body]
  }
}

final class CloudRedirectGuard: NSObject, URLSessionTaskDelegate {
  private let lock = NSLock()
  private var hosts: [CloudHostRule] = []

  func update(hosts: [CloudHostRule]) {
    lock.lock(); defer { lock.unlock() }
    self.hosts = hosts
  }

  private func allows(_ host: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return hosts.contains { $0.matches(host) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    guard let host = request.url?.host, allows(host) else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}

final class CloudDriveRequestBroker {
  private let cookies: CloudCookieStore
  private let redirectGuard = CloudRedirectGuard()
  private let session: URLSession

  init(cookies: CloudCookieStore) {
    self.cookies = cookies
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 40
    self.session = URLSession(configuration: configuration,
                              delegate: redirectGuard, delegateQueue: nil)
  }

  func perform(_ request: CloudRequest, provider: CloudDriveProvider,
               defaultUserAgent: String?, pageURL: URL? = nil) async throws -> CloudResponse {
    redirectGuard.update(hosts: provider.apiHosts)

    var headers = request.headers
    if let supplied = headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value {
      guard provider.requestUserAgents.contains(supplied) else {
        throw CloudDriveError.rejected("This drive's API does not accept that user agent.")
      }
    } else if let userAgent = provider.requestUserAgents.first {
      headers["User-Agent"] = userAgent
    } else if let defaultUserAgent, !defaultUserAgent.isEmpty {
      headers["User-Agent"] = defaultUserAgent
    }
    headers["Accept"] = "*/*,application/json;charset=utf-8"

    let matching = CloudCookieScope.matching(
      await cookies.cookies(for: request.url), mediaURL: request.url, pageURL: pageURL)
    if let cookieHeader = CloudCookieScope.headerValue(matching) {
      headers["Cookie"] = cookieHeader
    }

    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: urlRequest)
    } catch {
      throw CloudDriveError.network
    }
    guard data.count <= 2 * 1024 * 1024 else { throw CloudDriveError.tooLarge }

    if let http = response as? HTTPURLResponse {
      persistCookies(from: http, url: request.url)
      var returned: [String: String] = [:]
      if let type = http.value(forHTTPHeaderField: "Content-Type") { returned["Content-Type"] = type }
      return CloudResponse(status: http.statusCode, headers: returned,
                           body: String(decoding: data, as: UTF8.self))
    }
    return CloudResponse(status: 0, headers: [:], body: String(decoding: data, as: UTF8.self))
  }

  private func persistCookies(from response: HTTPURLResponse, url: URL) {
    let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
      result[String(describing: pair.key)] = String(describing: pair.value)
    }
    let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
    guard !cookies.isEmpty else { return }
    Task { await self.cookies.store(cookies) }
  }
}

// MARK: - Bridge

/// The message-intake rules, separated from WebKit so they can be tested
/// without a live page. The frame must be the page the bridge owns, in the
/// same origin, and the adapter must currently be enabled for a provider.
enum CloudDriveMessagePolicy {
  static func accepts(frameURL: URL, currentURL: URL,
                      provider: CloudDriveProvider?, enabled: Bool,
                      version: Int) -> Bool {
    guard enabled, provider != nil, version == 1 else { return false }
    return frameURL.scheme == currentURL.scheme
      && frameURL.host == currentURL.host
      && frameURL.port == currentURL.port
  }
}

@MainActor
final class CloudDriveBridge: NSObject, WKScriptMessageHandlerWithReply {
  static let handlerName = "cloudDrive"
  static let contentWorld = WKContentWorld.page

  private weak var webView: WKWebView?
  private var provider: CloudDriveProvider?
  private var enabled = false
  private var generation = 0
  private var urlObservation: NSKeyValueObservation?
  private var settingsObserver: NSObjectProtocol?
  private var broker: CloudDriveRequestBroker?
  private var defaultUserAgent: String?

  /// Called with one validated source, the owning web view, and a closure that
  /// reports whether the page that produced it is still current.
  var present: ((CloudMediaSource, WKWebView, @escaping () -> Bool) -> Void)?
  /// Called with a short adapter failure message.
  var failure: ((String) -> Void)?
  /// Called whenever the action's availability changes.
  var availabilityChanged: ((Bool) -> Void)?

  private(set) var isAvailable = false

  static var script: String {
    guard let url = Bundle.main.url(forResource: "CloudDriveActions", withExtension: "js"),
          let source = try? String(contentsOf: url, encoding: .utf8) else {
      Logger.log("CloudDriveActions.js is missing from the app bundle", level: .error)
      return ""
    }
    return source
  }

  func install(in configuration: WKWebViewConfiguration) {
    configuration.userContentController.addScriptMessageHandler(
      self, contentWorld: Self.contentWorld, name: Self.handlerName)
    let source = Self.script
    if !source.isEmpty {
      configuration.userContentController.addUserScript(WKUserScript(
        source: source, injectionTime: .atDocumentEnd,
        forMainFrameOnly: true, in: Self.contentWorld))
    }
    broker = CloudDriveRequestBroker(
      cookies: WebKitCloudCookieStore(store: configuration.websiteDataStore.httpCookieStore))
  }

  func attach(to web: WKWebView) {
    webView = web
    urlObservation = web.observe(\.url, options: [.new, .initial]) { [weak self] web, _ in
      Task { @MainActor in
        guard let self else { return }
        self.generation += 1
        self.readUserAgent(from: web)
        self.refresh()
      }
    }
    settingsObserver = NotificationCenter.default.addObserver(
      forName: CloudDrivePreferences.changed, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  /// Re-evaluates the provider for the current page and tells the adapter
  /// whether it may run.
  func refresh() {
    guard let web = webView else { return }
    let url = web.url
    let resolved = url.flatMap { CloudDrives.provider(forPageURL: $0) }
    let available = resolved.map {
      CloudDrives.isAvailable($0, pageHost: url?.host)
    } ?? false
    provider = resolved
    enabled = available
    if isAvailable != available {
      isAvailable = available
      availabilityChanged?(available)
    }
    guard let resolved else {
      web.evaluateJavaScript(
        "globalThis.uniPlayerCloudDrive?.configure(\"\", false, \"\")",
        completionHandler: nil)
      return
    }
    let adapter = Self.jsString(resolved.adapter)
    let userAgent = Self.jsString(resolved.requestUserAgents.sorted().first ?? "")
    web.evaluateJavaScript(
      "globalThis.uniPlayerCloudDrive?.configure(\(adapter), \(available ? "true" : "false"), \(userAgent))",
      completionHandler: nil)
  }

  private func readUserAgent(from web: WKWebView) {
    if let custom = web.customUserAgent, !custom.isEmpty {
      defaultUserAgent = custom
      return
    }
    web.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
      Task { @MainActor in
        if let text = value as? String, !text.isEmpty { self?.defaultUserAgent = text }
      }
    }
  }

  private func isCurrent(_ web: WKWebView, generation: Int) -> Bool {
    self.webView === web && self.generation == generation && enabled
  }

  func userContentController(_ userContentController: WKUserContentController,
                             didReceive message: WKScriptMessage,
                             replyHandler: @escaping (Any?, String?) -> Void) {
    guard let web = message.webView, web === webView, message.frameInfo.isMainFrame,
          let provider, let current = web.url,
          let frameURL = message.frameInfo.request.url,
          let body = message.body as? [String: Any], let version = body["version"] as? Int,
          CloudDriveMessagePolicy.accepts(
            frameURL: frameURL, currentURL: current, provider: provider,
            enabled: enabled, version: version),
          let action = body["action"] as? String else {
      replyHandler(nil, "Unavailable on this page")
      return
    }

    switch action {
    case "probe":
      replyHandler(["enabled": enabled, "provider": provider.id], nil)

    case "request":
      guard let request = CloudRequest(body: body["request"] ?? [:], provider: provider) else {
        replyHandler(nil, "Invalid request")
        return
      }
      let generation = self.generation
      Task { @MainActor in
        guard self.isCurrent(web, generation: generation) else {
          replyHandler(nil, "The page changed")
          return
        }
        do {
          let response = try await self.broker?.perform(
            request, provider: provider, defaultUserAgent: self.defaultUserAgent,
            pageURL: current)
          guard let response else {
            replyHandler(nil, "The bridge is not ready")
            return
          }
          replyHandler(response.dictionary, nil)
        } catch {
          replyHandler(nil, (error as? CloudDriveError)?.message ?? CloudDriveError.network.message)
        }
      }

    case "present":
      guard let source = source(from: body, provider: provider) else {
        replyHandler(nil, "Invalid source")
        return
      }
      let generation = self.generation
      present?(source, web, { [weak self] in
        self?.isCurrent(web, generation: generation) ?? false
      })
      replyHandler(["presented": true], nil)

    case "failure":
      let message = (body["message"] as? String) ?? "The drive did not return a download address."
      failure?(Self.clean(message))
      replyHandler(nil, nil)

    default:
      replyHandler(nil, "Unknown action")
    }
  }

  private func source(from body: [String: Any], provider: CloudDriveProvider) -> CloudMediaSource? {
    guard let raw = body["source"] as? [String: Any],
          let rawURL = raw["url"] as? String,
          let url = CloudDrives.validatedMediaURL(rawURL, provider: provider) else { return nil }

    let rawTitle = raw["title"] as? String ?? ""
    let title = Self.clean(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
    let displayTitle = title.isEmpty ? (url.lastPathComponent.isEmpty ? provider.displayName : url.lastPathComponent) : title

    var headers: [PlaybackHTTPHeader] = []
    if let list = raw["headers"] as? [[String: Any]] {
      guard list.count <= 16 else { return nil }
      for item in list {
        guard let name = item["name"] as? String, let value = item["value"] as? String,
              CloudDrives.mediaHeaderAllowlist.contains(name.lowercased()),
              let validName = CloudDrives.validatedHeaderName(name),
              let validValue = CloudDrives.validatedHeaderValue(value) else { return nil }
        headers.append(PlaybackHTTPHeader(name: validName, value: validValue))
      }
    }

    var userAgent: String?
    if let raw = raw["userAgent"] as? String {
      guard provider.mediaUserAgents.contains(raw) else { return nil }
      userAgent = raw
    }

    var referrer: String?
    if let raw = raw["referrer"] as? String {
      guard raw.utf8.count <= 2_048, let value = URL(string: raw),
            value.scheme?.lowercased() == "https", let host = value.host,
            provider.ownsPage(host: host),
            CloudDrives.validatedHeaderValue(raw) != nil else { return nil }
      referrer = raw
    }

    var expiresAt: Date?
    if let milliseconds = raw["expiresAt"] as? Double, milliseconds.isFinite,
       milliseconds > 0, milliseconds < 4_102_444_800_000 {
      expiresAt = Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    return CloudMediaSource(url: url, title: String(displayTitle.prefix(300)),
                            headers: headers, userAgent: userAgent,
                            referrer: referrer, expiresAt: expiresAt)
  }

  private static func clean(_ text: String) -> String {
    let scalars = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
    return String(String.UnicodeScalarView(scalars))
  }

  private static func jsString(_ value: String) -> String {
    let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
    return String(data: data, encoding: .utf8) ?? "\"\""
  }

  deinit {
    settingsObserver.map(NotificationCenter.default.removeObserver)
  }
}
