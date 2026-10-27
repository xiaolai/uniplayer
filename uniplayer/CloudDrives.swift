//
//  CloudDrives.swift
//  uniplayer
//
//  The trust boundary for cloud-drive channels. The drive's own web page is
//  the browser; this file describes which page hosts may run an adapter, which
//  API and media hosts the adapter may reach, and which headers may cross the
//  boundary. Nothing here performs a request.
//

import Foundation

enum CloudHostRule: Equatable, Sendable {
  case exact(String)
  case suffix(String)

  func matches(_ host: String) -> Bool {
    let candidate = host.lowercased()
    switch self {
    case .exact(let value):
      return candidate == value.lowercased()
    case .suffix(let value):
      let suffix = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      return !suffix.isEmpty && (candidate == suffix || candidate.hasSuffix("." + suffix))
    }
  }
}

struct CloudDriveProvider: Equatable, Sendable {
  let id: String
  let displayName: String
  let pageHosts: [CloudHostRule]
  let apiHosts: [CloudHostRule]
  let mediaHosts: [CloudHostRule]
  /// User agents an API request may use. Empty means the broker uses the
  /// channel's own user agent and refuses any override from the page.
  let requestUserAgents: Set<String>
  /// User agents the resolved media URL may need. Empty means mpv keeps its
  /// configured user agent.
  let mediaUserAgents: Set<String>
  /// The adapter implemented in CloudDriveActions.js. Empty until the provider
  /// has passed its real-account gate; an empty value hides the action.
  let adapter: String

  var isResolutionReady: Bool { !adapter.isEmpty }

  func ownsPage(host: String) -> Bool { pageHosts.contains { $0.matches(host) } }
  func allowsAPI(host: String) -> Bool { apiHosts.contains { $0.matches(host) } }
  func allowsMedia(host: String) -> Bool { mediaHosts.contains { $0.matches(host) } }
}

enum CloudDrives {
  /// Headers an adapter may ask the native broker to send. Cookies and the
  /// user agent are handled natively and are not accepted from the page.
  static let requestHeaderAllowlist: Set<String> = [
    "user-agent", "referer", "origin", "content-type", "authorization",
    "x-canary", "x-captcha-token", "x-device-id", "os", "version", "sec-ch-ua",
  ]

  /// Headers that may accompany a resolved media URL into mpv. The referrer
  /// and user agent travel as their own fields, and cookies are added from the
  /// WebKit store by the playback coordinator.
  static let mediaHeaderAllowlist: Set<String> = [
    "authorization", "x-canary", "x-captcha-token", "x-device-id", "os",
    "version", "sec-ch-ua", "origin",
  ]

  static let quarkUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 QuarkPC/6.9.7.761 QuarkCloudDrivePC/6.9.7.761 quark-cloud-drive/2.5.40"
  static let ucUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.8.8 Chrome/100.0.4896.160 Electron/18.3.5.16-b62cf9c50d Safari/537.36 Channel/ucpan_other_ch"
  static let pan123UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) 123pan/3.2.3 Chrome/108.0.5359.215 Electron/22.3.27 Safari/537.36 WebView/1.0"
  static let baiduMediaUserAgent = "pan.baidu.com"

  /// Provider metadata is derived from LinkSwift at commit 8283da0
  /// (AGPL-3.0-or-later). Only Quark ships an adapter in this change; the rest
  /// stay unready until their real-account gates run.
  static let providers: [CloudDriveProvider] = [
    CloudDriveProvider(
      id: "quark",
      displayName: "Quark Drive",
      pageHosts: [.exact("pan.quark.cn")],
      apiHosts: [.exact("drive-pc.quark.cn"), .exact("drive-social-api.quark.cn")],
      mediaHosts: [.suffix("quark.cn")],
      requestUserAgents: [quarkUserAgent],
      mediaUserAgents: [quarkUserAgent],
      adapter: "quark"),
    CloudDriveProvider(
      id: "aliyun",
      displayName: "Aliyun Drive",
      pageHosts: [.exact("www.alipan.com"), .exact("alipan.com"),
                  .exact("www.aliyundrive.com"), .exact("aliyundrive.com")],
      apiHosts: [.exact("api.alipan.com"), .exact("api.aliyundrive.com")],
      mediaHosts: [.suffix("alipan.com"), .suffix("aliyundrive.com"),
                   .suffix("aliyundrive.net"), .suffix("alicloudccp.com"),
                   .suffix("aliyundrive.cloud"), .suffix("aliyunpds.com")],
      requestUserAgents: [],
      mediaUserAgents: [],
      adapter: "aliyun"),
    CloudDriveProvider(
      id: "baidu",
      displayName: "Baidu Netdisk",
      pageHosts: [.exact("pan.baidu.com"), .exact("yun.baidu.com"), .exact("openapi.baidu.com")],
      apiHosts: [.exact("pan.baidu.com"), .exact("openapi.baidu.com")],
      mediaHosts: [.suffix("baidupcs.com"), .suffix("baidu.com")],
      requestUserAgents: [],
      mediaUserAgents: [baiduMediaUserAgent],
      adapter: ""),
    CloudDriveProvider(
      id: "uc",
      displayName: "UC Drive",
      pageHosts: [.exact("drive.uc.cn")],
      apiHosts: [.exact("pc-api.uc.cn")],
      mediaHosts: [.suffix("uc.cn")],
      requestUserAgents: [ucUserAgent],
      mediaUserAgents: [ucUserAgent],
      adapter: ""),
    CloudDriveProvider(
      id: "123",
      displayName: "123 Cloud Drive",
      pageHosts: [.suffix("123pan.com"), .suffix("123pan.cn"), .suffix("123684.com"),
                  .suffix("123865.com"), .suffix("123952.com"), .suffix("123912.com")],
      apiHosts: [.exact("api.123pan.cn")],
      mediaHosts: [.suffix("123pan.com"), .suffix("123pan.cn"), .suffix("123684.com"),
                   .suffix("123865.com"), .suffix("123952.com"), .suffix("123912.com"),
                   .suffix("cjjd19.com")],
      requestUserAgents: [pan123UserAgent],
      mediaUserAgents: [pan123UserAgent],
      adapter: ""),
    CloudDriveProvider(
      id: "xunlei",
      displayName: "Xunlei Drive",
      pageHosts: [.exact("pan.xunlei.com")],
      apiHosts: [.exact("api-pan.xunlei.com"), .exact("xluser-ssl.xunlei.com")],
      mediaHosts: [.suffix("xunlei.com")],
      requestUserAgents: [],
      mediaUserAgents: [],
      adapter: ""),
  ]

  static func provider(id: String) -> CloudDriveProvider? {
    providers.first { $0.id == id }
  }

  static func provider(forPageURL url: URL) -> CloudDriveProvider? {
    guard let host = url.host else { return nil }
    return providers.first { $0.ownsPage(host: host) }
  }

  static func isAvailable(_ provider: CloudDriveProvider, pageHost: String?) -> Bool {
    guard provider.isResolutionReady, CloudDrivePreferences.enabled else { return false }
    guard let pageHost, provider.ownsPage(host: pageHost) else { return false }
    return CloudDrivePreferences.allowed(host: pageHost)
  }

  /// Accepts only an HTTPS URL on a host the provider declared, with no
  /// credentials embedded in the authority.
  static func validatedMediaURL(_ raw: String, provider: CloudDriveProvider) -> URL? {
    guard raw.utf8.count <= 65_536, let url = URL(string: raw),
          url.scheme?.lowercased() == "https",
          url.user == nil, url.password == nil,
          let host = url.host, provider.allowsMedia(host: host) else { return nil }
    return url
  }

  static func validatedAPIURL(_ raw: String, provider: CloudDriveProvider) -> URL? {
    guard raw.utf8.count <= 65_536, let url = URL(string: raw),
          url.user == nil, url.password == nil,
          let host = url.host, provider.allowsAPI(host: host) else { return nil }
    let scheme = url.scheme?.lowercased()
    // Production providers are HTTPS-only. A loopback HTTP URL is permitted
    // solely so the fixture server can exercise this broker in tests, and the
    // provider's host allowlist still has to name it.
    let loopback = ["127.0.0.1", "::1", "localhost"].contains(host.lowercased())
    guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
    return url
  }

  /// RFC 7230 token characters, a conservative length, and no control
  /// characters. A backslash is refused because mpv's string-list parser uses
  /// it to escape its separator.
  static func validatedHeaderName(_ raw: String) -> String? {
    guard !raw.isEmpty, raw.utf8.count <= 64 else { return nil }
    let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return raw
  }

  static func validatedHeaderValue(_ raw: String) -> String? {
    guard raw.utf8.count <= 8_192 else { return nil }
    guard !raw.contains("\\") else { return nil }
    guard raw.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
    return raw
  }
}
