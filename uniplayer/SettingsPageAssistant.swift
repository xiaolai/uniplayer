//
//  SettingsPageAssistant.swift
//  uniplayer
//
//  Endpoint, model and key for the AI inspector. The key is stored in the
//  Keychain and is never shown again after it is saved.
//

import Cocoa

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
  private let endpointField = NSTextField()
  private let modelField = NSTextField()
  private let keyField = NSSecureTextField()
  private let keyStatus = NSTextField(labelWithString: "")
  private let privacyNote = NSTextField(wrappingLabelWithString: "")

  override func content() -> [SettingsSection] {
    configureControls()
    return sections {
      section {
        SettingsList(title: SettingsLocalization.Key("assistant.connection.label")) {
          SettingsItem.Custom().view(row(title: SettingsLocalization.Key("assistant.provider.label"),
                                         control: providerPopup))
          SettingsItem.Custom().view(row(title: SettingsLocalization.Key("assistant.endpoint.label"),
                                         control: endpointField))
          SettingsItem.Custom().view(row(title: SettingsLocalization.Key("assistant.model.label"),
                                         control: modelField))
          SettingsItem.Custom().view(keyRow)
        }
        SettingsList {
          SettingsItem.Custom().view(privacyNote)
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

    configureField(endpointField)
    endpointField.bind(.value, to: UserDefaults.standard,
                       withKeyPath: Preference.Key.assistantEndpoint.rawValue)
    endpointField.placeholderString = provider.defaultEndpoint
    endpointField.setAccessibilityLabel(NSLocalizedString("Assistant Endpoint", comment: "Settings"))

    configureField(modelField)
    modelField.bind(.value, to: UserDefaults.standard,
                    withKeyPath: Preference.Key.assistantModel.rawValue)
    modelField.placeholderString = provider.defaultModel
    modelField.setAccessibilityLabel(NSLocalizedString("Assistant Model", comment: "Settings"))

    keyField.translatesAutoresizingMaskIntoConstraints = false
    keyField.bezelStyle = .roundedBezel
    keyField.placeholderString = "sk-…"
    keyField.widthAnchor.constraint(equalToConstant: Tokens.Size.n260).isActive = true
    keyField.target = self
    keyField.action = #selector(saveKey)
    keyField.setAccessibilityLabel(NSLocalizedString("Assistant API Key", comment: "Settings"))

    keyStatus.font = Tokens.Typography.caption.nsFont
    keyStatus.textColor = Tokens.Palette.textSecondary.nsColor
    privacyNote.font = Tokens.Typography.caption.nsFont
    privacyNote.textColor = Tokens.Palette.textSecondary.nsColor
    privacyNote.stringValue = NSLocalizedString(
      "The key is stored in the Keychain. Requests go only to the endpoint above; video frames and files are never uploaded. A full file path is sent only when the inspector's opt-in is on.",
      comment: "Settings privacy note")
    refreshKeyStatus()
  }

  private func configureField(_ field: NSTextField) {
    field.translatesAutoresizingMaskIntoConstraints = false
    field.bezelStyle = .roundedBezel
    field.widthAnchor.constraint(equalToConstant: Tokens.Size.n360).isActive = true
  }

  private func row(title: SettingsLocalization.Key, control: NSView) -> NSView {
    let label = NSTextField(labelWithString: NSLocalizedString(title.rawValue, comment: title.rawValue))
    label.font = Tokens.Typography.settingsRowTitle.nsFont
    label.textColor = Tokens.Palette.textPrimary.nsColor
    let stack = NSStackView(views: [label, control])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Tokens.Space.n4
    return stack
  }

  private var keyRow: NSView {
    let label = NSTextField(labelWithString: NSLocalizedString("API Key", comment: "Settings"))
    label.font = Tokens.Typography.settingsRowTitle.nsFont
    label.textColor = Tokens.Palette.textPrimary.nsColor

    let save = NSButton(title: NSLocalizedString("Save Key", comment: "Settings"),
                        target: self, action: #selector(saveKey))
    save.bezelStyle = .rounded
    let remove = NSButton(title: NSLocalizedString("Remove Key", comment: "Settings"),
                          target: self, action: #selector(removeKey))
    remove.bezelStyle = .rounded

    let inputRow = NSStackView(views: [keyField, save, remove])
    inputRow.orientation = .horizontal
    inputRow.spacing = Tokens.Space.n8

    let stack = NSStackView(views: [label, inputRow, keyStatus])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Tokens.Space.n4
    return stack
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

  // MARK: Actions

  @objc private func providerChanged() {
    let index = providerPopup.indexOfSelectedItem
    guard index >= 0, AssistantProviderKind.allCases.indices.contains(index) else { return }
    let provider = AssistantProviderKind.allCases[index]
    let previousDefaults = AssistantProviderKind.allCases.flatMap {
      [$0.defaultEndpoint, $0.defaultModel]
    }
    // Setting stringValue on a bound control does not write through to
    // UserDefaults, so persist the replacement explicitly.
    if endpointField.stringValue.isEmpty
        || previousDefaults.contains(endpointField.stringValue) {
      endpointField.stringValue = provider.defaultEndpoint
      Preference.set(provider.defaultEndpoint, for: .assistantEndpoint)
    }
    if modelField.stringValue.isEmpty
        || previousDefaults.contains(modelField.stringValue) {
      modelField.stringValue = provider.defaultModel
      Preference.set(provider.defaultModel, for: .assistantModel)
    }
    endpointField.placeholderString = provider.defaultEndpoint
    modelField.placeholderString = provider.defaultModel
    Preference.set(provider.rawValue, for: .assistantProvider)
  }

  @objc private func saveKey() {
    let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return }
    do {
      try KeychainAccess.write(
        username: NSUserName(), password: key, forService: .assistantAPIKey)
      keyField.stringValue = ""
      refreshKeyStatus()
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
    } catch {
      keyStatus.stringValue = NSLocalizedString(
        "The key could not be removed.", comment: "Settings")
    }
  }
}
