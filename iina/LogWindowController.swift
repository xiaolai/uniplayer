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

fileprivate let textFieldHorizontalPadding: CGFloat = 4
fileprivate let textFieldVerticalPadding: CGFloat = 2

fileprivate let logFont = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

fileprivate func indicatorIcon(withColor color: NSColor) -> NSImage {
  return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!.withSymbolConfiguration(.init(scale: .small))!.tinted(color)
}

// Used to measure the row height of the multi-line text label
fileprivate let sizingTextField: NSTextField = {
  let tf = NSTextField(labelWithString: "")
  tf.maximumNumberOfLines = 0
  tf.lineBreakMode = .byWordWrapping
  tf.cell?.wraps = true
  tf.cell?.isScrollable = false
  tf.font = logFont
  return tf
}()

class LogWindowController: NSWindowController, NSMenuDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
  private let tableView = NSTableView()
  private var rowHeightCache: [Int: CGFloat] = [:]
  private var cachedColumnWidth: CGFloat = 0
  private let scrollView = NSScrollView()
  private let arrayController = NSArrayController()

  private let logLevelMenu = NSMenu()
  private let subsystemMenu = NSMenu()

  private var following: Bool = false {
    didSet {
      guard let button = toolbarItem(withID: .followButton) else { return }
      let symbolName = following ? "arrow.up.left.circle.fill" : "arrow.up.left.circle"
      button.image = .findSFSymbol([symbolName])
    }
  }
  private var filteredLogLevel = Logger.Level.preferred {
    didSet {
      updatePredicate()
    }
  }
  private var filteredSubsystems = Set<String>() {
    didSet {
      updatePredicate()
    }
  }
  private let searchField = NSSearchField()
  private var filterString = ""

  @objc private dynamic var predicate = NSPredicate(value: false) {
    didSet {
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
  }

  private var hasSetup = false

  convenience init() {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: NSSize(width: 800, height: 500)),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Log Viewer"
    self.init(window: window)
    self.windowFrameAutosaveName = "LogWindow"
  }

  override func showWindow(_ sender: Any?) {
    if !hasSetup {
      setupTableView()

      arrayController.bind(.contentArray, to: Logger.self, withKeyPath: "logs", options: nil)
      arrayController.bind(.filterPredicate, to: self, withKeyPath: "predicate", options: nil)
      arrayController.addObserver(self, forKeyPath: "arrangedObjects.@count", options: [.new, .prior], context: nil)
      tableView.bind(.content, to: arrayController, withKeyPath: "arrangedObjects", options: nil)
      tableView.bind(.selectionIndexes, to: arrayController, withKeyPath: "selectionIndexes", options: nil)

      let toolbar = NSToolbar(identifier: "iina.logWindow.toolbar")
      toolbar.delegate = self
      toolbar.autosavesConfiguration = true
      toolbar.displayMode = .iconOnly
      window?.toolbar = toolbar

      logLevelMenu.addItem(withTitle: "Dummy", action: nil, keyEquivalent: "")
      subsystemMenu.addItem(withTitle: "Dummy", action: nil, keyEquivalent: "")

      for level in Logger.Level.allCases {
        let item = NSMenuItem(title: level.description, action: #selector(logLevelChanged), keyEquivalent: "")
        item.tag = level.rawValue
        item.image = indicatorIcon(withColor: level.color)
        logLevelMenu.addItem(item)
      }
      subsystemMenu.delegate = self

      // to update the subtitle
      predicate = NSPredicate(value: true)

      hasSetup = true
    }

    super.showWindow(sender)
  }

  private func setupTableView() {
    guard let contentView = window?.contentView else { return }

    tableView.delegate = self
    tableView.style = .inset
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.userInterfaceLayoutDirection = .leftToRight
    tableView.allowsMultipleSelection = true
    tableView.allowsColumnReordering = false
    tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

    let tableViewMenu = NSMenu()
    tableViewMenu.addItem(withTitle: "Copy", action: #selector(menuCopy), keyEquivalent: "")
    tableView.menu = tableViewMenu

    func makeColumn(name: String, width: CGFloat? = nil, noTitle: Bool = false) -> NSTableColumn {
      let column = NSTableColumn(identifier: .init(name.lowercased()))
      column.title = noTitle ? "" : name
      if let width {
        column.minWidth = width
        column.maxWidth = width
      }
      return column
    }

    tableView.addTableColumn(makeColumn(name: "Level", width: 10, noTitle: true))
    tableView.addTableColumn(makeColumn(name: "Time", width: 90))
    tableView.addTableColumn(makeColumn(name: "Subsystem", width: 150))
    tableView.addTableColumn(makeColumn(name: "Message"))

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(scrollView)

    NotificationCenter.default.addObserver(self, selector: #selector(checkIfAtBottom),
                                           name: NSScrollView.didLiveScrollNotification, object: scrollView)
    NotificationCenter.default.addObserver(self, selector: #selector(columnDidResize),
                                           name: NSTableView.columnDidResizeNotification, object: tableView)

    scrollView.padding(.all)
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
    item.menu.addItem(withTitle: "Save filtered logs…", action: #selector(save), keyEquivalent: "")
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
  }

  private func updateLogLevelButtonImage(toolBarItem: NSToolbarItem? = nil) {
    let item = toolBarItem ?? toolbarItem(withID: .logLevelButton)
    if let item {
      item.image = indicatorIcon(withColor: filteredLogLevel.color).withSymbolConfiguration(.init(scale: .medium))
    }
  }

  private func scrollToBottom() {
    /// macOS couldn't calculate the frame size correctly when the row height is variable and
    /// is not rendered. After the first scroll, all rows should be rendered, which makes the
    /// second frame size correct. Scroll the second time to correctly scroll to the last row.
    tableView.scroll(NSPoint(x: 0, y: tableView.frame.size.height))
    tableView.scroll(NSPoint(x: 0, y: tableView.frame.size.height))
  }

  @objc private func checkIfAtBottom() {
    let visibleRect = tableView.visibleRect
    let totalHeight = tableView.bounds.height

    guard totalHeight > visibleRect.height else {
      following = true
      return
    }

    let tolerance: CGFloat = 2.0
    following = visibleRect.maxY >= totalHeight - tolerance
  }

  @objc private func followAction(_ sender: NSToolbarItem) {
    following = true
    scrollToBottom()
  }

  @objc private func logLevelChanged(_ sender: NSMenuItem) {
    guard let newLevel = Logger.Level(rawValue: sender.tag) else { return }
    filteredLogLevel = newLevel
    updateLogLevelButtonImage()
  }

  @objc private func subsystemChanged(_ sender: NSMenuItem) {
    if filteredSubsystems.contains(sender.title) {
      sender.state = .off
      filteredSubsystems.remove(sender.title)
    } else {
      sender.state = .on
      filteredSubsystems.insert(sender.title)
    }
  }

  @objc private func save(_ sender: Any) {
    let saveAll = sender is NSToolbarItem
    let filename = saveAll ? "iina.log" : (window?.subtitle ?? "filtered") + " iina.log"
    Utility.quickSavePanel(title: "Log", filename: filename, sheetWindow: window) { url in
      let content: Any? = saveAll ? self.arrayController.content : self.arrayController.arrangedObjects
      let logs = (content as! [Logger.Log]).map { $0.logString }.joined()
      try? logs.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                             change: [NSKeyValueChangeKey: Any]?,
                             context: UnsafeMutableRawPointer?) {
    guard keyPath == "arrangedObjects.@count" else { return }

    if change?[.notificationIsPriorKey] as? Bool == true {
      checkIfAtBottom()
    } else if following {
      scrollToBottom()
    }
  }

  func controlTextDidChange(_ notification: Notification) {
    filterString = searchField.stringValue
    updatePredicate()
  }

  // MARK: - Menu actions

  @IBAction func copy(_ sender: Any) {
    menuCopy()
  }

  @objc private func menuCopy() {
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
      cell.imageView?.image = indicatorIcon(withColor: log.level.color)
    case "time":
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

  func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
    return false
  }

  private func makeCell(identifier: NSUserInterfaceItemIdentifier, columnID: String) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier

    if columnID == "level" {
      let imageView = NSImageView()
      imageView.translatesAutoresizingMaskIntoConstraints = false
      imageView.imageScaling = .scaleProportionallyDown
      cell.addSubview(imageView)
      cell.imageView = imageView
      imageView.size(width: 12, height: 12)
      imageView.padding(ALConstraint.top(2.5))
      imageView.center(x: true)
    } else {
      let textField = NSTextField(labelWithString: "")
      textField.font = logFont
      textField.translatesAutoresizingMaskIntoConstraints = false

      if columnID == "message" {
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.cell?.isScrollable = false
      } else {
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
      }

      cell.addSubview(textField)
      cell.textField = textField

      textField.padding(.vertical(textFieldVerticalPadding), .horizontal(textFieldHorizontalPadding))
    }
    return cell
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    let columnWidth = tableView.tableColumns[3].width
    if columnWidth != cachedColumnWidth {
      cachedColumnWidth = columnWidth
      rowHeightCache.removeAll(keepingCapacity: true)
    }

    if let cached = rowHeightCache[row] {
      return cached
    }

    let availableWidth = columnWidth - textFieldHorizontalPadding * 2

    let message = (arrayController.arrangedObjects as! [Logger.Log])[row].message.trimmingCharacters(in: .newlines)
    sizingTextField.stringValue = message
    sizingTextField.preferredMaxLayoutWidth = availableWidth

    let textHeight = sizingTextField.intrinsicContentSize.height
    let rowHeight = textHeight + textFieldVerticalPadding * 2

    rowHeightCache[row] = rowHeight
    return rowHeight
  }

  @objc private func columnDidResize() {
    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
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
    return indicatorIcon(withColor: level.color)
  }
}

