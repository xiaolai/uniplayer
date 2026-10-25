//
//  SettingsModeTests.swift
//  UniPlayerTests
//

import XCTest
@testable import UniPlayer

final class SettingsModeTests: XCTestCase {
  private var savedMode: String?
  private var savedEntries: [SettingsSearch.Entry] = []

  override func setUp() {
    savedMode = UserDefaults.standard.string(forKey: SettingsMode.defaultsKey)
    UserDefaults.standard.removeObject(forKey: SettingsMode.defaultsKey)
    savedEntries = SettingsSearch.entries
    SettingsSearch.entries.removeAll()
  }

  override func tearDown() {
    SettingsSearch.entries = savedEntries
    if let savedMode {
      UserDefaults.standard.set(savedMode, forKey: SettingsMode.defaultsKey)
    } else {
      UserDefaults.standard.removeObject(forKey: SettingsMode.defaultsKey)
    }
  }

  func testDefaultModeIsAdvanced() {
    XCTAssertEqual(SettingsMode.current, .advanced)
  }

  func testModePersists() {
    SettingsMode.current = .simple
    XCTAssertEqual(SettingsMode.current, .simple)
  }

  func testPageAvailability() {
    let simplePages = SettingsWindow.makePages().filter(\.availableInSimpleMode).map(\.identifier)
    XCTAssertEqual(simplePages, [
      "general", "ui", "video", "audio", "subtitles", "liveTranslation", "assistant",
    ])
    for identifier in ["network", "control", "key.bindings", "plugin", "utilities", "advanced"] {
      let page = SettingsWindow.makePages().first { $0.identifier == identifier }
      XCTAssertEqual(page?.availableInSimpleMode, false, identifier)
    }
  }

  func testSidebarLayoutCoversEveryPageInOrder() {
    let pages = SettingsWindow.makePages()
    let allIdentifiers = pages.map(\.identifier)
    let advanced = SettingsSidebarLayout.groups(for: .advanced).flatMap(\.identifiers)
    XCTAssertEqual(advanced, allIdentifiers)

    let simple = SettingsSidebarLayout.groups(for: .simple).flatMap(\.identifiers)
    XCTAssertEqual(simple, pages.filter(\.availableInSimpleMode).map(\.identifier))
    XCTAssertEqual(SettingsSidebarLayout.groups(for: .simple).map(\.title), ["Playback", "Intelligence"])
  }

  func testEverySimplePageHasVisibleSections() {
    SettingsMode.current = .simple
    for page in SettingsWindow.makePages().filter(\.availableInSimpleMode) {
      XCTAssertTrue(page.builtSections.contains { $0.isVisible(in: .simple) }, page.identifier)
    }
  }

  func testSimpleModeHidesAdvancedSections() {
    let identifiers: Set<String> = ["ui", "video", "audio", "subtitles", "assistant", "liveTranslation"]
    let pages = SettingsWindow.makePages().filter { identifiers.contains($0.identifier) }

    SettingsMode.current = .advanced
    let advancedSections = Dictionary(uniqueKeysWithValues: pages.map {
      ($0.identifier, $0.builtSections.filter { $0.isVisible(in: .advanced) }.count)
    })
    SettingsMode.current = .simple
    let simpleSections = Dictionary(uniqueKeysWithValues: pages.map {
      ($0.identifier, $0.builtSections.filter { $0.isVisible(in: .simple) }.count)
    })

    XCTAssertEqual(simpleSections["ui"], advancedSections["ui"].map { $0 - 2 })
    XCTAssertEqual(simpleSections["video"], 1)
    XCTAssertEqual(simpleSections["audio"], advancedSections["audio"])
    XCTAssertEqual(simpleSections["subtitles"], advancedSections["subtitles"].map { $0 - 3 })
    XCTAssertEqual(simpleSections["assistant"], advancedSections["assistant"])
    XCTAssertEqual(simpleSections["liveTranslation"], advancedSections["liveTranslation"])
  }

  func testSearchEntriesFromHiddenPagesAreAdvancedOnly() {
    SettingsPageNetwork().registerSearchEntries()
    XCTAssertFalse(SettingsSearch.entries.isEmpty)
    XCTAssertTrue(SettingsSearch.entries.allSatisfy(\.advancedOnly))

    SettingsSearch.entries.removeAll()
    SettingsPageVideo().registerSearchEntries()
    XCTAssertTrue(SettingsSearch.entries.contains { $0.section == "Decoding" && !$0.advancedOnly })
    XCTAssertTrue(SettingsSearch.entries.contains { $0.section == "Live Text" && $0.advancedOnly })
  }

  func testLastPageKeysArePerMode() {
    XCTAssertNotEqual(SettingsMode.simple.lastPageKey, SettingsMode.advanced.lastPageKey)
  }

  func testSectionVisibilityFiltersProtocolTypedChildren() {
    let advancedSection = SettingsSection(
      spacing: 0,
      [SettingsList([SettingsItem.General().onlyInAdvanced()])])
    XCTAssertFalse(advancedSection.isVisible(in: .simple))
    XCTAssertTrue(advancedSection.isVisible(in: .advanced))

    let emptySection = SettingsSection(spacing: 0, [SettingsList([])])
    XCTAssertFalse(emptySection.isVisible(in: .simple))
  }

  func testExpandedDetailRemainsExpandedAfterRebuild() {
    let item = SettingsItem.General()
    item.withExpandingDetailView(SettingsItem.General())
    _ = item.makeView()
    item.toggleExpandable(true, animated: false)
    XCTAssertTrue(item.isExpanded)

    _ = item.makeView()

    XCTAssertEqual(item.disclosureButton.state, .on)
    XCTAssertEqual(item.renderedDetailView?.alphaValue, 1)
    guard let detail = item.renderedDetailView else {
      return XCTFail("Expected a rendered detail view")
    }
    XCTAssertEqual(item.expandingStackView?.visibilityPriority(for: detail), .mustHold)
  }

  func testLanguageSelectorAddsDescriptionOnce() {
    let selector = SettingsAccessory.LanguageSelector()
      .bind(to: .subTextFont)
      .hasDescription()
    _ = selector.makeView()
    _ = selector.makeView()

    let labels = descendants(of: selector.view)
      .compactMap { $0 as? NSTextField }
      .filter { !($0 is LanguageTokenField) }
    XCTAssertEqual(labels.count, 1)
  }

  func testASSSelectionVisibilitySurvivesRebuild() {
    let accessory = SubtitlesASSView()
    _ = accessory.makeView()
    accessory.segmentControl.selectedSegment = 1
    accessory.subOverrideLevelSegmentedControlAction(accessory.segmentControl)

    _ = accessory.makeView()

    guard let stack = accessory.view.subviews.compactMap({ $0 as? NSStackView }).first,
          stack.arrangedSubviews.count == 2 else {
      return XCTFail("Expected the ASS accessory to keep two selections")
    }
    XCTAssertEqual(stack.visibilityPriority(for: stack.arrangedSubviews[0]), .notVisible)
    XCTAssertEqual(stack.visibilityPriority(for: stack.arrangedSubviews[1]), .mustHold)
  }

  func testHiddenPageNavigationSwitchesToAdvanced() {
    SettingsMode.current = .simple
    let window = SettingsWindow([
      StubSettingsPage(identifier: "video"),
      StubSettingsPage(identifier: "plugin", availableInSimpleMode: false),
    ])
    defer { window.close() }

    XCTAssertEqual(window.mode, .simple)
    window.navigateTo(page: "plugin")
    XCTAssertEqual(window.mode, .advanced)
    XCTAssertEqual(window.title, "plugin")
  }

  func testAdvancedSearchEntrySwitchesModeWithinVisiblePage() {
    SettingsMode.current = .simple
    let window = SettingsWindow([StubSettingsPage(identifier: "video")])
    defer { window.close() }

    window.navigateTo(page: "video", advancedEntry: true)

    XCTAssertEqual(window.mode, .advanced)
    XCTAssertEqual(window.title, "video")
  }

  func testAdvancedNavigationKeepsOutgoingModeLastPage() {
    let key = SettingsMode.simple.lastPageKey
    let saved = UserDefaults.standard.string(forKey: key)
    defer {
      if let saved {
        UserDefaults.standard.set(saved, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }

    SettingsMode.current = .simple
    UserDefaults.standard.set("video", forKey: key)
    let window = SettingsWindow([
      StubSettingsPage(identifier: "video"),
      StubSettingsPage(identifier: "network", availableInSimpleMode: false),
    ])
    defer { window.close() }

    window.navigateTo(page: "network")

    XCTAssertEqual(window.mode, .advanced)
    XCTAssertEqual(UserDefaults.standard.string(forKey: key), "video")
  }

  private func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants(of:))
  }
}

private final class StubSettingsPage: SettingsPage {
  private let pageID: String
  private let simpleMode: Bool

  init(identifier: String, availableInSimpleMode: Bool = true) {
    self.pageID = identifier
    self.simpleMode = availableInSimpleMode
    super.init()
  }

  override var identifier: String { pageID }
  override var title: String { pageID }
  override var availableInSimpleMode: Bool { simpleMode }
}
