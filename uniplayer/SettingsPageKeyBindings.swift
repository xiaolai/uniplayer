//
//  SettingsKeyBindings.swift
//  uniplayer
//
//  Created by Hechen Li on 2026-02-01.
//  Copyright © 2026 lhc. All rights reserved.
//

fileprivate let ui = SettingsUIHelper.sharedUI


class SettingsPageKeyBindings: SettingsPage {
  override var identifier: String {
    "key.bindings"
  }
  
  override var title: String {
    return NSLocalizedString("preference.keybindings", comment: "Key Bindings")
  }

  override var image: NSImage {
    return .sf("keyboard", withConfiguration: symbolConfiguration)!
  }

  override var localizationTable: String {
    "SettingsKeyBindingLocalizable"
  }
  
  override var showSubSections: Bool { false }

  private lazy var configEditor: ConfigEditor = ConfigEditor()

  override func content() -> [SettingsSection] {
    return sections {
      sectionMediaControl()
      sectionConfiguration()
    }
  }

  private func sectionMediaControl() -> SettingsSection {
    return section {
      SettingsList {
        SettingsItem.Switch()
          .bindTo(.useMediaKeys)
          .image(name: ["playpause.circle", "playpause"])
          .withHelpLink(AppData.wikiLink.appending("/Manage-Key-Bindings"))
      }
    }
  }

  private func sectionConfiguration() -> SettingsSection {
    return section {
      SettingsList {
        SettingsItem.General(title: .text_KeyBindingSet)
          .image(name: ["book.and.wrench", "wrench.adjustable", "wrench"])
          .withValueView(configEditor.chooserView)
        SettingsItem.Custom()
          .view(configEditor.editorView)
        SettingsItem.Switch()
          .bindTo(.displayKeyBindingRawValues)
      }
    }
  }
}


private extension NSUserInterfaceItemIdentifier {
  static let columnID = NSUserInterfaceItemIdentifier("MainColumn")
}


fileprivate class ConfigEditor: SettingsAccessory.Base {

  private let prefObserver = Preference.Observer()
  let chooserView: NSView
  let editorView: NSView

  let kbTableView: NSTableView
  let searchField: NSSearchField

  let chooserPopupButton: NSPopUpButton
  let addConfBtn: NSButton
  let delConfBtn: NSButton
  let addKeyMappingBtn: NSButton

  var mappingController: NSArrayController

  var currentConfName: String!
  var currentConfFilePath: String!

  // This variable is to prevent `NSTableView.reloadData()` in the `loadConfigFile` to trigger `loadConfigFile` again thus forming an infinite loop
  var isLoadingConfig = false

  override init() {
    self.mappingController = NSArrayController()
    self.kbTableView = NSTableView()
    self.searchField = NSSearchField()
    searchField.translatesAutoresizingMaskIntoConstraints = false

    self.chooserPopupButton = NSPopUpButton()
    chooserPopupButton.translatesAutoresizingMaskIntoConstraints = false
    chooserPopupButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)

    self.chooserView = NSView()
    chooserView.translatesAutoresizingMaskIntoConstraints = false
    self.editorView = NSView()
    editorView.translatesAutoresizingMaskIntoConstraints = false

    self.addConfBtn = NSButton()
    self.delConfBtn = NSButton()
    addConfBtn.bezelStyle = .push
    delConfBtn.bezelStyle = .push

    self.addKeyMappingBtn = NSButton()

    super.init()

    kbTableView.bind(.content, to: mappingController, withKeyPath: "arrangedObjects", options: nil)
    kbTableView.bind(.selectionIndexes, to: mappingController, withKeyPath: "selectionIndexes", options: nil)
    kbTableView.delegate = self
    kbTableView.headerView = nil
    kbTableView.target = self

    let column = NSTableColumn(identifier: .columnID)
    column.title = "Items"
    kbTableView.addTableColumn(column)

    addConfBtn.translatesAutoresizingMaskIntoConstraints = false
    addConfBtn.image = .init(systemSymbolName: "square.grid.3x1.folder.badge.plus", accessibilityDescription: "Add Configuration")
    addConfBtn.target = self
    addConfBtn.action = #selector(addConfBtnAction)
    delConfBtn.translatesAutoresizingMaskIntoConstraints = false
    delConfBtn.image = .init(systemSymbolName: "trash", accessibilityDescription: "Delete Configuration")
    delConfBtn.target = self
    delConfBtn.action = #selector(deleteConfFileAction)

    let chooserStackView = ui.hStack(chooserPopupButton, delConfBtn, addConfBtn)
    chooserView.addSubview(chooserStackView)
    chooserStackView.padding(.all(Tokens.Space.n8))

    addKeyMappingBtn.translatesAutoresizingMaskIntoConstraints = false
    addKeyMappingBtn.imagePosition = .imageOnly
    addKeyMappingBtn.bezelStyle = .circular
    addKeyMappingBtn.image = .sf("plus")
    addKeyMappingBtn.target = self
    addKeyMappingBtn.action = #selector(addKeyMappingAction)
    addKeyMappingBtn.size(width: Tokens.Size.n26, height: Tokens.Size.n26)

    let headerViewContainer = NSView()
    headerViewContainer.translatesAutoresizingMaskIntoConstraints = false
    headerViewContainer.size(height: Tokens.Size.n32)
    let headerView = ui.hStack(searchField, addKeyMappingBtn)
    headerViewContainer.addSubview(headerView)
    headerView.padding(.top(Tokens.Space.n8), .leading(Tokens.Space.n16), .trailing(Tokens.Space.n16))

    let editorStackView = ui.vStack(align: .leading, spacing: Tokens.Space.n0, headerViewContainer, kbTableView)

    searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    searchField.bind(
      .predicate, to: mappingController, withKeyPath: "filterPredicate",
      options: [
        .predicateFormat: "(readableAction contains[cd] $value) OR (prettyCommand contains[cd] $value)",
      ]
    )

    editorView.addSubview(editorStackView)
    editorStackView.padding(.leading(Tokens.Space.n16), .trailing, .vertical)

    NotificationCenter.default.addObserver(forName: .iinaKeyBindingChanged, object: nil, queue: .main, using: saveToConfFile)

    prefObserver.add(.displayKeyBindingRawValues) { [unowned self] _ in
      kbTableView.reloadData()
    }
    loadConfigFile(Preference.string(for: .currentInputConfigName), true)
  }

  /// This function firstly reloads the table data, select the config file row, then load the config file.
  /// If the target config file cannot be found, or the file cannot be parsed correctly, it will fallback to the default config.
  /// - Parameter configName: the target config name
  private func loadConfigFile(_ configName: String?, _ initialSetup: Bool = false) {
    guard configName != Preference.string(for: .currentInputConfigName) || initialSetup else { return }
    isLoadingConfig = true

    func fallback() {
      isLoadingConfig = false
      DispatchQueue.main.async {
        Utility.showAlert("keybinding_config.error", arguments: [configName ?? "Unknown"], sheetWindow: self.view.window)
      }
      loadConfigFile(KeyBindingConfigStore.fallbackDefault)
    }

    guard let configName, let confFilePath = KeyBindingConfigStore.filePath(forConfig: configName, window: kbTableView.window, showAlert: false) else {
      fallback()
      return
    }

    populateChooser(select: configName)
    currentConfName = configName
    currentConfFilePath = confFilePath

    guard let mapping = KeyMapping.parseInputConf(at: currentConfFilePath) else { fallback(); return }

    mappingController.content = nil
    mappingController.add(contentsOf: mapping)
    mappingController.setSelectionIndexes(IndexSet())

    changeButtonEnabledStatus()

    if !initialSetup {
      Preference.set(currentConfName, for: .currentInputConfigName)
      setKeybindingsForPlayerCore()
    }

    isLoadingConfig = false
  }

  private func populateChooser(select currentConfName: String? = nil) {
    guard let menu = chooserPopupButton.menu else { return }

    menu.removeAllItems()
    for name in KeyBindingConfigStore.configNames {
      let isDefaultConfig = KeyBindingConfigStore.isDefaultConfig(name)
      menu.addItem(withTitle: name, image: isDefaultConfig ? ["lock"] : nil,
                   action: #selector(configSelected), target: self, obj: name)
    }

    if let currentConfName {
      chooserPopupButton.selectItem(withTitle: currentConfName)
    }
  }

  func saveToConfFile(_ sender: Notification) {
    let predicate = mappingController.filterPredicate
    mappingController.filterPredicate = nil
    let keyMappings = mappingController.arrangedObjects as! [KeyMapping]
    setKeybindingsForPlayerCore()
    mappingController.filterPredicate = predicate
    KeyBindingConfigStore.save(keyMappings, to: currentConfFilePath, window: view.window)
  }

  @objc private func configSelected() {
    guard !isLoadingConfig else { return }
    guard let item = chooserPopupButton.selectedItem, item.title != currentConfName else { return }
    loadConfigFile(item.title)
    changeButtonEnabledStatus()
  }

  @objc private func addConfBtnAction() {
    let menu = NSMenu()
    menu.addItem(.sectionHeader(title: ui.localized(.text_NewKeyBindingSet)))
    menu.addItem(withTitle: ui.localized(.text_CreateAnEmptySet),
                 action: #selector(newConfFileAction), target: self)
    menu.addItem(withTitle: ui.localized(.text_DuplicateCurrentSet),
                 action: #selector(duplicateConfFileAction), target: self)
    menu.addItem(withTitle: ui.localized(.text_ImportAnExistingConfigFile),
                 action: #selector(importConfigAction), target: self)
    menu.addItem(.separator())
    menu.addItem(withTitle: ui.localized(.text_ShowTheConfigFileIn),
                 action: #selector(showConfFileAction), target: self)
    NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: addConfBtn)
  }

  @objc func newConfFileAction(_ sender: AnyObject) {
    Utility.quickPromptPanel("config.new", validator: KeyBindingConfigStore.configNameValidator, sheetWindow: addConfBtn.window) { newName in
      guard let newFilePath = KeyBindingConfigStore.newConfigPath(forName: newName, window: self.kbTableView.window) else { return }

      if !FileManager.default.createFile(atPath: newFilePath, contents: nil, attributes: nil) {
        Utility.showAlert("config.cannot_create", sheetWindow: self.addConfBtn.window)
        return
      }
      self.loadConfigFile(newName)
    }
  }

  @objc func duplicateConfFileAction(_ sender: AnyObject) {
    Utility.quickPromptPanel("config.duplicate", validator: KeyBindingConfigStore.configNameValidator, sheetWindow: addConfBtn.window) { newName in
      guard let newFilePath = KeyBindingConfigStore.newConfigPath(forName: newName, window: self.kbTableView.window) else { return }

      do {
        try FileManager.default.copyItem(atPath: self.currentConfFilePath!, toPath: newFilePath)
      } catch let error {
        Utility.showAlert("config.cannot_create", arguments: [error.localizedDescription], sheetWindow: self.view.window)
        return
      }
      self.loadConfigFile(newName)
    }
  }

  @objc func importConfigAction(_ sender: Any) {
    Utility.quickOpenPanel(title: "Select Config File to Import", chooseDir: false, sheetWindow: view.window, allowedFileTypes: ["conf"]) { url in
      guard url.isFileURL, url.lastPathComponent.hasSuffix(".conf") else { return }
      let newFilePath = Utility.userInputConfDirURL.appendingPathComponent(url.lastPathComponent).path
      let newName = url.deletingPathExtension().lastPathComponent
      // copy file
      do {
        try FileManager.default.copyItem(atPath: url.path, toPath: newFilePath)
      } catch let error {
        Utility.showAlert("config.cannot_create", arguments: [error.localizedDescription], sheetWindow: self.view.window)
        return
      }
      self.loadConfigFile(newName)
    }
  }

  @objc func showConfFileAction(_ sender: AnyObject) {
    let url = URL(fileURLWithPath: currentConfFilePath)
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  @objc func deleteConfFileAction(_ sender: AnyObject) {
    guard isCurrentConfigEditable() else { return }
    Task { @MainActor in
      guard await Dialogs.ask("delete_keybindingset").show(in: kbTableView.window!) else { return }
      do {
        try FileManager.default.removeItem(atPath: currentConfFilePath)
      } catch {
        await Dialogs.alert("error_deleting_file").show(in: view.window!)
      }
      // Fallback to default
      loadConfigFile(KeyBindingConfigStore.fallbackDefault)
    }
  }

  @objc func addKeyMappingAction(_ sender: AnyObject) {
    Task { @MainActor in
      guard isCurrentConfigEditable() else {
        await Dialogs.alert("duplicate_config").show(in: kbTableView.window!)
        return
      }
      showKeyBindingPanel { key, action in
        guard !key.isEmpty && !action.isEmpty else { return }
        if action.hasPrefix("@uniplayer") {
          let trimmedAction = action[action.index(action.startIndex, offsetBy: "@uniplayer".count)...].trimmingCharacters(in: .whitespaces)
          self.mappingController.addObject(KeyMapping(rawKey: key,
                                                      rawAction: trimmedAction,
                                                      isUniPlayerCommand: true))
        } else {
          self.mappingController.addObject(KeyMapping(rawKey: key, rawAction: action))
        }

        self.kbTableView.scrollRowToVisible((self.mappingController.arrangedObjects as! [AnyObject]).count - 1)
        NotificationCenter.default.post(Notification(name: .iinaKeyBindingChanged))
      }
    }
  }

  @objc func removeKeyMappingAction(_ sender: ButtonWithObject) {
    guard let km = sender.object else { return }
    mappingController.remove(km)
    NotificationCenter.default.post(Notification(name: .iinaKeyBindingChanged))
  }

  @objc func editKeyMappingAction(_ sender: ButtonWithObject) {
    Task { @MainActor in
      guard isCurrentConfigEditable() else {
        await Dialogs.alert("duplicate_config").show(in: kbTableView.window!)
        return
      }
      guard let km = sender.object else { return }
      showKeyBindingPanel(key: km.rawKey, action: km.readableAction) { key, action in
        guard !key.isEmpty && !action.isEmpty else { return }
        km.rawKey = key
        km.rawAction = action
        self.kbTableView.reloadData()
        NotificationCenter.default.post(Notification(name: .iinaKeyBindingChanged))
      }
    }
  }

  @objc func showHelpForLockedSetAction(_ sender: ButtonWithObject) {
    Task {
      await Dialogs.alert("duplicate_config").show(in: kbTableView.window!)
    }
  }

  private func showKeyBindingPanel(key: String = "", action: String = "", ok: @escaping (String, String) -> Void) {
    KeyBindingConfigStore.showKeyBindingPanel(
      key: key, action: action, window: kbTableView.window, ok: ok)
  }

  private func changeButtonEnabledStatus() {
    let shouldEnableEdit = isCurrentConfigEditable()
    delConfBtn.isEnabled = shouldEnableEdit
    addKeyMappingBtn.image = shouldEnableEdit ? .sf("plus") : .customLockBadgeQuestionmark
  }

  func isCurrentConfigEditable() -> Bool {
    return !KeyBindingConfigStore.isDefaultConfig(currentConfName)
  }

  private func setKeybindingsForPlayerCore() {
    PlayerCore.setKeyBindings(mappingController.arrangedObjects as! [KeyMapping])
  }
}

extension ConfigEditor: NSTableViewDelegate, NSMenuDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let km = (mappingController.arrangedObjects as? [KeyMapping])?[at: row] else { return nil }
    let cell = (tableView.makeView(withIdentifier: .columnID, owner: self) as? KeyMappingCell) ?? KeyMappingCell()

    cell.setup(keyMapping: km, isSelected: row == tableView.selectedRow, self)
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    return RowView()
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    return 32
  }
}


fileprivate class KeyMappingCell: NSTableCellView {
  var keyLabel: NSTextField!
  var actionLabel: NSTextField!
  var editButton: ButtonWithObject!
  var removeButton: ButtonWithObject!
  var lockHelpButton: ButtonWithObject!
  weak var editor: ConfigEditor!

  func setup(keyMapping km: KeyMapping, isSelected: Bool, _ editor: ConfigEditor) {
    self.editor = editor

    if keyLabel == nil || actionLabel == nil {
      self.identifier = .columnID

      let actionLabel = NSTextField(labelWithString: "")
      actionLabel.translatesAutoresizingMaskIntoConstraints = false

      let spacer = NSView()
      spacer.translatesAutoresizingMaskIntoConstraints = false
      spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

      func createActionButton(symbol: String, action: Selector) -> ButtonWithObject {
        let image = NSImage.sf(symbol)!
        let button = ButtonWithObject(
          title: "", image: image, target: editor, action: action)
        button.bezelStyle = .circular
        button.size(width: Tokens.Size.n20, height: Tokens.Size.n20)
        button.isHidden = true
        return button
      }

      self.editButton = createActionButton(
        symbol: "pencil", action: #selector(editor.editKeyMappingAction))
      self.removeButton = createActionButton(
        symbol: "trash.fill", action: #selector(editor.removeKeyMappingAction))
      self.lockHelpButton = createActionButton(
        symbol: "custom.lock.badge.questionmark", action: #selector(editor.showHelpForLockedSetAction))

      let keyBox = NSBox()
      keyBox.translatesAutoresizingMaskIntoConstraints = false
      keyBox.titlePosition = .noTitle
      keyBox.boxType = .custom
      keyBox.borderWidth = Tokens.Stroke.hairline
      keyBox.borderColor = Tokens.Palette.separator.nsColor
      keyBox.fillColor = Tokens.Palette.controlBackground.nsColor
      keyBox.cornerRadius = Tokens.Radius.n4
      keyBox.contentViewMargins = .zero
      let keyLabel = NSTextField(labelWithAttributedString: NSAttributedString(string: ""))
      keyLabel.translatesAutoresizingMaskIntoConstraints = false
      keyBox.contentView?.addSubview(keyLabel)
      keyBox.size(height: Tokens.Size.n28)
      keyLabel.padding(.horizontal(Tokens.Space.n4)).center(.y, with: keyBox.contentView)

      self.keyLabel = keyLabel
      self.actionLabel = actionLabel

      let stackView = NSStackView(views: [actionLabel, spacer, lockHelpButton, removeButton, editButton, keyBox])
      stackView.translatesAutoresizingMaskIntoConstraints = false
      stackView.orientation = .horizontal
      stackView.alignment = .centerY

      self.addSubview(stackView)
      stackView.padding(.vertical, .horizontal(Tokens.Space.n4))
    }

    selectionChanged(isSelected)

    if Preference.bool(for: .displayKeyBindingRawValues) {
      keyLabel.font = Tokens.Typography.mono.nsFont
      actionLabel.font = Tokens.Typography.mono.nsFont
    } else {
      keyLabel.font = Tokens.Typography.body.nsFont
      actionLabel.font = Tokens.Typography.body.nsFont
    }

    keyLabel.attributedStringValue = km.attributedKeyForDisplay
    actionLabel.stringValue = km.actionForDisplay
    removeButton.object = km
    editButton.object = km
  }

  func selectionChanged(_ selected: Bool) {
    if editor.isCurrentConfigEditable() {
      editButton.isHidden = !selected
      removeButton.isHidden = !selected
      lockHelpButton.isHidden = true
    } else {
      lockHelpButton.isHidden = !selected
    }
  }
}


fileprivate class ButtonWithObject : NSButton {
  weak var object: KeyMapping?
}


class RowView: NSTableRowView {
  override var isSelected: Bool {
    didSet {
      // Push selection state to the cell view
      for subview in subviews {
        (subview as? KeyMappingCell)?.selectionChanged(isSelected)
      }
    }
  }
}
