//
//  LiveTranslationSettingsPage.swift
//  uniplayer
//
//  Settings › Live Translation. The page owns language choice, the two
//  package systems, their download actions, and the audio-permission entry
//  point. Playback is not started from here.
//

import Cocoa
import SwiftUI

fileprivate let ui = SettingsUIHelper.sharedUI

final class SettingsPageLiveTranslation: SettingsPage {
  override var identifier: String { "liveTranslation" }

  override var title: String {
    NSLocalizedString("Live Translation", comment: "Settings page")
  }

  override var image: NSImage {
    .sf("translate", withConfiguration: symbolConfiguration)!
  }

  override var showSubSections: Bool { false }

  private let speechInventory = SystemSpeechModelInventory()
  private let translationInventory = SystemTranslationPackInventory()
  private let downloadCoordinator = TranslationPackDownloadCoordinator()
  private lazy var installer = SystemTranslationPackInstaller(
    coordinator: downloadCoordinator)
  private lazy var model = LiveTranslationPackModel(
    speech: speechInventory, translation: translationInventory, installer: installer)

  private let targetPopup = NSPopUpButton()
  private let watchedStack = NSStackView()
  private let statusStack = NSStackView()
  private let refreshIndicator = NSProgressIndicator()
  private let downloadAllButton = NSButton()
  private let permissionStatus = NSTextField(labelWithString: "")
  private var configured = false
  private var isRefreshing = false
  private var refreshPending = false
  private var singleDownloadTask: Task<Void, Never>?
  private var downloadPollTask: Task<Void, Never>?
  private var pendingPackRequest: LiveTranslationLanguage?
  private var permissionObserver: NSObjectProtocol?
  private var packRequestObserver: NSObjectProtocol?

  deinit {
    downloadPollTask?.cancel()
    if let permissionObserver {
      NotificationCenter.default.removeObserver(permissionObserver)
    }
    if let packRequestObserver {
      NotificationCenter.default.removeObserver(packRequestObserver)
    }
  }

  private lazy var downloadHost: NSHostingView<TranslationPackDownloadHost> = {
    let host = NSHostingView(
      rootView: TranslationPackDownloadHost(coordinator: downloadCoordinator))
    host.translatesAutoresizingMaskIntoConstraints = false
    host.widthAnchor.constraint(equalToConstant: Tokens.Space.n1).isActive = true
    host.heightAnchor.constraint(equalToConstant: Tokens.Space.n1).isActive = true
    return host
  }()

  private final class DownloadRequest: NSObject {
    enum Kind { case speech, translation }
    let language: LiveTranslationLanguage
    let kind: Kind

    init(language: LiveTranslationLanguage, kind: Kind) {
      self.language = language
      self.kind = kind
    }
  }

  private final class DownloadButton: NSButton {
    var request: DownloadRequest?
  }

  // MARK: - Page

  override func content() -> [SettingsSection] {
    configureControls()
    return sections {
      section {
        SettingsList(title: .init("liveTranslation.languages.label")) {
          SettingsItem.Switch()
            .image(name: ["captions.bubble", "captions.bubble.fill"])
            .bindTo(.liveTranslationEnabled)
            .hasDescription()
          SettingsItem.Custom().view(targetRow)
          SettingsItem.Custom().view(watchedRow)
        }
      }
      section {
        SettingsList(title: .init("liveTranslation.packs.label")) {
          SettingsItem.Custom().view(statusView)
        }
      }
      section {
        SettingsList(title: .init("liveTranslation.behavior.label")) {
          SettingsItem.Switch()
            .image(name: ["arrow.down.circle", "arrow.down.circle.fill"])
            .bindTo(.liveTranslationAutoDownload)
            .hasDescription()
          SettingsItem.PopupButton()
            .image(name: ["arrow.triangle.branch", "arrow.triangle.branch"])
            .bindTo(.liveTranslationFallback, ofType: LiveTranslationFallback.self)
            .hasDescription()
          SettingsItem.PopupButton()
            .image(name: ["speaker.wave.2", "speaker.wave.3"])
            .bindTo(.liveTranslationPreferredStrategy, ofType: LiveTranslationStrategy.self)
            .hasDescription()
          SettingsItem.Switch()
            .image(name: ["text.alignleft", "text.alignleft"])
            .bindTo(.liveTranslationShowSource)
            .hasDescription()
          SettingsItem.Switch()
            .image(name: ["checkmark.seal", "checkmark.seal.fill"])
            .bindTo(.liveTranslationRepair)
            .hasDescription()
        }
      }
      section {
        SettingsList(title: .init("liveTranslation.audioAccess.label")) {
          SettingsItem.Custom().view(permissionRow)
        }
        SettingsList {
          SettingsItem.Custom().view(noteRow)
        }
      }
    }
  }

  override func pageLoaded() {
    updatePermissionStatus()
    if permissionObserver == nil {
      permissionObserver = NotificationCenter.default.addObserver(
        forName: .iinaLiveTranslationAudioPermissionChanged,
        object: nil, queue: .main) { [weak self] _ in
          self?.updatePermissionStatus()
        }
    }
    if packRequestObserver == nil {
      packRequestObserver = NotificationCenter.default.addObserver(
        forName: .iinaLiveTranslationPackDownloadRequested,
        object: nil, queue: .main) { [weak self] note in
          self?.handlePackDownloadRequest(note)
        }
    }
    Task { @MainActor in
      await refreshStatuses()
    }
  }

  // MARK: - Rows

  private var targetRow: NSView {
    let label = rowLabel("liveTranslation.target.label")
    let desc = rowDescription("liveTranslation.target.desc")
    targetPopup.controlSize = .regular
    targetPopup.setAccessibilityLabel(ui.localized("liveTranslation.target.label"))
    return ui.vStack(spacing: Tokens.Space.n4, label, targetPopup, desc)
  }

  private var watchedRow: NSView {
    let label = rowLabel("liveTranslation.watched.label")
    let desc = rowDescription("liveTranslation.watched.desc")
    return ui.vStack(spacing: Tokens.Space.n4, label, watchedStack, desc)
  }

  private var statusView: NSView {
    let title = rowLabel("liveTranslation.packs.title")
    let desc = rowDescription("liveTranslation.packs.desc")
    let controls = ui.hStack(
      spacing: Tokens.Space.n8,
      downloadAllButton,
      refreshIndicator)
    return ui.vStack(
      spacing: Tokens.Space.n8,
      title,
      statusStack,
      controls,
      desc,
      downloadHost)
  }

  private var permissionRow: NSView {
    let label = rowLabel("liveTranslation.audioAccess.title")
    let desc = rowDescription("liveTranslation.audioAccess.desc")
    permissionStatus.font = Tokens.Typography.caption.nsFont
    permissionStatus.lineBreakMode = .byWordWrapping
    permissionStatus.maximumNumberOfLines = 0
    permissionStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    updatePermissionStatus()
    let open = NSButton(
      title: ui.localized("liveTranslation.audioAccess.open"),
      target: self,
      action: #selector(openAudioPrivacy))
    open.bezelStyle = .rounded
    open.controlSize = .small
    let actions = ui.hStack(spacing: Tokens.Space.n8, permissionStatus, open)
    return ui.vStack(spacing: Tokens.Space.n4, label, actions, desc)
  }

  private var noteRow: NSView {
    let note = NSTextField(wrappingLabelWithString: ui.localized("liveTranslation.note"))
    note.font = Tokens.Typography.caption.nsFont
    note.textColor = Tokens.Palette.textSecondary.nsColor
    return note
  }

  // MARK: - Configuration

  private func configureControls() {
    guard !configured else { return }
    configured = true

    targetPopup.removeAllItems()
    for language in LiveTranslationLanguages.targetCandidates {
      targetPopup.addItem(withTitle: language.displayName)
      targetPopup.lastItem?.representedObject = language.id
    }
    let selected = LiveTranslationPreferences.targetID
    Preference.set(selected, for: .liveTranslationTarget)
    if let index = targetPopup.itemArray.firstIndex(where: {
      ($0.representedObject as? String) == selected
    }) {
      targetPopup.selectItem(at: index)
    }
    targetPopup.target = self
    targetPopup.action = #selector(targetChanged)

    watchedStack.orientation = .vertical
    watchedStack.alignment = .leading
    watchedStack.spacing = Tokens.Space.n4
    watchedStack.translatesAutoresizingMaskIntoConstraints = false
    let watched = Set(LiveTranslationPreferences.watchedIDs)
    for language in LiveTranslationLanguages.watchedCandidates {
      let checkbox = NSButton(
        checkboxWithTitle: language.displayName,
        target: self,
        action: #selector(watchedChanged))
      checkbox.state = watched.contains(language.id) ? .on : .off
      checkbox.identifier = NSUserInterfaceItemIdentifier(language.id)
      checkbox.controlSize = .small
      watchedStack.addArrangedSubview(checkbox)
    }

    statusStack.orientation = .vertical
    statusStack.alignment = .leading
    statusStack.spacing = Tokens.Space.n8
    statusStack.translatesAutoresizingMaskIntoConstraints = false

    refreshIndicator.style = .spinning
    refreshIndicator.controlSize = .small
    refreshIndicator.isDisplayedWhenStopped = false

    downloadAllButton.title = ui.localized("liveTranslation.downloadAll")
    downloadAllButton.bezelStyle = .rounded
    downloadAllButton.controlSize = .small
    downloadAllButton.target = self
    downloadAllButton.action = #selector(downloadAll)

    model.onUpdate = { [weak self] in
      self?.rebuildStatusRows()
    }
    updatePermissionStatus()
    rebuildStatusRows()
  }

  private func updatePermissionStatus() {
    switch LiveTranslationAudioPermission.shared.state {
    case .unknown:
      permissionStatus.stringValue = ui.localized("liveTranslation.audioAccess.notChecked")
      permissionStatus.textColor = Tokens.Palette.textSecondary.nsColor
    case .granted:
      permissionStatus.stringValue = ui.localized("liveTranslation.audioAccess.granted")
      permissionStatus.textColor = Tokens.Palette.textSecondary.nsColor
    case .denied:
      permissionStatus.stringValue = ui.localized("liveTranslation.audioAccess.denied")
      permissionStatus.textColor = Tokens.Palette.destructive.nsColor
    case .suspected:
      permissionStatus.stringValue = ui.localized("liveTranslation.audioAccess.suspected")
      permissionStatus.textColor = Tokens.Palette.destructive.nsColor
    }
  }

  // MARK: - Actions

  @objc private func targetChanged(_ sender: NSPopUpButton) {
    guard let id = sender.selectedItem?.representedObject as? String else { return }
    Preference.set(id, for: .liveTranslationTarget)
    Task { @MainActor in
      await refreshStatuses()
    }
  }

  @objc private func watchedChanged(_ sender: NSButton) {
    let ids = watchedStack.arrangedSubviews.compactMap { view -> String? in
      guard let checkbox = view as? NSButton, checkbox.state == .on else { return nil }
      return checkbox.identifier?.rawValue
    }
    LiveTranslationPreferences.setWatchedIDs(ids)
    Task { @MainActor in
      await refreshStatuses()
    }
  }

  @objc private func downloadSpeech(_ sender: NSButton) {
    guard let button = sender as? DownloadButton,
          let request = button.request,
          request.kind == .speech else { return }
    guard singleDownloadTask == nil, !model.isDownloadingAll else { return }
    singleDownloadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.model.installSpeech(for: request.language)
      if self.model.rows.first(where: {
        $0.language.id == request.language.id
      })?.speech == .installed {
        NotificationCenter.default.post(
          name: .iinaLiveTranslationSpeechModelInstalled, object: nil)
      }
      self.singleDownloadTask = nil
      self.rebuildStatusRows()
    }
  }

  @objc private func downloadTranslation(_ sender: NSButton) {
    guard let button = sender as? DownloadButton,
          let request = button.request,
          request.kind == .translation else { return }
    guard singleDownloadTask == nil, !model.isDownloadingAll else { return }
    singleDownloadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.model.installTranslation(for: request.language)
      self.postPackInstalledIfNeeded(languageID: request.language.id)
      self.singleDownloadTask = nil
      self.rebuildStatusRows()
      self.runPendingPackRequestIfPossible()
    }
  }

  @objc private func downloadAll(_ sender: NSButton) {
    if model.isDownloadingAll || singleDownloadTask != nil {
      singleDownloadTask?.cancel()
      Task { @MainActor in
        model.cancelDownloads()
      }
      return
    }
    guard !anyDownloadInProgress else { return }
    Task { @MainActor in
      await model.installAllMissing()
      if model.rows.contains(where: { $0.speech == .installed }) {
        NotificationCenter.default.post(
          name: .iinaLiveTranslationSpeechModelInstalled, object: nil)
      }
      if model.rows.contains(where: { $0.translation == .installed }) {
        NotificationCenter.default.post(
          name: .iinaLiveTranslationPackInstalled, object: nil)
      }
      runPendingPackRequestIfPossible()
    }
  }

  /// The caption pipeline asks for a pack when automatic downloads are on and
  /// the video's pair is missing. The system sheet can only be hosted here.
  private func handlePackDownloadRequest(_ note: Notification) {
    guard let sourceID =
            note.userInfo?[LiveTranslationPackDownloadRequest.sourceKey] as? String,
          let source = LiveTranslationLanguages.language(for: sourceID),
          source.id != LiveTranslationPreferences.target.id else { return }
    guard singleDownloadTask == nil, !model.isDownloadingAll,
          !anyDownloadInProgress else {
      // Keep the newest request; retry when the current download finishes.
      pendingPackRequest = source
      return
    }
    startPackDownload(source)
  }

  private func runPendingPackRequestIfPossible() {
    guard let pending = pendingPackRequest,
          singleDownloadTask == nil, !model.isDownloadingAll,
          !anyDownloadInProgress else { return }
    pendingPackRequest = nil
    startPackDownload(pending)
  }

  private func startPackDownload(_ source: LiveTranslationLanguage) {
    singleDownloadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if !self.model.rows.contains(where: { $0.language.id == source.id }) {
        await self.model.refresh(
          watched: self.checkedLanguages() + [source],
          target: LiveTranslationPreferences.target)
      }
      await self.model.installTranslation(for: source)
      self.postPackInstalledIfNeeded(languageID: source.id)
      self.singleDownloadTask = nil
      self.rebuildStatusRows()
      self.runPendingPackRequestIfPossible()
    }
  }

  private func postPackInstalledIfNeeded(languageID: String) {
    guard model.rows.first(where: { $0.language.id == languageID })?
      .translation == .installed else { return }
    NotificationCenter.default.post(
      name: .iinaLiveTranslationPackInstalled, object: nil)
  }

  @objc private func openAudioPrivacy(_ sender: NSButton) {
    guard let url = URL(string:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  // MARK: - Refresh and status rows

  @MainActor
  private func refreshStatuses() async {
    guard !model.isDownloadingAll else { return }
    if isRefreshing {
      refreshPending = true
      return
    }
    isRefreshing = true
    repeat {
      refreshPending = false
      rebuildStatusRows()
      await model.refresh(
        watched: checkedLanguages(),
        target: LiveTranslationPreferences.target)
    } while refreshPending
    isRefreshing = false
    rebuildStatusRows()
    ensureDownloadPolling()
  }

  /// A download started by another app or by playback leaves the page showing
  /// `.downloading` until something refreshes it. Poll while that is the only
  /// active download; page-initiated downloads already report their progress.
  private func ensureDownloadPolling() {
    let externalDownload = model.rows.contains {
      $0.speech == .downloading || $0.translation == .downloading
    }
    guard downloadPollTask == nil, externalDownload,
          singleDownloadTask == nil, !model.isDownloadingAll else { return }
    downloadPollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard let self, !Task.isCancelled else { return }
        await self.refreshStatuses()
        let stillDownloading = self.model.rows.contains {
          $0.speech == .downloading || $0.translation == .downloading
        }
        if !stillDownloading { break }
      }
      self?.downloadPollTask = nil
    }
  }

  private func checkedLanguages() -> [LiveTranslationLanguage] {
    let ids = watchedStack.arrangedSubviews.compactMap { view -> String? in
      guard let checkbox = view as? NSButton, checkbox.state == .on else { return nil }
      return checkbox.identifier?.rawValue
    }
    return ids.compactMap(LiveTranslationLanguages.language(for:))
  }

  private func rebuildStatusRows() {
    let downloadingAll = model.isDownloadingAll
    let busy = anyDownloadInProgress
    targetPopup.isEnabled = !busy
    for case let checkbox as NSButton in watchedStack.arrangedSubviews {
      checkbox.isEnabled = !busy
    }

    if isRefreshing || busy {
      refreshIndicator.startAnimation(nil)
    } else {
      refreshIndicator.stopAnimation(nil)
    }

    if downloadingAll || singleDownloadTask != nil {
      downloadAllButton.title = ui.localized("liveTranslation.cancel")
      downloadAllButton.isEnabled = true
    } else {
      downloadAllButton.title = ui.localized("liveTranslation.downloadAll")
      downloadAllButton.isEnabled = !isRefreshing
        && !busy
        && model.rows.contains { $0.speech.canDownload || $0.translation.canDownload }
    }

    for view in statusStack.arrangedSubviews {
      statusStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    if model.rows.isEmpty {
      let empty = NSTextField(labelWithString: ui.localized("liveTranslation.packs.empty"))
      empty.font = Tokens.Typography.caption.nsFont
      empty.textColor = Tokens.Palette.textSecondary.nsColor
      statusStack.addArrangedSubview(empty)
      return
    }

    for (index, row) in model.rows.enumerated() {
      if index > 0 {
        statusStack.addArrangedSubview(ui.separator())
      }
      statusStack.addArrangedSubview(makeStatusRow(row))
    }
  }

  /// A single in-flight download uses the same system sheet as Download All;
  /// serializing both keeps the coordinator and the row states honest.
  private var anyDownloadInProgress: Bool {
    singleDownloadTask != nil
      || model.isDownloadingAll
      || model.rows.contains {
        $0.speech == .downloading || $0.translation == .downloading
      }
  }

  private func makeStatusRow(_ row: LiveTranslationPackRow) -> NSView {
    let title = NSTextField(labelWithString: row.language.displayName)
    title.font = Tokens.Typography.bodyStrong.nsFont
    title.textColor = Tokens.Palette.textPrimary.nsColor

    let buttonsAllowed = !isRefreshing && !anyDownloadInProgress
    let speechLabel = statusLabel(speechText(row.speech), failed: row.speech.isFailed)
    let speechButton = downloadButton(
      for: row.language, kind: .speech,
      canDownload: buttonsAllowed && row.speech.canDownload,
      accessibility: String(format: ui.localized("liveTranslation.download.speech"),
                            row.language.displayName))
    var headerViews: [NSView] = [title, ui.flexibleSpace(), speechLabel]
    if let speechButton {
      headerViews.append(speechButton)
    }

    let targetName = LiveTranslationPreferences.target.displayName
    let translationTitle = NSTextField(labelWithString:
      String(format: ui.localized("liveTranslation.translationTo"), targetName))
    translationTitle.font = Tokens.Typography.caption.nsFont
    translationTitle.textColor = Tokens.Palette.textSecondary.nsColor
    let translationLabel = statusLabel(
      translationText(row.translation), failed: row.translation.isFailed)
    let translationButton = downloadButton(
      for: row.language, kind: .translation,
      canDownload: buttonsAllowed && row.translation.canDownload,
      accessibility: String(format: ui.localized("liveTranslation.download.translation"),
                            row.language.displayName, targetName))
    var translationViews: [NSView] = [translationTitle, ui.flexibleSpace(), translationLabel]
    if let translationButton {
      translationViews.append(translationButton)
    }

    return ui.vStack(
      spacing: Tokens.Space.n2,
      ui.hStack(align: .centerY, spacing: Tokens.Space.n8, headerViews),
      ui.hStack(align: .centerY, spacing: Tokens.Space.n8, translationViews))
  }

  private func statusLabel(_ text: String, failed: Bool) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Tokens.Typography.caption.nsFont
    label.textColor = failed
      ? Tokens.Palette.destructive.nsColor
      : Tokens.Palette.textSecondary.nsColor
    label.lineBreakMode = .byTruncatingTail
    return label
  }

  private func downloadButton(for language: LiveTranslationLanguage,
                              kind: DownloadRequest.Kind,
                              canDownload: Bool,
                              accessibility: String) -> NSButton? {
    guard canDownload else { return nil }
    let button = DownloadButton(
      title: ui.localized("liveTranslation.download"),
      target: self,
      action: kind == .speech ? #selector(downloadSpeech(_:))
        : #selector(downloadTranslation(_:)))
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.request = DownloadRequest(language: language, kind: kind)
    button.setAccessibilityLabel(accessibility)
    return button
  }

  private func speechText(_ status: SpeechPackStatus) -> String {
    switch status {
    case .checking: return ui.localized("liveTranslation.status.checking")
    case .installed: return ui.localized("liveTranslation.status.installed")
    case .available: return ui.localized("liveTranslation.status.notInstalled")
    case .downloading: return ui.localized("liveTranslation.status.downloading")
    case .unsupported: return ui.localized("liveTranslation.status.unsupported")
    case .failed(let message):
      return String(format: ui.localized("liveTranslation.status.failed"), message)
    }
  }

  private func translationText(_ status: TranslationPackStatus) -> String {
    switch status {
    case .checking: return ui.localized("liveTranslation.status.checking")
    case .installed: return ui.localized("liveTranslation.status.installed")
    case .available: return ui.localized("liveTranslation.status.notInstalled")
    case .downloading: return ui.localized("liveTranslation.status.downloading")
    case .unsupported: return ui.localized("liveTranslation.status.unsupported")
    case .notNeeded: return ui.localized("liveTranslation.status.notNeeded")
    case .failed(let message):
      return String(format: ui.localized("liveTranslation.status.failed"), message)
    }
  }

  // MARK: - Helpers

  private func rowLabel(_ key: String) -> NSTextField {
    let label = NSTextField(labelWithString: ui.localized(key))
    label.font = Tokens.Typography.bodyStrong.nsFont
    label.textColor = Tokens.Palette.textPrimary.nsColor
    return label
  }

  private func rowDescription(_ key: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: ui.localized(key))
    label.font = Tokens.Typography.caption.nsFont
    label.textColor = Tokens.Palette.textSecondary.nsColor
    return label
  }
}

private extension SpeechPackStatus {
  var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}

private extension TranslationPackStatus {
  var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}
