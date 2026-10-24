//
//  PlaybackStateBridgeTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

final class PlaybackStateBridgeTests: XCTestCase {

  private func media(position: Double, duration: Double) -> CatalogMedia {
    let id = UUID()
    return CatalogMedia(
      id: id, rootID: nil, directoryID: nil, relativePath: nil,
      comparisonKey: nil, name: "A.mkv", foldedSearchText: "a.mkv",
      providerFileID: nil, size: nil, modifiedAt: nil, duration: duration,
      firstDiscoveredAt: Date(), presence: .present, hiddenAt: nil,
      reasons: [.explicit],
      playState: MediaPlayState(
        mediaID: id, observedPosition: position, observedDuration: duration,
        completed: false, manualWatchedOverride: nil,
        lastManualActionAt: nil, lastManualActionKind: nil,
        observedAt: Date(), revision: 1),
      rootDisplayName: "Root", rootKind: .local,
      url: URL(fileURLWithPath: "/tmp/A.mkv"))
  }

  func testCatalogPlanSuppressesWatchLaterAndCarriesPosition() {
    let item = media(position: 42, duration: 100)
    let plan = MediaPlaybackResolver.plan(
      for: item, url: item.url!, intent: .resume, resumePreference: true)
    XCTAssertTrue(plan.suppressWatchLater)
    let arguments = PlaybackEngineOptions.loadfileArguments(path: "/tmp/A.mkv",
                                                           plan: plan)
    XCTAssertEqual(arguments.count, 4)
    XCTAssertTrue(arguments[3].contains("resume-playback=no"))
    XCTAssertTrue(arguments[3].contains("start=42.0"))
  }

  func testLegacyPlanDoesNotSuppressMpvAuthority() {
    let plan = MediaPlaybackResolver.legacyPlan(
      url: URL(fileURLWithPath: "/tmp/A.mkv"), intent: .ordinaryOpen,
      resumePreference: true)
    XCTAssertFalse(plan.suppressWatchLater)
    XCTAssertEqual(PlaybackEngineOptions.loadfileArguments(path: "/tmp/A.mkv",
                                                           plan: plan),
                   ["/tmp/A.mkv"])
  }
}
