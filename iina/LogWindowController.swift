//
//  LogWindowController.swift
//  iina
//
//  Created by Yuze Jiang on 2022/11/10.
//  Copyright © 2022 lhc. All rights reserved.
//

import Foundation

extension NSToolbarItem.Identifier {
  static let followButton = NSToolbarItem.Identifier("iina.logWindow.toolbar.followButton")
  static let logLevelButton = NSToolbarItem.Identifier("iina.logWindow.toolbar.logLevelButton")
  static let subsystemButton = NSToolbarItem.Identifier("iina.logWindow.toolbar.subsystemButton")
  static let saveButton = NSToolbarItem.Identifier("iina.logWindow.toolbar.saveButton")
  static let searchField = NSToolbarItem.Identifier("iina.logWindow.toolbar.searchField")
}

final class LogCellView: NSTableCellView {
  override func viewWillDraw() {
    super.viewWillDraw()
    textField?.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
  }
}

class LogWindowController: NSWindowController, NSMenuDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
  let tableView = NSTableView()
  let scrollView = NSScrollView()
  let arrayController = NSArrayController()

  let logLevelMenu = NSMenu()
  let subsystemMenu = NSMenu()

  var following: Bool = false {
    didSet {
      guard let button = toolbarItem(withID: .followButton) else { return }
      let symbolName = following ? "arrow.up.left.circle.fill" : "arrow.up.left.circle"
      button.image = .findSFSymbol([symbolName])
    }
  }
  var filteredLogLevel = Logger.Level.preferred
  var filteredSubsystems: [String] = []
  let searchField = NSSearchField()
  var filterString = ""

  private var scrollEndObserver: NSObjectProtocol?
  private var liveScrollObserver: NSObjectProtocol?
  private var boundsChangeObserver: NSObjectProtocol?

  @objc dynamic var predicate = NSPredicate(value: true)

  convenience init() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Log Viewer"
    window.setFrameAutosaveName("LogWindow")
    self.init(window: window)
  }

  override func showWindow(_ sender: Any?) {
    setupTableView()
    setupArrayController()
    setupToolbar()

    arrayController.addObserver(self, forKeyPath: "arrangedObjects.@count", options: [.new, .prior], context: nil)

    tableView.userInterfaceLayoutDirection = .leftToRight
    tableView.sizeLastColumnToFit()
    let tableViewMenu = NSMenu()
    tableViewMenu.addItem(withTitle: "Copy", action: #selector(menuCopy), keyEquivalent: "")
    tableView.menu = tableViewMenu

    logLevelMenu.addItem(withTitle: "Dummy", action: nil, keyEquivalent: "")
    subsystemMenu.addItem(withTitle: "Dummy", action: nil, keyEquivalent: "")

    for level in Logger.Level.allCases {
      let item = NSMenuItem(title: level.description, action: #selector(logLevelChanged), keyEquivalent: "")
      item.tag = level.rawValue
      item.image = LogWindowController.indicatorIcon(withColor: level.color)
      logLevelMenu.addItem(item)
    }
    subsystemMenu.delegate = self
    updateSubtitle()
    super.showWindow(sender)
  }

  private func setupTableView() {
    guard let contentView = window?.contentView else { return }

    // Table view inside a scroll view
    tableView.style = .inset           // or .plain, .sourceList, .fullWidth
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.allowsMultipleSelection = true
    tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    tableView.delegate = self
    tableView.usesAutomaticRowHeights = true
    tableView.rowSizeStyle = .default
    // Columns
    let levelColumn = NSTableColumn(identifier: .init("level"))
    levelColumn.title = ""
    levelColumn.minWidth = 10
    levelColumn.maxWidth = 10
    tableView.addTableColumn(levelColumn)

    let timestampColumn = NSTableColumn(identifier: .init("timestamp"))
    timestampColumn.title = "Time"
    timestampColumn.minWidth = 90
    timestampColumn.maxWidth = 90
    tableView.addTableColumn(timestampColumn)

    let subsystemColumn = NSTableColumn(identifier: .init("subsystem"))
    subsystemColumn.title = "Subsystem"
    subsystemColumn.minWidth = 150
    subsystemColumn.maxWidth = 150
    tableView.addTableColumn(subsystemColumn)

    let messageColumn = NSTableColumn(identifier: .init("message"))
    messageColumn.title = "Message"
    messageColumn.resizingMask = .autoresizingMask
    tableView.addTableColumn(messageColumn)

    // Scroll view wrapper (NSTableView must live inside one)
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    contentView.addSubview(scrollView)

    NotificationCenter.default.addObserver(self, selector: #selector(checkIfAtBottom),
                                           name: NSScrollView.didLiveScrollNotification, object: scrollView)

    // Pin to all four edges of contentView
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
    ])
  }

  private func setupArrayController() {
    // Bind controller to our entries array
    arrayController.bind(.contentArray, to: Logger.self, withKeyPath: "logs", options: nil)
    arrayController.bind(.filterPredicate, to: self, withKeyPath: "predicate", options: nil)

    // Bind table view's content to array controller's arrangedObjects
    tableView.bind(.content, to: arrayController, withKeyPath: "arrangedObjects", options: nil)
    tableView.bind(.selectionIndexes, to: arrayController, withKeyPath: "selectionIndexes", options: nil)
  }

  private func setupToolbar() {
    let toolbar = NSToolbar(identifier: "iina.logWindow.toolbar")
    toolbar.delegate = self
    toolbar.autosavesConfiguration = true
    toolbar.displayMode = .iconOnly
    window?.toolbar = toolbar
  }

  fileprivate static func indicatorIcon(withColor color: NSColor) -> NSImage {
    return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!.withSymbolConfiguration(.init(scale: .small))!.tinted(color)
  }

  // MARK: - NSToolbarDelegate

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    return [.followButton, .logLevelButton, .subsystemButton, .saveButton, .searchField]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    return [.followButton, .logLevelButton, .subsystemButton, .saveButton, .searchField]
  }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    switch itemIdentifier {
    case .followButton:
      return makeFollowButton()
    case .logLevelButton:
      return makeLogLevelButton()
    case .subsystemButton:
      return makeSubsystemButton()
    case .saveButton:
      return makeSaveButton()
    case .searchField:
      return makeSearchField()
    default:
      return nil
    }
  }

  private func toolbarItem(withID id: NSToolbarItem.Identifier) -> NSToolbarItem? {
    return window?.toolbar?.items.first(where: { $0.itemIdentifier == id })
  }

  // MARK: - Item Factory

  private func makeFollowButton() -> NSToolbarItem {
    let item = NSToolbarItem(itemIdentifier: .followButton)
    item.label = "Follow"
    item.paletteLabel = "Follow latest logs"
    item.toolTip = "Follow latest logs"
    item.image = .findSFSymbol(["arrow.up.left.circle"])
    item.action = #selector(followAction)
    return item
  }

  private func updateLogLevelButtonImage(toolBarItem: NSToolbarItem? = nil) {
    let item = toolBarItem ?? toolbarItem(withID: .logLevelButton)
    if let item {
      item.image = LogWindowController.indicatorIcon(withColor: filteredLogLevel.color).withSymbolConfiguration(.init(scale: .medium))
    }
  }

  private func makeLogLevelButton() -> NSMenuToolbarItem {
    let item = NSMenuToolbarItem(itemIdentifier: .logLevelButton)
    item.label = "Log Level"
    item.paletteLabel = "Log Level"
    item.toolTip = "Log Level"
    item.showsIndicator = true
    item.title = "Log Level"
    item.menu = logLevelMenu
    updateLogLevelButtonImage(toolBarItem: item)
    return item
  }

  private func makeSubsystemButton() -> NSMenuToolbarItem {
    let item = NSMenuToolbarItem(itemIdentifier: .subsystemButton)
    item.label = "Subsystem"
    item.paletteLabel = "Subsystem"
    item.toolTip = "Subsystem"
    item.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Subsystem")!
    item.showsIndicator = true
    item.title = "Subsystem"
    item.menu = subsystemMenu
    return item
  }

  private func makeSaveButton() -> NSToolbarItem {
    let item = NSMenuToolbarItem(itemIdentifier: .saveButton)
    item.label = "Save"
    item.paletteLabel = "Save"
    item.toolTip = "Save"
    item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save")!
    item.action = #selector(save)
    item.menu = NSMenu()
    item.menu.addItem(withTitle: "Save filtered logs...", action: #selector(save), keyEquivalent: "")
    return item
  }

  private func makeSearchField() -> NSSearchToolbarItem {
    let item = NSSearchToolbarItem(itemIdentifier: .searchField)
    item.label = "Filter"
    item.paletteLabel = "Filter"
    item.toolTip = "Filter"
    searchField.placeholderString = "Filter"
    searchField.delegate = self
    item.searchField = searchField
    return item
  }

  // MARK: - NSMenuDelegate

  func menuNeedsUpdate(_ menu: NSMenu) {
    Logger.$subsystems.withLock() { subsystems in
      for (index, subsystem) in subsystems.enumerated() {
        guard !subsystem.added else { continue }
        subsystem.added = true
        let item = NSMenuItem.init(title: subsystem.rawValue, action: #selector(subsystemChanged), keyEquivalent: "")
        item.image = subsystem.image
        menu.insertItem(item, at: index + 1)
      }
    }
  }

  private func updatePredicate() {
    var predicates: [NSPredicate] = []
    if !filteredSubsystems.isEmpty {
      let subsystemPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: filteredSubsystems.map {
          NSPredicate(format: "subsystem == %@", $0)
      })
      predicates.append(subsystemPredicate)
    }
    predicates.append(NSPredicate(format: "level >= %d", filteredLogLevel.rawValue))
    if !filterString.isEmpty {
      predicates.append(NSPredicate(format: "message CONTAINS[c] %@", filterString))
    }
    predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    updateSubtitle()
  }

  func updateSubtitle() {
    if let window {
      var subtitleString = ""
      if filteredSubsystems.isEmpty {
        subtitleString = "All subsystems"
      } else {
        subtitleString = String(describing: filteredSubsystems)
      }
      subtitleString += " - "
      subtitleString += filteredLogLevel.description
      window.subtitle = subtitleString
    }
  }


  private func scrollToBottom() {
    /// macOS couldn't calculate the frame size correctly when the row height is variable and
    /// is not rendered. After the first scroll, all rows should be rendered, which makes the
    /// second frame size correct. Scroll the second time to correctly scroll to the last row.
    tableView.scroll(NSPoint(x: 0, y: tableView.frame.size.height))
    tableView.scroll(NSPoint(x: 0, y: tableView.frame.size.height))
  }

  @objc
  private func checkIfAtBottom() {
    let visibleRect = tableView.visibleRect
    let totalHeight = tableView.bounds.height

    guard totalHeight > visibleRect.height else {
      following = true
      return
    }

    let tolerance: CGFloat = 2.0
    following = visibleRect.maxY >= totalHeight - tolerance
  }

  override func observeValue(
      forKeyPath keyPath: String?,
      of object: Any?,
      change: [NSKeyValueChangeKey: Any]?,
      context: UnsafeMutableRawPointer?
  ) {
    guard keyPath == "arrangedObjects.@count" else { return }

    if change?[.notificationIsPriorKey] as? Bool == true {
      checkIfAtBottom()
    } else if following {
      scrollToBottom()
    }
  }

  @objc func followAction(_ sender: NSToolbarItem) {
    following = true
    scrollToBottom()
  }

  @objc func logLevelChanged(_ sender: NSMenuItem) {
    guard let newLevel = Logger.Level(rawValue: sender.tag) else { return }
    filteredLogLevel = newLevel
    updateLogLevelButtonImage()
    updatePredicate()
  }

  @objc func subsystemChanged(_ sender: NSMenuItem) {
    if let index = filteredSubsystems.firstIndex(of: sender.title) {
      sender.state = .off
      filteredSubsystems.remove(at: index)
    } else {
      sender.state = .on
      filteredSubsystems.append(sender.title)
    }
    updatePredicate()
  }

  func controlTextDidChange(_ notification: Notification) {
    filterString = searchField.stringValue
    updatePredicate()
  }

  @objc func save(_ sender: Any) {
    let saveAll = sender is NSToolbarItem
    let filename = saveAll ? "iina.log" : (window?.subtitle ?? "filtered") + " iina.log"
    Utility.quickSavePanel(title: "Log", filename: filename, sheetWindow: window) { url in
      let content: Any? = saveAll ? self.arrayController.content : self.arrayController.arrangedObjects
      let logs = (content as! [Logger.Log]).map { $0.logString }.joined()
      try? logs.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  // MARK: - Menu actions

  @IBAction func copy(_ sender: Any) {
    menuCopy()
  }

  @objc private func menuCopy()
  {
    let string = (arrayController.selectedObjects as! [Logger.Log]).map { $0.logString }.joined()
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
  }
}

extension LogWindowController: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let column = tableColumn,
          let logs = arrayController.arrangedObjects as? [Logger.Log],
          row < logs.count else { return nil }
    let log = logs[row]

    let columnID = column.identifier.rawValue
    let identifier = NSUserInterfaceItemIdentifier("\(columnID)Cell")

    let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? makeCell(identifier: identifier, columnID: columnID)
    switch columnID {
    case "level":
      cell.imageView?.image = LogWindowController.indicatorIcon(withColor: log.level.color)
    case "timestamp":
      cell.textField?.stringValue = log.date
    case "subsystem":
      cell.textField?.stringValue = log.subsystem
    case "message":
      cell.textField?.stringValue = log.message
    default:
      break
    }
    return cell
  }

  private func makeCell(identifier: NSUserInterfaceItemIdentifier, columnID: String) -> NSTableCellView {
    let cell = LogCellView()
    cell.identifier = identifier

    if columnID == "level" {
      let imageView = NSImageView()
      imageView.translatesAutoresizingMaskIntoConstraints = false
      imageView.imageScaling = .scaleProportionallyDown
      cell.addSubview(imageView)
      cell.imageView = imageView
      NSLayoutConstraint.activate([
        imageView.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
        imageView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
        imageView.widthAnchor.constraint(equalToConstant: 12),
        imageView.heightAnchor.constraint(equalToConstant: 12),
      ])
    } else {
      let textField = NSTextField(wrappingLabelWithString: "")
      textField.translatesAutoresizingMaskIntoConstraints = false

      if columnID == "message" {
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false
        // Resist being compressed vertically; allow horizontal compression so width tracks column
        textField.setContentCompressionResistancePriority(.required, for: .vertical)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      } else {
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
      }

      cell.addSubview(textField)
      cell.textField = textField

      NSLayoutConstraint.activate([
        textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
        textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
        textField.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),
      ])
    }
    return cell
  }
}

@objc(LogLevelTransformer) class LogLevelTransformer: ValueTransformer {
  static override func allowsReverseTransformation() -> Bool {
    return false
  }

  static override func transformedValueClass() -> AnyClass {
    return NSImage.self
  }

  override func transformedValue(_ value: Any?) -> Any? {
    guard let intValue = value as? Int, let level = Logger.Level(rawValue: intValue) else { return nil }
    return LogWindowController.indicatorIcon(withColor: level.color)
  }
}

