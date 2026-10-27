//
//  CloudDrivePlayback.swift
//  uniplayer
//
//  Turns a resolved cloud-drive source into a normal playback plan. The first
//  selected file opens; further selections are appended to the same player so
//  a multi-file selection behaves like a playlist.
//

import AppKit
import Combine
import WebKit

enum CloudDriveExpiry {
  static let warningInterval: TimeInterval = 300

  /// The only honest warning phase 1 can give: the signed address is close to
  /// its advertised deadline, so a later seek may fail.
  static func note(for expiresAt: Date?, now: Date = Date()) -> String? {
    guard let expiresAt, expiresAt.timeIntervalSince(now) < warningInterval else { return nil }
    return "This download address expires soon. A seek after it expires may fail."
  }
}

@MainActor
final class CloudDrivePlaybackCoordinator: NSObject, ObservableObject {
  static let shared = CloudDrivePlaybackCoordinator()

  private weak var sourceWindow: NSWindow?
  private var returnItem: NSMenuItem?

  enum State: Equatable {
    case idle
    case resolving
    case failed(String)
  }

  @Published private(set) var state: State = .idle
  /// Set when a resolved address is close to its advertised expiry, which is
  /// the one condition that can stop a seek without a user error.
  @Published private(set) var expiryNote: String?

  private var timeout: Task<Void, Never>?
  private weak var player: PlayerCore?
  private var session = UUID()

  /// Called when the user asks for the current selection.
  func begin() {
    timeout?.cancel()
    session = UUID()
    player = nil
    expiryNote = nil
    state = .resolving
    timeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(45))
      guard !Task.isCancelled, let self, case .resolving = self.state else { return }
      self.state = .failed("The drive did not answer in time. Check the page and try again.")
    }
  }

  func fail(_ message: String) {
    timeout?.cancel()
    player = nil
    expiryNote = nil
    state = .failed(message)
  }

  func reset() {
    timeout?.cancel()
    timeout = nil
    player = nil
    expiryNote = nil
    state = .idle
  }

  func present(_ source: CloudMediaSource, web: WKWebView, isCurrent: @escaping () -> Bool) {
    let session = self.session
    installReturnCommand(for: web.window)
    Task { @MainActor in
      guard isCurrent() else { return }
      let store = WebKitCloudCookieStore(
        store: web.configuration.websiteDataStore.httpCookieStore)
      let cookies = CloudCookieScope.matching(
        await store.cookies(for: source.url), mediaURL: source.url, pageURL: web.url)
      guard isCurrent(), self.session == session else { return }

      var headers = source.headers
      if let cookieHeader = CloudCookieScope.headerValue(cookies),
         !headers.contains(where: { $0.name.caseInsensitiveCompare("Cookie") == .orderedSame }) {
        headers.append(PlaybackHTTPHeader(name: "Cookie", value: cookieHeader))
      }
      let http = PlaybackHTTPOptions(
        userAgent: source.userAgent, referrer: source.referrer,
        headers: headers, expiresAt: source.expiresAt, title: source.title)
      let plan = PlaybackLoadPlan(
        mediaID: nil, url: source.url, intent: .ordinaryOpen,
        startPosition: 0, suppressWatchLater: true, knownDuration: nil, http: http)

      self.expiryNote = CloudDriveExpiry.note(for: source.expiresAt)

      if let player = self.player, player.info.state != .idle {
        player.mpv.playlistAppend(source.url.absoluteString, plan: plan)
        return
      }
      // A standalone player keeps the channel page visible; the library's
      // inline surface would replace it.
      let player = PlayerCore.newPlayerCore
      self.player = player
      player.openURL(source.url, plan: plan)
      self.timeout?.cancel()
      self.timeout = nil
      self.state = .idle
    }
  }

  /// The channel stays on the source page, so returning is raising its window.
  /// The item is installed once and retargeted by each new session.
  private func installReturnCommand(for window: NSWindow?) {
    sourceWindow = window
    guard returnItem == nil, let menu = NSApp.windowsMenu else { return }
    let item = NSMenuItem(title: "Return to Drive Source",
                          action: #selector(returnToDriveSource), keyEquivalent: "")
    item.target = self
    menu.addItem(.separator())
    menu.addItem(item)
    returnItem = item
  }

  @objc private func returnToDriveSource() {
    sourceWindow?.makeKeyAndOrderFront(nil)
  }
}
