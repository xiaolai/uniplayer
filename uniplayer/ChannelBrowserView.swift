//
//  ChannelBrowserView.swift
//  uniplayer
//
//  The WebKit side of a channel: persistent cookies and AirPlay permission for
//  sites whose media player exposes it.
//

import AppKit
import Combine
import SwiftUI
import WebKit

private func channelL(_ key: String) -> String {
  NSLocalizedString(key, comment: "")
}

/// WebKit's legacy direct-media handoff is not a navigation failure.
enum ChannelNavigationFailure {
  static func isExpectedHandoff(_ error: NSError) -> Bool {
    if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return true }
    return (error.domain == "WebKitErrorDomain" || error.domain == WKError.errorDomain)
      && error.code == 204
  }
}

/// Operational limits, independent of visual animation timing.
enum EmbeddedPageLoadingPolicy {
  static let slowNoticeDelay: TimeInterval = 8
  static let connectionTimeout: TimeInterval = 30
}

struct ChannelConnectionIssue {
  let title: String
  let explanation: String
  let symbol: String

  init(error: Error) {
    let error = error as NSError
    switch (error.domain, error.code) {
    case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
      title = channelL("You’re offline")
      explanation = channelL("Check your internet connection, then try again.")
      symbol = "wifi.slash"
    case (NSURLErrorDomain, NSURLErrorTimedOut):
      title = channelL("The website took too long to respond")
      explanation = channelL("The connection timed out. You can try again or open the website in your browser.")
      symbol = "clock.arrow.circlepath"
    case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
         (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
         (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
         (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
         (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid):
      title = channelL("A secure connection couldn’t be established")
      explanation = channelL("The website could not establish a secure connection. Try again later or check it in your browser.")
      symbol = "lock.trianglebadge.exclamationmark"
    default:
      title = channelL("Couldn’t connect")
      explanation = channelL("The website may be unavailable, or the connection may be interrupted. Try again or open it in your browser.")
      symbol = "network.slash"
    }
  }
}

@MainActor
final class ChannelBrowserModel: NSObject, ObservableObject {
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var connectionIssue: ChannelConnectionIssue?
  @Published private(set) var hasDocument = false
  @Published private(set) var isSlow = false
  @Published private(set) var estimatedProgress = 0.0
  private var activeNavigation: WKNavigation?
  private var slowNoticeTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var lastRequestedURL: URL?

  @Published private(set) var canGoBack = false
  @Published private(set) var canGoForward = false
  @Published private(set) var pageURL: URL?
  private var observations: [NSKeyValueObservation] = []

  private(set) var channel: Channel?
  let webView: WKWebView
  let netflixRatings = NetflixRatingsBridge()
  let torrentActions = ChannelTorrentBridge()

  override init() {
    let configuration = WKWebViewConfiguration()
    // The default store is persistent and app-scoped, so logins survive
    // relaunches without sharing cookies with Safari.
    configuration.websiteDataStore = .default()
    configuration.allowsAirPlayForMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.preferences.isElementFullscreenEnabled = true
    configuration.applicationNameForUserAgent = "Version/27.0 Safari/605.1.15"

    netflixRatings.install(in: configuration)
    torrentActions.install(in:configuration)
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()

    netflixRatings.attach(to: webView)
    torrentActions.attach(to:webView,channelID:{ [weak self] in self?.channel?.id })
    torrentActions.present = { candidate, web, current in
      TorrentPlaybackCoordinator.shared.present(candidate,web:web,isCurrent:current)
    }
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    // Keep fixed/sticky webpage controls below our draggable titlebar while
    // the page's visual surface still extends behind it (public macOS 26 API).
    webView.obscuredContentInsets = NSEdgeInsets(
      top: Tokens.Library.titlebarHeight, left: Tokens.Space.n0,
      bottom: Tokens.Space.n0, right: Tokens.Space.n0)
    webView.setValue(false, forKey: "drawsBackground")
    observations = [
      webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in self?.canGoBack = view.canGoBack },
      webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in self?.canGoForward = view.canGoForward },
      webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in self?.estimatedProgress = view.estimatedProgress },
      webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in self?.pageURL = view.url },
    ]
  }

  func returnToSourcePage(_ url:URL) {
    guard webView.url != url else { return }
    if let item = webView.backForwardList.backList.last(where:{ $0.url == url || TorrentPlaybackStore.sanitizedPage($0.url) == url }) {
      webView.go(to:item)
    } else { webView.load(URLRequest(url:url)) }
  }
  func open(_ channel: Channel) {
    if self.channel?.id == channel.id, self.channel?.url == channel.url,
       isLoading || (hasDocument && errorMessage == nil) { return }
    finishLoading()
    activeNavigation = nil
    webView.stopLoading()
    self.channel = channel
    hasDocument = false
    navigate(to: channel.url)
  }

  func openIMDbTitle(_ url: URL) { navigate(to: url) }

  private func navigate(to url: URL) {
    lastRequestedURL = url
    beginLoading()
    var request = URLRequest(url: url)
    request.timeoutInterval = EmbeddedPageLoadingPolicy.connectionTimeout
    activeNavigation = webView.load(request)
  }

  private func beginLoading() {
    finishLoading()
    isLoading = true
    errorMessage = nil
    connectionIssue = nil
    slowNoticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(EmbeddedPageLoadingPolicy.slowNoticeDelay))
      guard !Task.isCancelled, let self, self.isLoading else { return }
      self.isSlow = true
    }
    timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(EmbeddedPageLoadingPolicy.connectionTimeout))
      guard !Task.isCancelled, let self, self.isLoading, !self.hasDocument else { return }
      self.activeNavigation = nil
      self.finishLoading()
      self.webView.stopLoading()
      self.record(URLError(.timedOut))
    }
  }

  private func finishLoading() {
    slowNoticeTask?.cancel()
    timeoutTask?.cancel()
    slowNoticeTask = nil
    timeoutTask = nil
    isLoading = false
    isSlow = false
  }

  private func isCurrent(_ navigation: WKNavigation?) -> Bool {
    guard let activeNavigation else { return false }
    return navigation === activeNavigation
  }

  func goBack() { activeNavigation = webView.goBack() }
  func goForward() { activeNavigation = webView.goForward() }
  func goHome() {
    guard let channel else { return }
    navigate(to: channel.url)
  }
  func openInBrowser() {
    guard let url = lastRequestedURL ?? channel?.url else { return }
    NSWorkspace.shared.open(url)
  }

  func stop() {
    finishLoading()
    activeNavigation = nil
    webView.evaluateJavaScript(
      "document.querySelectorAll('video,audio').forEach((element) => element.pause())",
      completionHandler: nil)
    webView.stopLoading()
  }

  func reload() {
    if errorMessage == nil, hasDocument, let navigation = webView.reload() {
      beginLoading()
      activeNavigation = navigation
      return
    }
    // A failed provisional load has no document for WKWebView.reload().
    // Issue a fresh request so the first-connection Retry always does work.
    guard let url = lastRequestedURL ?? channel?.url else { return }
    navigate(to: url)
  }

  /// Reads the page title, URL and the user's current selection. This runs
  /// only when the user asks for it; the page is never scraped in the
  /// background.
  func contextSnapshot() async -> ChannelPageContext? {
    guard let requestedURL = webView.url, let requestedChannel = channel?.id else { return nil }
    // One evaluation, so title, URL and selection describe the same document.
    let script = """
      (function () {
        return {
          title: document.title,
          href: location.href,
          selection: window.getSelection().toString()
        };
      })()
      """
    guard let raw = try? await webView.evaluateJavaScript(script) as? [String: Any] else {
      return nil
    }
    // Navigation during the evaluation makes the snapshot ambiguous.
    guard webView.url == requestedURL, channel?.id == requestedChannel else { return nil }
    let href = (raw["href"] as? String).flatMap(URL.init(string:))
    let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let selection = (raw["selection"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let url = href ?? requestedURL
    return ChannelPageContext(
      title: (title?.isEmpty == false ? title! : (url.host ?? channel?.name ?? "Channel")),
      url: url,
      selection: selection?.isEmpty == false ? selection : nil)
  }
}

extension ChannelBrowserModel: WKNavigationDelegate {
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    if navigationAction.navigationType == .linkActivated, torrentActions.handleLink(url,in:webView) { decisionHandler(.cancel); return }
    if navigationAction.targetFrame?.isMainFrame == true { lastRequestedURL = url }
    switch url.scheme?.lowercased() {
    case "http", "https", "about", "blob", "data":
      decisionHandler(.allow)
    default:
      NSWorkspace.shared.open(url)
      decisionHandler(.cancel)
    }
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    netflixRatings.navigationStarted()
    activeNavigation = navigation
    torrentActions.navigationStarted()
    beginLoading()
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    guard isCurrent(navigation) else { return }
    hasDocument = true
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard isCurrent(navigation) else { return }
    hasDocument = true
    torrentActions.refresh()
    finishLoading()
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    guard isCurrent(navigation) else { return }
    finishLoading()
    record(error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
               withError error: Error) {
    guard isCurrent(navigation) else { return }
    finishLoading()
    record(error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finishLoading()
    hasDocument = false
    connectionIssue = ChannelConnectionIssue(error: WKError(.webContentProcessTerminated))
    errorMessage = channelL("The web content process stopped. Reload the channel to continue.")
  }

  private func record(_ error: Error) {
    let nsError = error as NSError
    guard !ChannelNavigationFailure.isExpectedHandoff(nsError) else {
      if nsError.domain != NSURLErrorDomain && nsError.code == 204 { hasDocument = true }
      return
    }
    connectionIssue = ChannelConnectionIssue(error: error)
    errorMessage = error.localizedDescription
  }

}

extension ChannelBrowserModel: WKUIDelegate {
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction,
               windowFeatures: WKWindowFeatures) -> WKWebView? {
    // Login and "open in new tab" links stay in the channel instead of
    // creating an unmanaged browser window.
    if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
      if torrentActions.handleLink(url, in: webView) { return nil }
      webView.load(URLRequest(url: url))
    }
    return nil
  }

  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: NSLocalizedString("general.ok", comment: "OK"))
    present(alert, in: webView, frame: frame) { _ in completionHandler() }
  }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: NSLocalizedString("general.ok", comment: "OK"))
    alert.addButton(withTitle: NSLocalizedString("general.cancel", comment: "Cancel"))
    present(alert, in: webView, frame: frame) { completionHandler($0 == .alertFirstButtonReturn) }
  }

  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
               defaultText: String?, initiatedByFrame frame: WKFrameInfo,
               completionHandler: @escaping (String?) -> Void) {
    let alert = NSAlert()
    alert.messageText = prompt
    alert.addButton(withTitle: NSLocalizedString("general.ok", comment: "OK"))
    alert.addButton(withTitle: NSLocalizedString("general.cancel", comment: "Cancel"))
    let input = NSTextField(string: defaultText ?? "")
    input.frame = NSRect(x: 0, y: 0, width: Tokens.Size.n260, height: Tokens.Size.n24)
    alert.accessoryView = input
    alert.window.initialFirstResponder = input
    present(alert, in: webView, frame: frame) {
      completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil)
    }
  }
  private func present(_ alert: NSAlert, in webView: WKWebView, frame: WKFrameInfo,
                       completion: @escaping (NSApplication.ModalResponse) -> Void) {
    alert.informativeText = String(format: channelL("Message from %@"), frame.securityOrigin.host)
    guard let window = webView.window else { completion(.cancel); return }
    alert.beginSheetModal(for: window, completionHandler: completion)
  }

}

/// Hosts the web view with an explicit frame and autoresizing.
///
/// WebKit's element fullscreen path breaks when the web view is pinned with
/// Auto Layout constraints; the fullscreen surface then gets an invalid
/// bounds and renders as a black window with a small video strip.
private final class ChannelWebViewContainer: NSView {
  let webView: WKWebView

  init(webView: WKWebView) {
    self.webView = webView
    super.init(frame: .zero)
    webView.translatesAutoresizingMaskIntoConstraints = true
    webView.autoresizingMask = [.width, .height]
    webView.frame = bounds
    addSubview(webView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    webView.frame = bounds
  }
}

private struct ChannelWebView: NSViewRepresentable {
  let webView: WKWebView

  func makeNSView(context: Context) -> ChannelWebViewContainer {
    ChannelWebViewContainer(webView: webView)
  }

  func updateNSView(_ nsView: ChannelWebViewContainer, context: Context) {}
}

struct ChannelDetailView: View {
  @Environment(\.libraryTextScale) private var textScale
  @ObservedObject var chrome: LibraryChrome
  @State private var navigationPinned = false
  @ObservedObject var browser: ChannelBrowserModel
  let channel: Channel
  let onUseContext: (ChannelPageContext) -> Void

  @State private var capturing = false
  @State private var contextStatus: String?

  var body: some View {
    ChannelWebView(webView: browser.webView)
      .overlay(alignment: .topTrailing) {
        Tokens.Palette.clear.color
          .frame(width: Tokens.Size.n30, height: Tokens.Size.n30)
          .popover(isPresented: $chrome.channelNavigationPresented, arrowEdge: .top) { navigationPanel }
          .padding(.top, Tokens.Library.titlebarHeight)
          .padding(.trailing, Tokens.Space.n16)
      }
      .overlay(alignment: .top) {
        if navigationPinned {
          navigationPanel
            .glassEffect(.regular, in: .rect(cornerRadius: Tokens.Radius.n12))
            .padding(.top, Tokens.Library.titlebarHeight)
        }
      }
      .overlay {
        if !browser.hasDocument {
          connectionState
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.Palette.canvas.color)
        }
      }
      .overlay(alignment: .top) {
        if browser.hasDocument && browser.isLoading {
          ProgressView(value: browser.estimatedProgress)
            .progressViewStyle(.linear)
            .accessibilityLabel(channelL("Loading channel…"))
            .padding(.top, Tokens.Library.titlebarHeight)
        }
      }
      .overlay(alignment: .bottom) {
        if browser.hasDocument, browser.errorMessage != nil {
          HStack(spacing: Tokens.Space.n12) {
            Label(channelL("The page couldn’t finish loading"), systemImage: "exclamationmark.circle")
            Spacer()
            Button(channelL("Try Again"), action: browser.reload)
            Button(channelL("Open in Browser"), action: browser.openInBrowser)
          }
          .font(Tokens.Typography.caption.font)
          .padding(Tokens.Space.n16)
          .background(Tokens.Palette.controlBackground.color)
        }
      }
      .overlay(alignment: .bottom) {
        if let contextStatus {
          HStack {
            Text(contextStatus).font(Tokens.Typography.caption.font)
            Button(channelL("Dismiss")) { self.contextStatus = nil }
          }
          .padding(Tokens.Space.n12)
          .glassEffect(.regular, in: .capsule)
          .padding(Tokens.Space.n16)
        }
      }
      .background(Tokens.Palette.canvas.color)
      .onAppear { chrome.channelSelected = true; browser.open(channel) }
      .onChange(of: channel.id) { _, _ in contextStatus = nil; browser.open(channel) }
      .onChange(of: channel.url) { _, _ in contextStatus = nil; browser.open(channel) }
      .onDisappear { chrome.channelSelected = false; chrome.channelNavigationPresented = false; browser.stop() }
  }

  private var navigationPanel: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.n12) {
      HStack(spacing: Tokens.Space.n8) {
        navigationButton("chevron.left", title: "Back", action: browser.goBack).disabled(!browser.canGoBack)
        navigationButton("chevron.right", title: "Forward", action: browser.goForward).disabled(!browser.canGoForward)
        navigationButton("arrow.clockwise", title: "Reload", action: browser.reload)
        navigationButton("house", title: "Channel Home", action: browser.goHome)
        navigationButton("safari", title: "Open in Browser", action: browser.openInBrowser)
        Spacer()
        Button { navigationPinned.toggle(); chrome.channelNavigationPresented = false } label: {
          Image(systemName: navigationPinned ? "pin.slash" : "pin")
        }
        .help(channelL(navigationPinned ? "Unpin Navigation" : "Pin Navigation"))
        .accessibilityLabel(channelL(navigationPinned ? "Unpin Navigation" : "Pin Navigation"))
      }
      Text(browser.pageURL?.host ?? channel.name)
        .font(Tokens.Typography.body.font)
        .lineLimit(1).truncationMode(.middle)
        Button {
          capturing = true
          contextStatus = nil
          Task {
            if let context = await browser.contextSnapshot() {
              onUseContext(context)
              contextStatus = channelL("Context attached. Review it in AI Assistant before sending.")
            } else {
              contextStatus = channelL("Could not read this page. Reload it and try again.")
            }
            capturing = false
          }
        } label: {
          Label(channelL("Attach Context"), systemImage: "sparkles")
        }
        .disabled(capturing || browser.isLoading)
        .help(channelL("Attach the page title and selected text to AI Assistant"))
    }
    .padding(Tokens.Space.n12)
    .frame(width: Tokens.Inspector.idealWidth)
  }

  private func navigationButton(_ symbol: String, title: String,
                                action: @escaping () -> Void) -> some View {
    Button {
      action()
      if !navigationPinned { chrome.channelNavigationPresented = false }
    } label: {
      Image(systemName: symbol).frame(width: Tokens.Size.n30, height: Tokens.Size.n30)
    }
    .buttonStyle(.borderless)
    .help(channelL(title))
    .accessibilityLabel(channelL(title))
  }

  private var connectionState: some View {
    GeometryReader { geometry in
      ScrollView {
        connectionStateContent
          .frame(maxWidth: .infinity, minHeight: geometry.size.height)
      }
    }
  }

  private var connectionStateContent: some View {
    VStack(spacing: Tokens.Space.n20) {
      Image(systemName: browser.connectionIssue?.symbol ?? channel.symbol)
        .font(Tokens.Typography.channelStateIcon.scaledFont(textScale))
        .foregroundStyle(Tokens.Palette.textSecondary.color)
        .accessibilityHidden(true)
      VStack(spacing: Tokens.Space.n8) {
        Text(browser.connectionIssue?.title ?? channel.name)
          .font(Tokens.Typography.pageTitle.scaledFont(textScale))
        Text(browser.connectionIssue == nil ? (channel.url.host ?? channel.name) :
          "\(channel.name) · \(channel.url.host ?? channel.name)")
          .font(Tokens.Typography.body.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textSecondary.color)
          .textSelection(.enabled)
      }
      if let issue = browser.connectionIssue {
        Text(issue.explanation)
          .font(Tokens.Typography.body.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textSecondary.color)
        recoveryActions
        if let message = browser.errorMessage {
          DisclosureGroup(channelL("Technical Details")) {
            Text(message)
              .font(Tokens.Typography.caption.scaledFont(textScale))
              .foregroundStyle(Tokens.Palette.textSecondary.color)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, Tokens.Space.n8)
          }
          .font(Tokens.Typography.caption.scaledFont(textScale))
        }
      } else if browser.isLoading {
        HStack(spacing: Tokens.Space.n12) {
          ProgressView().controlSize(.small)
          Text(channelL(browser.isSlow ? "This is taking longer than expected…" : "Connecting to the website…"))
            .font(Tokens.Typography.body.scaledFont(textScale))
            .foregroundStyle(Tokens.Palette.textSecondary.color)
        }
        if browser.isSlow { recoveryActions }
      } else {
        Text(channelL("The connection was stopped."))
          .font(Tokens.Typography.body.scaledFont(textScale))
          .foregroundStyle(Tokens.Palette.textSecondary.color)
        recoveryActions
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: Tokens.Library.channelStateMaximumWidth * textScale)
    .padding(Tokens.Space.n32)
    .padding(.top, Tokens.Library.titlebarHeight)
  }

  private var recoveryActions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Tokens.Space.n12) { recoveryButtons }.fixedSize()
      VStack(spacing: Tokens.Space.n8) { recoveryButtons }
    }
    .font(Tokens.Typography.body.scaledFont(textScale))
  }

  @ViewBuilder
  private var recoveryButtons: some View {
    Button(channelL("Try Again"), action: browser.reload).buttonStyle(.borderedProminent)
    Button(channelL("Open in Browser"), action: browser.openInBrowser).buttonStyle(.bordered)
  }

}

struct ChannelEditorSheet: View {
  enum Mode: Identifiable {
    case add
    case edit(Channel)

    var id: String {
      switch self {
      case .add: "add"
      case .edit(let channel): channel.id
      }
    }
  }

  @ObservedObject var store: ChannelStore
  let mode: Mode
  let onSaved: (Channel) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var urlString: String
  @State private var errorMessage: String?
  private enum Field { case name, url }
  @FocusState private var focusedField: Field?

  init(store: ChannelStore, mode: Mode, onSaved: @escaping (Channel) -> Void) {
    self.store = store
    self.mode = mode
    self.onSaved = onSaved
    switch mode {
    case .add:
      _name = State(initialValue: "")
      _urlString = State(initialValue: "")
    case .edit(let channel):
      _name = State(initialValue: channel.name)
      _urlString = State(initialValue: channel.url.absoluteString)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.n16) {
      Text(title)
        .font(Tokens.Typography.sectionTitle.font)

      VStack(alignment: .leading, spacing: Tokens.Space.n4) {
        Text(channelL("Channel Name"))
          .font(Tokens.Typography.caption.font)
          .foregroundStyle(Tokens.Palette.textSecondary.color)
        TextField(channelL("Channel Name"), text: $name)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(channelL("Channel Name"))
          .focused($focusedField, equals: .name)
      }

      VStack(alignment: .leading, spacing: Tokens.Space.n4) {
        Text(channelL("URL"))
          .font(Tokens.Typography.caption.font)
          .foregroundStyle(Tokens.Palette.textSecondary.color)
        TextField("https://example.com", text: $urlString)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(channelL("Channel URL"))
          .focused($focusedField, equals: .url)
          .onChange(of: urlString) { _, _ in
            if Channel.validatedURL(urlString) != nil { errorMessage = nil }
          }
      }

      if let errorMessage {
        Text(errorMessage)
          .font(Tokens.Typography.caption.font)
          .foregroundStyle(Tokens.Palette.destructive.color)
      }

      HStack {
        Spacer()
        Button(NSLocalizedString("general.cancel", comment: "Cancel")) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button(NSLocalizedString("general.save", comment: "Save")) {
          save()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(Tokens.Space.n20)
    .frame(width: Tokens.Size.n420)
    .onAppear { focusedField = .name }
  }

  private var title: String {
    switch mode {
    case .add: channelL("Add Channel")
    case .edit: channelL("Edit Channel")
    }
  }

  private func save() {
    guard let url = Channel.validatedURL(urlString) else {
      errorMessage = channelL("Enter a valid HTTP or HTTPS URL.")
      focusedField = .url
      return
    }

    switch mode {
    case .add:
      guard let channel = store.add(name: name, urlString: url.absoluteString) else {
        errorMessage = channelL("Enter a valid HTTP or HTTPS URL.")
        return
      }
      onSaved(channel)
    case .edit(let oldChannel):
      var updated = oldChannel
      updated.name = name
      updated.url = url
      guard store.update(updated) else {
        errorMessage = channelL("This channel no longer exists.")
        return
      }
      onSaved(updated)
    }
    dismiss()
  }
}
