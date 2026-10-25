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
}
