//
//  LogWindowController.swift
//  iina
//
//  Created by Yuze Jiang on 2022/11/10.
//  Copyright © 2022 lhc. All rights reserved.
//

import Foundation

fileprivate let colorMap: [Int: NSColor] = [0: .lightGray, 1: .systemGreen, 2: .systemYellow, 3: .systemRed]

extension NSToolbarItem.Identifier {
  static let logLevelButton = NSToolbarItem.Identifier("iina.logWindow.toolbar.logLevelButton")
  static let subsystemButton = NSToolbarItem.Identifier("iina.logWindow.toolbar.subsystemButton")
  static let saveButton = NSToolbarItem.Identifier("iina.logWindow.toolbar.saveButton")
  static let searchField = NSToolbarItem.Identifier("iina.logWindow.toolbar.searchField")
}

class LogWindowController: NSWindowController, NSMenuDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
  override var windowNibName: NSNib.Name {
    return NSNib.Name("LogWindowController")
  }

  @IBOutlet weak var logTableView: NSTableView!
  @IBOutlet var logArrayController: NSArrayController!

  let logLevelMenu = NSMenu()
  let subsystemMenu = NSMenu()
  var filteredLogLevel = Logger.Level.preferred
  var filteredSubsystems: [String] = []
  let searchField = NSSearchField()
  var filterString = ""

  @objc dynamic var logs: [Logger.Log] = []
  @objc dynamic var predicate = NSPredicate(value: true)

  override func windowDidLoad() {
    super.windowDidLoad()
    let toolbar = NSToolbar(identifier: "iina.logWindow.toolbar")
    toolbar.delegate = self
    toolbar.autosavesConfiguration = true
    toolbar.displayMode = .iconOnly
    window?.toolbar = toolbar

    logTableView.userInterfaceLayoutDirection = .leftToRight
    logTableView.sizeLastColumnToFit()
    let tableViewMenu = NSMenu()
    tableViewMenu.addItem(withTitle: "Copy", action: #selector(menuCopy), keyEquivalent: "")
    logTableView.menu = tableViewMenu

    logLevelMenu.addItem(withTitle: "Dummy", action: nil, keyEquivalent: "")
    subsystemMenu.addItem(withTitle: "Dummy", action: nil, keyEquivalent: "")

    for level in Logger.Level.allCases {
      let item = NSMenuItem(title: level.description, action: #selector(logLevelChanged), keyEquivalent: "")
      item.tag = level.rawValue
      item.image = LogWindowController.indicatorIcon(withColor: colorMap[level.rawValue]!)
      logLevelMenu.addItem(item)
    }

    subsystemMenu.delegate = self

    syncLogs()
    updateSubtitle()
  }

  fileprivate static func indicatorIcon(withColor color: NSColor) -> NSImage {
    return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!.withSymbolConfiguration(.init(scale: .small))!.tinted(color)
  }


  // MARK: - NSToolbarDelegate

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    return [.logLevelButton, .subsystemButton, .saveButton, .searchField]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    return [.logLevelButton, .subsystemButton, .saveButton, .searchField]
  }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    switch itemIdentifier {
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

  // MARK: - Item Factory

  private func updateLogLevelButtonImage(toolBarItem: NSToolbarItem? = nil) {
    let item = toolBarItem ?? window?.toolbar?.items.first(where: { $0.itemIdentifier == .logLevelButton })
    if let item {
      item.image = LogWindowController.indicatorIcon(withColor: colorMap[filteredLogLevel.rawValue]!).withSymbolConfiguration(.init(scale: .medium))
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
        menu.insertItem(withTitle: subsystem.rawValue, action: #selector(subsystemChanged), keyEquivalent: "", at: index + 1)
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
      let content: Any? = saveAll ? self.logArrayController.content : self.logArrayController.arrangedObjects
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
    let string = (logArrayController.selectedObjects as! [Logger.Log]).map { $0.logString }.joined()
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
  }

  // MARK: - Logs

  @objc func syncLogs() {
    guard isWindowLoaded else { return }
    Logger.$logs.withLock() { logs in
      guard !logs.isEmpty else { return }
      var scroll = false
      let range = logTableView.rows(in: logTableView.visibleRect)
      if range.location + range.length >= self.logs.count {
        scroll = true
      }

      self.logs.append(contentsOf: logs)
      logs.removeAll()
      if scroll {
        // macOS couldn't calculate the frame size correctly when the row height is variable and
        // is not rendered. After the first scroll, all rows should be rendered, which makes the
        // second frame size correct. Scroll the second time to correctly scroll to the last row.
        logTableView.scroll(NSPoint(x: 0, y: logTableView.frame.size.height))
        logTableView.scroll(NSPoint(x: 0, y: logTableView.frame.size.height))
      }
    }
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
    guard let value = value as? Int else { return nil }
    return LogWindowController.indicatorIcon(withColor: colorMap[value]!)
  }
}

