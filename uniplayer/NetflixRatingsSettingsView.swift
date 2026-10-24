import AppKit

/// Credential entry stays native; the WebKit page receives only public ratings.
final class NetflixRatingsSettingsView: NSStackView {
  private let keyField = NSSecureTextField()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let enabled = NSButton(checkboxWithTitle: NSLocalizedString("Show IMDb ratings on Netflix cards", comment: "Netflix ratings"), target: nil, action: nil)
  private var observer: NSObjectProtocol?

  init() {
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = Tokens.Space.n8
    edgeInsets = NSEdgeInsets(top: Tokens.Space.n10, left: Tokens.Space.n12,
                             bottom: Tokens.Space.n10, right: Tokens.Space.n12)
    enabled.state = NetflixRatingService.enabled ? .on : .off
    enabled.target = self; enabled.action = #selector(toggle)
    addArrangedSubview(enabled)
    let note = NSTextField(wrappingLabelWithString: NSLocalizedString(
      "Displays scores and vote counts, for example 9.3 (12K). Visible Netflix titles are sent to OMDb for matching. Your API key is stored in the Keychain and is never shared with Netflix.", comment: "Netflix ratings"))
    note.font = Tokens.Typography.caption.nsFont
    note.textColor = Tokens.Palette.textSecondary.nsColor
    addArrangedSubview(note)
    keyField.placeholderString = NSLocalizedString("OMDb API Key", comment: "Netflix ratings")
    keyField.setAccessibilityLabel(keyField.placeholderString)
    keyField.bezelStyle = .roundedBezel
    keyField.widthAnchor.constraint(greaterThanOrEqualToConstant: Tokens.Size.n200).isActive = true
    keyField.target = self; keyField.action = #selector(save)
    addArrangedSubview(keyField)
    let save = NSButton(title: NSLocalizedString("Save Key", comment: "Settings"), target: self, action: #selector(save))
    let remove = NSButton(title: NSLocalizedString("Remove Key", comment: "Settings"), target: self, action: #selector(remove))
    let get = NSButton(title: NSLocalizedString("Get an OMDb Key…", comment: "Netflix ratings"), target: self, action: #selector(getKey))
    [save, remove, get].forEach { $0.bezelStyle = .rounded }
    let actions = NSStackView(views: [save, remove, get]); actions.spacing = Tokens.Space.n8
    addArrangedSubview(actions)
    status.font = Tokens.Typography.caption.nsFont
    status.textColor = Tokens.Palette.textSecondary.nsColor
    addArrangedSubview(status)
    refresh()
    observer = NotificationCenter.default.addObserver(forName: NetflixRatingService.statusChanged, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

  private func refresh() {
    if !NetflixRatingService.shared.status.isEmpty {
      status.stringValue = NSLocalizedString(NetflixRatingService.shared.status, comment: "Netflix ratings")
    } else if (try? KeychainAccess.read(username: NSUserName(), forService: NetflixRatingService.keychainService)) != nil {
      status.stringValue = NSLocalizedString("A key is stored. Ratings appear as you browse Netflix.", comment: "Netflix ratings")
    } else {
      status.stringValue = NSLocalizedString("No OMDb key stored.", comment: "Netflix ratings")
    }
  }

  @objc private func toggle() {
    UserDefaults.standard.set(enabled.state == .on, forKey: NetflixRatingService.enabledKey)
    NetflixRatingService.shared.configurationChanged()
    refresh()
  }
  @objc private func save() {
    let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return }
    do {
      try KeychainAccess.write(username: NSUserName(), password: key, forService: NetflixRatingService.keychainService)
      keyField.stringValue = ""
      NetflixRatingService.shared.configurationChanged()
      refresh()
    } catch { status.stringValue = NSLocalizedString("Couldn’t save the key in the Keychain.", comment: "Netflix ratings") }
  }
  @objc private func remove() {
    do {
      try KeychainAccess.remove(username: NSUserName(), forService: NetflixRatingService.keychainService)
      keyField.stringValue = ""
      NetflixRatingService.shared.configurationChanged()
      refresh()
    } catch { status.stringValue = NSLocalizedString("Couldn’t remove the key from the Keychain.", comment: "Netflix ratings") }
  }
  @objc private func getKey() { NSWorkspace.shared.open(URL(string: "https://www.omdbapi.com/apikey.aspx")!) }
}
