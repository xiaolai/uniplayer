//
//  OpenURLWindowController.swift
//  uniplayer
//
//  Created by Collider LI on 25/8/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa
import SwiftUI

class OpenURLWindowController: NSWindowController, NSTextFieldDelegate, NSControlTextEditingDelegate, NSWindowDelegate {

  override var windowNibName: NSNib.Name {
    return NSNib.Name("OpenURLWindowController")
  }

  @IBOutlet weak var urlStackView: NSStackView!
  @IBOutlet weak var httpPrefixTextField: NSTextField!
  @IBOutlet weak var urlField: NSTextField!
  @IBOutlet weak var usernameField: NSTextField!
  @IBOutlet weak var passwordField: NSSecureTextField!
  @IBOutlet weak var rememberPasswordCheckBox: NSButton!
  @IBOutlet weak var errorMessageLabel: NSTextField!
  @IBOutlet weak var openButton: NSButton!

  @IBOutlet weak var overlayView: NSVisualEffectView!
  @IBOutlet weak var loadingMediaProgressIndicator: NSProgressIndicator!
  @IBOutlet weak var loadingMediaLabel: NSTextField!

  private let loadingModel = LoadingMediaModel()
  private var torrentStatsTask: Task<Void, Never>?

  var isAlternativeAction = false

  var playerCore: PlayerCore?
  var loadingURL: String?

  private var invalidURLMessage: String {
    NSLocalizedString("alert.invalid_url", comment: "The URL is invalid.")
  }

  private var failedToOpenURLMessage: String {
    NSLocalizedString("alert.error_open", comment: "Cannot open file or stream!")
  }

  override func windowDidLoad() {
    super.windowDidLoad()
    window?.isMovableByWindowBackground = true
    window?.titlebarAppearsTransparent = true
    window?.titleVisibility = .hidden
    urlStackView.setVisibilityPriority(.notVisible, for: httpPrefixTextField)
    httpPrefixTextField.font = Tokens.Typography.urlField.nsFont
    urlField.font = Tokens.Typography.urlField.nsFont
    urlField.delegate = self
    ([.closeButton, .miniaturizeButton, .zoomButton] as [NSWindow.ButtonType]).forEach {
      window?.standardWindowButton($0)?.isHidden = true
    }

    // The legacy AppKit loading contents stay in the nib for the window's
    // geometry; the loading surface itself is the SwiftUI view hosted over it.
    loadingMediaProgressIndicator.isHidden = true
    loadingMediaLabel.isHidden = true
    overlayView.subviews.compactMap { $0 as? NSButton }.forEach { $0.isHidden = true }
    let loadingView = NSHostingView(rootView: LoadingMediaView(model: loadingModel, onStop: { [weak self] in
      self?.stopLoading()
    }))
    loadingView.translatesAutoresizingMaskIntoConstraints = false
    overlayView.addSubview(loadingView)
    NSLayoutConstraint.activate([
      loadingView.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor),
      loadingView.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor),
      loadingView.topAnchor.constraint(equalTo: overlayView.topAnchor),
      loadingView.bottomAnchor.constraint(equalTo: overlayView.bottomAnchor),
    ])
  }

  func showLoadingScreen(playerCore: PlayerCore) {
    _ = window
    overlayView.isHidden = false
    // Must not leave the focus in the username or password text fields.
    window?.makeFirstResponder(nil)
    self.playerCore = playerCore
    loadingURL = playerCore.info.currentURL?.absoluteString
    stopTorrentStats()
    loadingModel.isTorrent = playerCore.torrentContext != nil
    if let context = playerCore.torrentContext {
      let parts = context.record.file.name.split(separator: "/").map(String.init)
      let torrent = parts.first ?? context.record.title
      let file = parts.count > 1 ? parts.last : nil
      let size = ByteCountFormatter.string(fromByteCount: context.record.file.length, countStyle: .file)
      loadingModel.title = torrent
      loadingModel.subtitle = file.map { "Torrent · \($0) · \(size)" } ?? "Torrent · \(size)"
      loadingModel.stats = []
      loadingModel.progress = nil
      loadingModel.health = NSLocalizedString("Reading torrent status…", comment: "Torrent loading status")
      loadingModel.healthTone = .waiting
      startTorrentStats(context)
    } else {
      loadingModel.title = NSLocalizedString("Loading Media……", comment: "Loading media")
      loadingModel.subtitle = playerCore.info.currentURL?.host ?? ""
      loadingModel.stats = []
      loadingModel.progress = nil
      loadingModel.health = nil
      loadingModel.healthTone = .none
    }
    NSApp.activate()
    showWindow(self)
  }

  private func startTorrentStats(_ context: TorrentPlayerContext) {
    let hash = context.record.identity.hash
    let file = context.record.file
    torrentStatsTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, !self.overlayView.isHidden else { return }
        if let snapshot = try? await TransmissionRuntime.shared.find(hash, fresh: true) {
          self.updateTorrentStats(snapshot, file: file)
        }
        try? await Task.sleep(for: .milliseconds(700))
      }
    }
  }

  private func stopTorrentStats() {
    torrentStatsTask?.cancel()
    torrentStatsTask = nil
  }

  private func updateTorrentStats(_ snapshot: TorrentSnapshot, file: TorrentFile) {
    guard snapshot.pieceSize > 0, file.length > 0, snapshot.pieceCount > 0 else { return }
    let first = Int(file.offset / snapshot.pieceSize)
    let last = Int((file.offset + file.length - 1) / snapshot.pieceSize)
    guard first >= 0, first <= last, last < snapshot.pieceCount else { return }
    var have = 0, available = 0
    for piece in first...last {
      if snapshot.hasPiece(piece) { have += 1 }
      if snapshot.hasPiece(piece) || (piece < snapshot.availability.count && snapshot.availability[piece] > 0) {
        available += 1
      }
    }
    let count = last - first + 1
    let progress = have * 100 / count
    let availability = available * 100 / count
    let speed = snapshot.downloadRate > 0
      ? ByteCountFormatter.string(fromByteCount: snapshot.downloadRate, countStyle: .file) + "/s"
      : "0 B/s"
    let health: String
    let tone: LoadingMediaModel.HealthTone
    if snapshot.peers == 0 {
      health = NSLocalizedString("No peers — may stall", comment: "Torrent loading status")
      tone = .stalled
    } else if available == 0 {
      health = NSLocalizedString("No pieces — may stall", comment: "Torrent loading status")
      tone = .stalled
    } else if availability < 95 {
      health = NSLocalizedString("Limited availability", comment: "Torrent loading status")
      tone = .limited
    } else if snapshot.downloadRate == 0 {
      health = NSLocalizedString("Waiting for data", comment: "Torrent loading status")
      tone = .waiting
    } else {
      health = NSLocalizedString("Good availability", comment: "Torrent loading status")
      tone = .good
    }
    loadingModel.progress = Double(have) / Double(count)
    loadingModel.stats = [
      .init(label: "Seeds", value: "\(snapshot.completePeers)"),
      .init(label: "Peers", value: "\(snapshot.peers)"),
      .init(label: "Speed", value: speed),
      .init(label: "Progress", value: "\(progress)%"),
    ]
    loadingModel.health = health
    loadingModel.healthTone = tone
  }

  func failedToLoadURL() {
    stopTorrentStats()
    guard isWindowLoaded && window?.isVisible == true else { return }
    urlField.stringValue = loadingURL ?? ""
    errorMessageLabel.stringValue = failedToOpenURLMessage
    errorMessageLabel.isHidden = false
    overlayView.isHidden = true
    urlField.textColor = Tokens.Palette.destructive.nsColor
  }

  func resetWindowState() {
    stopTorrentStats()
    urlField.stringValue = ""
    urlField.textColor = Tokens.Palette.textPrimary.nsColor
    usernameField.stringValue = ""
    passwordField.stringValue = ""
    errorMessageLabel.stringValue = invalidURLMessage
    errorMessageLabel.isHidden = true
    rememberPasswordCheckBox.state = .off
    urlStackView.setVisibilityPriority(.notVisible, for: httpPrefixTextField)
    window?.makeFirstResponder(urlField)
    overlayView.isHidden = true
    playerCore = nil
    loadingURL = nil
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let playerCore else { return true }
    playerCore.stop()
    return true
  }

  func windowWillClose(_ notification: Notification) {
    stopTorrentStats()
    playerCore = nil
    overlayView.isHidden = true
  }

  override func cancelOperation(_ sender: Any?) {
    window?.close()
  }

  @IBAction func cancelBtnAction(_ sender: Any) {
    window?.close()
  }

  @IBAction func stopLoadingBtnAction(_ sender: Any) {
    stopLoading()
  }

  private func stopLoading() {
    stopTorrentStats()
    playerCore?.stop()
    overlayView.isHidden = true
  }

  @IBAction func openBtnAction(_ sender: Any) {
    if let url = getURL().url {
      if MainActor.assumeIsolated({ TorrentPlaybackCoordinator.shared.route(url, hud: PlayerCore.active.isInMiniPlayer, player: PlayerCore.active) }) { window?.close(); return }
      if rememberPasswordCheckBox.state == .on,
         let host = url.host,
         !usernameField.stringValue.isEmpty {
        try? KeychainAccess.write(username: usernameField.stringValue,
                                  password: passwordField.stringValue,
                                  forService: .httpAuth,
                                  server: host,
                                  port: url.port)
      }
      stopTorrentStats()
      overlayView.isHidden = false
      loadingModel.isTorrent = false
      loadingModel.stats = []
      loadingModel.progress = nil
      loadingModel.health = nil
      loadingModel.healthTone = .none
      // Must not leave the focus in the username or password text fields.
      window?.makeFirstResponder(nil)
      playerCore = PlayerCore.activeOrNewForMenuAction(isAlternative: isAlternativeAction)
      playerCore!.openURL(url)
    } else {
      Utility.showAlert("wrong_url_format")
    }
  }

  private func getURL() -> (url: URL?, hasScheme: Bool) {
    guard !urlField.stringValue.isEmpty else { return (nil, false) }
    let username = usernameField.stringValue
    let password = passwordField.stringValue
    let trimmedUrlString = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    // URL(string:) percent-encodes characters itself under the deployment
    // target, so pre-encoding would double-encode them.
    var pstr = trimmedUrlString
    var hasScheme = true
    if let url = URL(string: pstr), url.scheme == nil {
      pstr = "http://" + pstr
      hasScheme = false
    }
    guard let nsurl = NSURL(string: pstr)?.standardized, let urlComponents = NSURLComponents(url: nsurl, resolvingAgainstBaseURL: false) else { return (nil, false) }
    if !username.isEmpty {
      urlComponents.user = username
      if !password.isEmpty {
        urlComponents.password = password
      }
    }
    return (urlComponents.url, hasScheme)
  }

  // NSControlTextEditingDelegate

  func controlTextDidChange(_ obj: Notification) {
    if let textView = obj.userInfo?["NSFieldEditor"] as? NSTextView, let str = textView.textStorage?.string, str.isEmpty {
      errorMessageLabel.stringValue = invalidURLMessage
      errorMessageLabel.isHidden = true
      urlField.textColor = Tokens.Palette.textPrimary.nsColor
      urlStackView.setVisibilityPriority(.notVisible, for: httpPrefixTextField)
      openButton.isEnabled = true
      return
    }
    let (url, hasScheme) = getURL()
    if let url, TorrentPreferences.enabled, TorrentPlaybackCoordinator.recognizes(url) {
      // A magnet carries its identity in the query, not a host. The Open
      // action routes it through the torrent inspector instead.
      errorMessageLabel.isHidden = true
      urlField.textColor = Tokens.Palette.textPrimary.nsColor
      openButton.isEnabled = true
      urlStackView.setVisibilityPriority(.notVisible, for: httpPrefixTextField)
      usernameField.stringValue = ""
      passwordField.stringValue = ""
      return
    }
    if let url, let host = url.host {
      errorMessageLabel.isHidden = true
      urlField.textColor = Tokens.Palette.textPrimary.nsColor
      openButton.isEnabled = true
      if hasScheme {
        urlStackView.setVisibilityPriority(.notVisible, for: httpPrefixTextField)
      } else {
        urlStackView.setVisibilityPriority(.mustHold, for: httpPrefixTextField)
      }
      // find saved password
      if let (username, password) = try? KeychainAccess.read(username: nil, forService: .httpAuth, server: host, port: url.port) {
        usernameField.stringValue = username
        passwordField.stringValue = password
      } else {
        usernameField.stringValue = ""
        passwordField.stringValue = ""
      }
    } else {
      urlField.textColor = Tokens.Palette.destructive.nsColor
      errorMessageLabel.stringValue = invalidURLMessage
      errorMessageLabel.isHidden = false
      urlStackView.setVisibilityPriority(.notVisible, for: httpPrefixTextField)
      openButton.isEnabled = false
    }
  }

}
