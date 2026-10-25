//
//  SettingsPageAssistant.swift
//  uniplayer
//
//  Endpoint, profile, model and key for the AI inspector, plus the one-shot
//  source used to translate subtitle files. The key is stored in the Keychain
//  and is never shown again after it is saved.
//

import Cocoa
import SaySoAI

private final class FieldEditingObserver: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {
  var onEndEditing: (() -> Void)?
  var onTextChange: (() -> Void)?
  var onSelection: (() -> Void)?

  func controlTextDidEndEditing(_ notification: Notification) {
    onEndEditing?()
  }

  func controlTextDidChange(_ notification: Notification) {
    onTextChange?()
  }

  func comboBoxSelectionDidChange(_ notification: Notification) {
    onSelection?()
  }
}

final class SettingsPageAssistant: SettingsPage {

  override var identifier: String { "assistant" }

  override var title: String {
    NSLocalizedString("AI Assistant", comment: "Settings page")
  }

  override var image: NSImage {
    .sf("sparkles", withConfiguration: symbolConfiguration)!
  }

  override var showSubSections: Bool { false }

  private let providerPopup = NSPopUpButton()
  private let profilePopup = NSPopUpButton()
  private let endpointField = NSTextField()
  private let modelCombo = NSComboBox()
  private let fetchModelsButton = NSButton()
  private let keyField = NSSecureTextField()
  private let keyStatus = NSTextField(wrappingLabelWithString: "")
  private let modelStatus = NSTextField(wrappingLabelWithString: "")
  private let profileNote = NSTextField(wrappingLabelWithString: "")
  private let connectionService = AssistantService()
  private let testButton = NSButton()
  private let privacyNote = NSTextField(wrappingLabelWithString: "")

  private let translationSourcePopup = NSPopUpButton()
  private let translationModelField = NSTextField()
  private let translationModelRow = NSStackView()
  private let translationExplanation = NSTextField(wrappingLabelWithString: "")
  private let translationStatus = NSTextField(wrappingLabelWithString: "")
  private let translationAction = NSButton()
  private let translationCheck = NSButton()
  private var translationCheckTask: Task<Void, Never>?
  private var translationSignInTask: Task<Void, Never>?
  private var signInGeneration = 0
  private var modelLoadTask: Task<Void, Never>?
  private var modelLoadGeneration = 0
  private var isLoadingModels = false
  private var lastTranslationSource: TranslationSource?
  private let modelEditingObserver = FieldEditingObserver()
  private let endpointEditingObserver = FieldEditingObserver()
  private let translationEditingObserver = FieldEditingObserver()

  override func content() -> [SettingsSection] {
    configureControls()
    return sections {
      section {
        SettingsList(title: SettingsLocalization.Key("assistant.connection.label")) {
          SettingsItem.Custom().view(row(title: SettingsLocalization.Key("assistant.provider.label"),
                                         control: providerPopup))
          SettingsItem.Custom().view(row(title: SettingsLocalization.Key("assistant.profile.label"),
                                         control: profilePopup))
          SettingsItem.Custom().view(row(title: SettingsLocalization.Key("assistant.endpoint.label"),
                                         control: endpointField))
          SettingsItem.Custom().view(inset(profileNote))
          SettingsItem.Custom().view(modelRow)
          SettingsItem.Custom().view(inset(keyRow))
          SettingsItem.Custom().view(inset(connectionTestRow))
        }
        SettingsList {
          SettingsItem.Custom().view(inset(privacyNote))
        }
      }
      section {
        SettingsList(title: SettingsLocalization.Key("assistant.translation.label")) {
          SettingsItem.Switch()
            .image(name: ["captions.bubble", "captions.bubble.fill"])
            .bindTo(.subtitleTranslationEnabled)
            .hasDescription()
          SettingsItem.LongInput()
            .bindTo(.subtitleTranslationLanguage)
            .hasDescription()
          SettingsItem.Custom().view(row(title: SettingsLocalization.Key("assistant.translation_source.label"),
                                         control: translationSourcePopup))
          SettingsItem.Custom().view(translationDetails)
        }
      }
    }
  }

  // MARK: Controls

  private func configureControls() {
    providerPopup.addItems(withTitles: AssistantProviderKind.allCases.map(\.title))
    let provider = AssistantProviderKind(
      rawValue: Preference.string(for: .assistantProvider) ?? "") ?? .openAICompatible
    providerPopup.selectItem(at: providerPopup.indexOfItem(withTitle: provider.title))
    providerPopup.target = self
    providerPopup.action = #selector(providerChanged)
    providerPopup.controlSize = .regular

    profilePopup.addItems(withTitles: AssistantProfiles.known.map(\.name))
    let configuration = AssistantConfiguration.load()
    if let index = AssistantProfiles.known.firstIndex(where: { $0.id == configuration.profileID }) {
      profilePopup.selectItem(at: index)
    }
    profilePopup.target = self
    profilePopup.action = #selector(profileChanged)
    profilePopup.controlSize = .regular

    configureField(endpointField)
    endpointField.bind(.value, to: UserDefaults.standard,
                       withKeyPath: Preference.Key.assistantEndpoint.rawValue)
    endpointEditingObserver.onTextChange = { [weak self] in self?.endpointChanged() }
    endpointField.delegate = endpointEditingObserver
    endpointField.placeholderString = configuration.profile.baseURL?.absoluteString
      ?? provider.defaultEndpoint
    endpointField.setAccessibilityLabel(NSLocalizedString("Assistant Endpoint", comment: "Settings"))

    configureField(modelCombo)
    modelEditingObserver.onEndEditing = { [weak self] in self?.modelChanged() }
    modelEditingObserver.onSelection = { [weak self] in self?.modelChanged() }
    modelCombo.delegate = modelEditingObserver
    modelCombo.completes = true
    modelCombo.numberOfVisibleItems = 12
    modelCombo.bind(.value, to: UserDefaults.standard,
                    withKeyPath: Preference.Key.assistantModel.rawValue)
    modelCombo.target = self
    modelCombo.action = #selector(modelChanged)
    modelCombo.placeholderString = provider.defaultModel.isEmpty
      ? NSLocalizedString("Model", comment: "Assistant")
      : provider.defaultModel
    modelCombo.setAccessibilityLabel(NSLocalizedString("Assistant Model", comment: "Settings"))
    populateModelHints()

    fetchModelsButton.title = NSLocalizedString("Load Models", comment: "Assistant")
    fetchModelsButton.bezelStyle = .rounded
    fetchModelsButton.target = self
    fetchModelsButton.action = #selector(loadModels)

    keyField.translatesAutoresizingMaskIntoConstraints = false
    keyField.bezelStyle = .roundedBezel
    keyField.placeholderString = "sk-…"
    keyField.widthAnchor.constraint(greaterThanOrEqualToConstant: Tokens.Size.n200).isActive = true
    keyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    keyField.target = self
    keyField.action = #selector(saveKey)
    keyField.setAccessibilityLabel(NSLocalizedString("Assistant API Key", comment: "Settings"))

    keyStatus.font = Tokens.Typography.caption.nsFont
    keyStatus.textColor = Tokens.Palette.textSecondary.nsColor
    modelStatus.font = Tokens.Typography.caption.nsFont
    modelStatus.textColor = Tokens.Palette.textSecondary.nsColor
    profileNote.font = Tokens.Typography.caption.nsFont
    profileNote.textColor = Tokens.Palette.textSecondary.nsColor
    privacyNote.font = Tokens.Typography.caption.nsFont
    privacyNote.textColor = Tokens.Palette.textSecondary.nsColor
    refreshKeyStatus()

    translationSourcePopup.addItems(withTitles: TranslationSource.allCases.map(\.title))
    let source = TranslationSettings.source
    translationSourcePopup.selectItem(withTitle: source.title)
    translationSourcePopup.target = self
    translationSourcePopup.action = #selector(translationSourceChanged)
    translationSourcePopup.controlSize = .regular

    configureField(translationModelField)
    translationEditingObserver.onEndEditing = { [weak self] in self?.saveTranslationModel() }
    translationModelField.delegate = translationEditingObserver
    translationModelField.target = self
    translationModelField.action = #selector(translationModelChanged)
    translationModelField.setAccessibilityLabel(
      NSLocalizedString("Translation Model", comment: "Settings"))

    translationExplanation.font = Tokens.Typography.caption.nsFont
    translationExplanation.textColor = Tokens.Palette.textSecondary.nsColor
    translationStatus.font = Tokens.Typography.caption.nsFont
    translationStatus.textColor = Tokens.Palette.textSecondary.nsColor

    translationAction.bezelStyle = .rounded
    translationAction.target = self
    translationAction.action = #selector(translationActionTapped)
    translationCheck.title = NSLocalizedString("Check Again", comment: "Settings")
    translationCheck.bezelStyle = .rounded
    translationCheck.target = self
    translationCheck.action = #selector(checkTranslationSource)
    translationModelRow.orientation = .vertical
    translationModelRow.alignment = .leading
    translationModelRow.spacing = Tokens.Space.n4
    let modelLabel = NSTextField(labelWithString: NSLocalizedString("CLI Model", comment: "Settings"))
    modelLabel.font = Tokens.Typography.bodyStrong.nsFont
    modelLabel.textColor = Tokens.Palette.textPrimary.nsColor
    translationModelRow.addArrangedSubview(modelLabel)
    translationModelRow.addArrangedSubview(translationModelField)

    updateAssistantUI()
    updateTranslationUI()
    lastTranslationSource = source
    checkTranslationSource()
  }

  private func configureField(_ field: NSTextField) {
    field.translatesAutoresizingMaskIntoConstraints = false
    field.bezelStyle = .roundedBezel
    field.widthAnchor.constraint(greaterThanOrEqualToConstant: Tokens.Size.n200).isActive = true
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
  }

  private func row(title: SettingsLocalization.Key, control: NSView) -> NSView {
    let label = NSTextField(labelWithString: NSLocalizedString(title.rawValue, comment: title.rawValue))
    label.font = Tokens.Typography.bodyStrong.nsFont
    label.textColor = Tokens.Palette.textPrimary.nsColor
    let stack = NSStackView(views: [label, control])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Tokens.Space.n8
    return inset(stack)
  }

  private func inset(_ content: NSView) -> NSView {
    let wrapper = NSView()
    wrapper.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    wrapper.addSubview(content)
    content.padding(.horizontal(Tokens.Space.n12), .vertical(Tokens.Space.n10))
    return wrapper
  }

  private var modelRow: NSView {
    let label = NSTextField(labelWithString: NSLocalizedString("Model", comment: "Settings"))
    label.font = Tokens.Typography.bodyStrong.nsFont
    label.textColor = Tokens.Palette.textPrimary.nsColor
    let buttons = NSStackView(views: [fetchModelsButton])
    buttons.orientation = .horizontal
    buttons.spacing = Tokens.Space.n8
    let input = NSStackView(views: [modelCombo, buttons])
    input.orientation = .horizontal
    input.alignment = .centerY
    input.spacing = Tokens.Space.n8
    let stack = NSStackView(views: [label, input, modelStatus])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Tokens.Space.n4
    return inset(stack)
  }

  private var translationDetails: NSView {
    let buttons = NSStackView(views: [translationAction, translationCheck])
    buttons.orientation = .horizontal
    buttons.spacing = Tokens.Space.n8
    let stack = NSStackView(views: [
      translationExplanation, translationModelRow, translationStatus, buttons,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Tokens.Space.n8
    return inset(stack)
  }

  private var keyRow: NSView {
    let label = NSTextField(labelWithString: NSLocalizedString("API Key", comment: "Settings"))
    label.font = Tokens.Typography.bodyStrong.nsFont
    label.textColor = Tokens.Palette.textPrimary.nsColor

    let save = NSButton(title: NSLocalizedString("Save Key", comment: "Settings"),
                        target: self, action: #selector(saveKey))
    save.bezelStyle = .rounded
    let remove = NSButton(title: NSLocalizedString("Remove Key", comment: "Settings"),
                          target: self, action: #selector(removeKey))
    remove.bezelStyle = .rounded

    let buttons = NSStackView(views: [save, remove])
    buttons.orientation = .horizontal
    buttons.spacing = Tokens.Space.n8
    let inputRow = NSStackView(views: [keyField, buttons])
    inputRow.orientation = .vertical
    inputRow.alignment = .leading
    inputRow.spacing = Tokens.Space.n8

    let stack = NSStackView(views: [label, inputRow, keyStatus])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Tokens.Space.n4
    return stack
  }

  private var connectionTestRow: NSView {
    testButton.title = NSLocalizedString("Test Connection", comment: "Assistant")
    testButton.bezelStyle = .rounded
    testButton.target = self
    testButton.action = #selector(testConnection)
    let note = NSTextField(wrappingLabelWithString: NSLocalizedString(
      "Sends one short message to your selected provider.", comment: "Assistant"))
    note.font = Tokens.Typography.caption.nsFont
    note.textColor = Tokens.Palette.textSecondary.nsColor
    let stack = NSStackView(views: [testButton, note])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Tokens.Space.n4
    return stack
  }

  private var windowForControls: NSWindow? { endpointField.window }

  // MARK: Assistant UI

  private func updateAssistantUI() {
    let configuration = AssistantConfiguration.load()
    let isClaude = configuration.provider == .claude
    profilePopup.isEnabled = !isClaude
    fetchModelsButton.isEnabled = !isClaude && !isLoadingModels
    endpointField.placeholderString = isClaude
      ? configuration.provider.defaultEndpoint
      : configuration.profile.baseURL?.absoluteString
    modelCombo.placeholderString = configuration.provider.defaultModel.isEmpty
      ? NSLocalizedString("Model", comment: "Assistant")
      : configuration.provider.defaultModel
    profileNote.stringValue = isClaude
      ? NSLocalizedString("The native Claude Messages API.", comment: "Assistant")
      : (configuration.profile.note ?? "")
    updatePrivacyNote()
    populateModelHints()
  }

  private func updatePrivacyNote(endpoint: String? = nil) {
    var configuration = AssistantConfiguration.load()
    if let endpoint {
      configuration.endpoint = endpoint
    }
    var privacy = NSLocalizedString(
      "The key is stored in the Keychain. Requests go only to the endpoint above; video frames and files are never uploaded. A full file path is sent only when the inspector's opt-in is on.",
      comment: "Settings privacy note")
    if configuration.isDeepSeek {
      privacy += "\n\n" + NSLocalizedString(
        "Reviews & discussion uses DeepSeek Search. A title, year and episode may be sent to DeepSeek; each successful search is billed by DeepSeek.",
        comment: "Settings privacy note")
    }
    privacyNote.stringValue = privacy
  }

  private func populateModelHints() {
    let configuration = AssistantConfiguration.load()
    let current = modelCombo.stringValue.isEmpty
      ? (Preference.string(for: .assistantModel) ?? "")
      : modelCombo.stringValue
    modelCombo.removeAllItems()
    if configuration.provider == .openAICompatible {
      modelCombo.addItems(withObjectValues: configuration.profile.hints)
    }
    modelCombo.stringValue = current
  }

  private func cancelModelLoading() {
    modelLoadGeneration += 1
    modelLoadTask?.cancel()
    modelLoadTask = nil
    isLoadingModels = false
  }

  private func endpointChanged() {
    cancelModelLoading()
    refreshModelButton()
    updatePrivacyNote(endpoint: endpointField.stringValue)
  }

  private func keyChanged() {
    cancelModelLoading()
    refreshModelButton()
  }

  private func refreshModelButton() {
    let provider = AssistantProviderKind(
      rawValue: Preference.string(for: .assistantProvider) ?? "") ?? .openAICompatible
    fetchModelsButton.isEnabled = provider == .openAICompatible && !isLoadingModels
  }

  // MARK: Translation UI

  private func updateTranslationUI() {
    let source = TranslationSettings.source
    translationSourcePopup.selectItem(withTitle: source.title)
    translationExplanation.stringValue = source.explanation
    translationModelRow.isHidden = !source.needsModel
    translationModelField.stringValue = TranslationSettings.model(for: source) ?? ""
    translationModelField.placeholderString = source == .claudeCLI
      ? NSLocalizedString("Default Claude model", comment: "Translation source")
      : NSLocalizedString("Default Codex model", comment: "Translation source")
    translationAction.isHidden = source == .assistant || source == .appleOnDevice
    translationCheck.isHidden = source == .assistant
    translationAction.title = source == .claudeCLI
      ? NSLocalizedString("Copy Sign-In Command", comment: "Translation source")
      : NSLocalizedString("Sign In to Codex", comment: "Translation source")
    switch source {
    case .assistant:
      translationStatus.stringValue = NSLocalizedString(
        "Uses the assistant connection above.", comment: "Translation source")
    case .appleOnDevice:
      translationStatus.stringValue = SaySoTranslation.appleAvailabilityText(
        SaySoTranslation.appleAvailability())
    case .codexCLI, .claudeCLI:
      translationStatus.stringValue = NSLocalizedString("Checking…", comment: "Translation source")
    }
  }

  private func saveTranslationModel() {
    let source = TranslationSettings.source
    guard source.needsModel else { return }
    let key: Preference.Key = source == .codexCLI ? .translationCodexModel : .translationClaudeModel
    Preference.set(translationModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                   for: key)
  }

  // MARK: Actions

  @objc private func modelChanged() {
    Preference.set(modelCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                   for: .assistantModel)
  }

  @objc private func providerChanged() {
    let index = providerPopup.indexOfSelectedItem
    guard index >= 0, AssistantProviderKind.allCases.indices.contains(index) else { return }
    let provider = AssistantProviderKind.allCases[index]
    let previousDefaults = AssistantProviderKind.allCases.flatMap {
      [$0.defaultEndpoint, $0.defaultModel]
    }
    cancelModelLoading()
    // Setting stringValue on a bound control does not write through to
    // UserDefaults, so persist the replacement explicitly.
    let currentEndpoint = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let anthropicCompatibility = "https://api.anthropic.com/v1"
    let anthropicCompatibilityChat = "https://api.anthropic.com/v1/chat/completions"
    if provider == .claude {
      // Known provider defaults become the native Messages endpoint; a custom
      // proxy or gateway stays where the reader put it.
      if isKnownProviderEndpoint(currentEndpoint) {
        endpointField.stringValue = provider.defaultEndpoint
        Preference.set(provider.defaultEndpoint, for: .assistantEndpoint)
      }
    } else {
      if currentEndpoint.isEmpty
          || currentEndpoint == AssistantProviderKind.claude.defaultEndpoint
          || currentEndpoint == anthropicCompatibility
          || currentEndpoint == anthropicCompatibilityChat {
        endpointField.stringValue = provider.defaultEndpoint
        Preference.set(provider.defaultEndpoint, for: .assistantEndpoint)
      }
      let derived = AssistantProfiles.derivedID(for: endpointField.stringValue)
      if let index = AssistantProfiles.known.firstIndex(where: { $0.id == derived }) {
        profilePopup.selectItem(at: index)
        Preference.set(derived, for: .assistantProfile)
      }
    }
    if modelCombo.stringValue.isEmpty
        || previousDefaults.contains(modelCombo.stringValue) {
      modelCombo.stringValue = provider.defaultModel
      Preference.set(provider.defaultModel, for: .assistantModel)
    }
    Preference.set(provider.rawValue, for: .assistantProvider)
    updateAssistantUI()
  }

  /// A documented service address is not a custom proxy: switching to native
  /// Claude must not send Messages requests to an OpenAI-compatible base.
  private func isKnownProviderEndpoint(_ endpoint: String) -> Bool {
    let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    if trimmed == AssistantProviderKind.claude.defaultEndpoint { return true }
    guard let base = AssistantProfiles.baseURL(trimmed)?.absoluteString else { return false }
    let documented = Set(AssistantProfiles.known.compactMap { profile in
      profile.baseURL.flatMap { AssistantProfiles.baseURL($0.absoluteString)?.absoluteString }
    })
    let openAIBase = AssistantProfiles.baseURL(
      AssistantProviderKind.openAICompatible.defaultEndpoint)?.absoluteString
    return documented.contains(base) || base == openAIBase
  }

  @objc private func profileChanged() {
    let index = profilePopup.indexOfSelectedItem
    guard AssistantProfiles.known.indices.contains(index) else { return }
    cancelModelLoading()
    let profile = AssistantProfiles.known[index]
    Preference.set(profile.id, for: .assistantProfile)
    if let base = profile.baseURL {
      endpointField.stringValue = base.absoluteString
      Preference.set(base.absoluteString, for: .assistantEndpoint)
    }
    if modelCombo.stringValue.isEmpty, let hint = profile.hints.first {
      modelCombo.stringValue = hint
      Preference.set(hint, for: .assistantModel)
    }
    modelStatus.stringValue = ""
    updateAssistantUI()
  }

  @objc private func loadModels() {
    windowForControls?.makeFirstResponder(nil)
    let configuration = AssistantConfiguration.load()
    guard configuration.provider == .openAICompatible,
          let request = configuration.catalogRequest else {
      modelStatus.stringValue = NSLocalizedString(
        "Model lists are only available for OpenAI-compatible providers.",
        comment: "Assistant")
      return
    }
    guard configuration.supportsSaySoTransport else {
      modelStatus.stringValue = NSLocalizedString(
        "Model lists need HTTPS or a loopback address. Enter the LAN model name manually.",
        comment: "Assistant")
      return
    }
    cancelModelLoading()
    let generation = modelLoadGeneration
    isLoadingModels = true
    updateAssistantUI()
    modelStatus.stringValue = NSLocalizedString("Loading models…", comment: "Assistant")
    modelLoadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let result: Result<[AIModel], Error>
      do {
        result = .success(try await ModelCatalog().fetch(request))
      } catch {
        result = .failure(error)
      }
      guard self.modelLoadGeneration == generation else { return }
      let current = AssistantConfiguration.load()
      guard current.catalogRequest == request else {
        self.isLoadingModels = false
        self.modelLoadTask = nil
        self.modelStatus.stringValue = NSLocalizedString(
          "Configuration changed. Load models again.", comment: "Assistant")
        self.fetchModelsButton.isEnabled =
          current.provider == .openAICompatible && current.supportsSaySoTransport
        return
      }
      switch result {
      case .success(let models):
        self.modelCombo.removeAllItems()
        self.modelCombo.addItems(withObjectValues: models.map(\.id))
        self.modelStatus.stringValue = String(
          format: NSLocalizedString("Loaded %d models.", comment: "Assistant"), models.count)
      case .failure(let error):
        self.modelStatus.stringValue = AssistantProfiles.catalogMessage(error)
      }
      self.isLoadingModels = false
      self.modelLoadTask = nil
      self.fetchModelsButton.isEnabled = current.supportsSaySoTransport
    }
  }

  @objc private func testConnection() {
    windowForControls?.makeFirstResponder(nil)
    let configuration = AssistantConfiguration.load()
    guard configuration.isConfigured else {
      keyStatus.stringValue = NSLocalizedString(
        "Enter a valid endpoint, model and any required API key.", comment: "Assistant")
      return
    }
    testButton.isEnabled = false
    keyStatus.stringValue = NSLocalizedString("Testing connection…", comment: "Assistant")
    if configuration.provider == .openAICompatible, configuration.supportsSaySoTransport {
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          let provider = try configuration.makeHTTPProvider()
          _ = try await provider.probe()
          self.keyStatus.stringValue = NSLocalizedString("Connection succeeded.", comment: "Assistant")
        } catch let error as AIProviderError {
          self.keyStatus.stringValue = SaySoTranslation
            .assistantError(error, source: .assistant)
            .localizedDescription
        } catch {
          self.keyStatus.stringValue = error.localizedDescription
        }
        self.testButton.isEnabled = true
      }
      return
    }
    testWithStreaming(configuration)
  }

  private func testWithStreaming(_ configuration: AssistantConfiguration) {
    connectionService.stream(configuration: configuration,
      request: AssistantRequest(messages: [AssistantProviderMessage(role: .user, content: "Reply with OK.")], tools: []),
      onEvent: { _ in },
      onError: { [weak self] error in
        self?.keyStatus.stringValue = error.localizedDescription
        self?.testButton.isEnabled = true
      },
      onFinish: { [weak self] in
        guard self?.testButton.isEnabled == false else { return }
        self?.keyStatus.stringValue = NSLocalizedString("Connection succeeded.", comment: "Assistant")
        self?.testButton.isEnabled = true
      })
  }

  @objc private func translationSourceChanged() {
    let previous = lastTranslationSource
    if previous?.needsModel == true {
      let key: Preference.Key = previous == .codexCLI
        ? .translationCodexModel : .translationClaudeModel
      Preference.set(translationModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                     for: key)
    }
    let index = translationSourcePopup.indexOfSelectedItem
    guard TranslationSource.allCases.indices.contains(index) else { return }
    let source = TranslationSource.allCases[index]
    Preference.set(source.rawValue, for: .translationSource)
    signInGeneration += 1
    translationSignInTask?.cancel()
    translationSignInTask = nil
    translationAction.isEnabled = true
    lastTranslationSource = source
    updateTranslationUI()
    checkTranslationSource()
  }

  @objc private func translationModelChanged() {
    saveTranslationModel()
  }

  @objc private func translationActionTapped() {
    switch TranslationSettings.source {
    case .codexCLI:
      let source = TranslationSource.codexCLI
      translationSignInTask?.cancel()
      signInGeneration += 1
      let generation = signInGeneration
      translationAction.isEnabled = false
      translationStatus.stringValue = NSLocalizedString(
        "Starting Codex sign-in…", comment: "Translation source")
      translationSignInTask = Task { @MainActor [weak self] in
        guard let self else { return }
        defer {
          if self.signInGeneration == generation {
            self.translationSignInTask = nil
            if TranslationSettings.source == source {
              self.translationAction.isEnabled = true
            }
          }
        }
        do {
          let output = try await SaySoTranslation.signInToCodex { line in
            Task { @MainActor in
              guard self.signInGeneration == generation,
                    TranslationSettings.source == source else { return }
              self.translationStatus.stringValue = line
            }
          }
          guard self.signInGeneration == generation,
                TranslationSettings.source == source else { return }
          if !output.isEmpty { self.translationStatus.stringValue = output }
          self.checkTranslationSource()
        } catch {
          guard self.signInGeneration == generation,
                TranslationSettings.source == source else { return }
          self.translationStatus.stringValue = error.localizedDescription
        }
      }
    case .claudeCLI:
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(TranslationSettings.claudeSignInCommand, forType: .string)
      translationStatus.stringValue = NSLocalizedString(
        "Sign-in command copied. Run it once in Terminal, then choose Check Again.",
        comment: "Translation source")
    case .assistant, .appleOnDevice:
      break
    }
  }

  @objc private func checkTranslationSource() {
    let source = TranslationSettings.source
    guard source != .assistant else { return }
    translationCheckTask?.cancel()
    translationStatus.stringValue = NSLocalizedString("Checking…", comment: "Translation source")
    translationCheckTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let result = try await SaySoTranslation.check(source: source)
        guard !Task.isCancelled, TranslationSettings.source == source else { return }
        if source == .claudeCLI {
          translationStatus.stringValue = String(
            format: NSLocalizedString(
              "%@ found. Run the sign-in command once if a translation says you are signed out.",
              comment: "Translation source"), result)
        } else {
          translationStatus.stringValue = result
        }
        if source == .codexCLI {
          translationAction.title = NSLocalizedString("Sign In Again", comment: "Translation source")
        }
      } catch {
        guard !Task.isCancelled, TranslationSettings.source == source else { return }
        translationStatus.stringValue =
          (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if source == .codexCLI {
          translationAction.title = NSLocalizedString("Sign In to Codex", comment: "Translation source")
        }
      }
      self.translationCheck.isEnabled = true
    }
    translationCheck.isEnabled = false
  }

  @objc private func saveKey() {
    let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return }
    do {
      try KeychainAccess.write(
        username: NSUserName(), password: key, forService: .assistantAPIKey)
      keyField.stringValue = ""
      refreshKeyStatus()
      keyChanged()
    } catch {
      keyStatus.stringValue = NSLocalizedString(
        "The key could not be saved.", comment: "Settings")
    }
  }

  @objc private func removeKey() {
    do {
      // The API already treats a missing credential as success.
      try KeychainAccess.remove(username: NSUserName(), forService: .assistantAPIKey)
      keyField.stringValue = ""
      refreshKeyStatus()
      keyChanged()
    } catch {
      keyStatus.stringValue = NSLocalizedString(
        "The key could not be removed.", comment: "Settings")
    }
  }

  deinit {
    translationCheckTask?.cancel()
    translationSignInTask?.cancel()
    modelLoadTask?.cancel()
  }

  private func refreshKeyStatus() {
    do {
      _ = try KeychainAccess.read(username: nil, forService: .assistantAPIKey)
      keyStatus.stringValue = NSLocalizedString("A key is stored.", comment: "Settings")
    } catch KeychainAccess.KeychainError.noResult {
      keyStatus.stringValue = NSLocalizedString("No key stored.", comment: "Settings")
    } catch {
      keyStatus.stringValue = NSLocalizedString(
        "The stored key could not be read.", comment: "Settings")
    }
  }
}
