//
//  SettingsWindowTests.swift
//  UniPlayerTests
//

import XCTest
@testable import UniPlayer

@MainActor
final class SettingsWindowTests: XCTestCase {
  func testEscapeClosesTheSettingsWindow() {
    let window = SettingsWindow.default
    window.orderFront(nil)
    XCTAssertTrue(window.isVisible)
    window.cancelOperation(nil)
    XCTAssertFalse(window.isVisible)
  }

  func testEscapeKeyClosesTheSettingsWindow() throws {
    let window = SettingsWindow.default
    window.orderFront(nil)
    XCTAssertTrue(window.isVisible)
    let event = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil,
      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
      isARepeat: false, keyCode: 53))
    window.keyDown(with: event)
    XCTAssertFalse(window.isVisible)
  }
}
