//
//  OpenURLWindowController.swift
//  uniplayer
//
//  Created by Collider LI on 25/8/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa

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
    loadingMediaLabel.font = Tokens.Typography.loading.nsFont
    urlField.delegate = self
    ([.closeButton, .miniaturizeButton, .zoomButton] as [NSWindow.ButtonType]).forEach {
      window?.standardWindowButton($0)?.isHidden = true
    }

    loadingMediaProgressIndicator.startAnimation(self)
  }

  func showLoadingScreen(playerCore: PlayerCore) {
    _ = window
    overlayView.isHidden = false
    // Must not leave the focus in the username or password text fields.
    window?.makeFirstResponder(nil)
    self.playerCore = playerCore
    loadingURL = playerCore.info.currentURL?.absoluteString
    NSApp.activate()
    showWindow(self)
  }

  func failedToLoadURL() {
    guard isWindowLoaded && window?.isVisible == true else { return }
    urlField.stringValue = loadingURL ?? ""
    errorMessageLabel.stringValue = failedToOpenURLMessage
    errorMessageLabel.isHidden = false
    overlayView.isHidden = true
    urlField.textColor = Tokens.Palette.destructive.nsColor
  }

  func resetWindowState() {
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
    guard let playerCore else { return }
    playerCore.stop()
    overlayView.isHidden = true
  }

  @IBAction func openBtnAction(_ sender: Any) {
    if let url = getURL().url {
      if MainActor.assumeIsolated({ TorrentPlaybackCoordinator.shared.route(url) }) { window?.close(); return }
      if rememberPasswordCheckBox.state == .on,
         let host = url.host,
         !usernameField.stringValue.isEmpty {
        try? KeychainAccess.write(username: usernameField.stringValue,
                                  password: passwordField.stringValue,
                                  forService: .httpAuth,
                                  server: host,
                                  port: url.port)
      }
      overlayView.isHidden = false
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
