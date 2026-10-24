//
//  PlaybackLoadPlanTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

final class PlaybackLoadPlanTests: XCTestCase {

  private let url = URL(fileURLWithPath: "/tmp/Test.mkv")

  private func media(position: Double, duration: Double,
                     completed: Bool = false,
                     manualWatched: Bool? = nil) -> CatalogMedia {
    let id = UUID()
    return CatalogMedia(
      id: id,
      rootID: nil,
      directoryID: nil,
      relativePath: nil,
      comparisonKey: nil,
      name: "Test.mkv",
      foldedSearchText: "test.mkv",
      providerFileID: nil,
      size: nil,
      modifiedAt: nil,
      duration: duration,
      firstDiscoveredAt: Date(),
      presence: .present,
      hiddenAt: nil,
      reasons: [.explicit],
      playState: MediaPlayState(
        mediaID: id, observedPosition: position, observedDuration: duration,
        completed: completed, manualWatchedOverride: manualWatched,
        lastManualActionAt: manualWatched == nil ? nil : Date(),
        lastManualActionKind: manualWatched == nil ? nil : .watched,
        observedAt: Date(), revision: 1),
      rootDisplayName: nil,
      rootKind: nil,
      url: url)
  }

  func testOrdinaryOpenUsesPositionOnlyWhenResumePreferenceIsOn() {
    let item = media(position: 40, duration: 100)
    let on = MediaPlaybackResolver.plan(for: item, url: url,
                                        intent: .ordinaryOpen, resumePreference: true)
    XCTAssertEqual(on.startPosition, 40)
    XCTAssertTrue(on.suppressWatchLater)
    XCTAssertEqual(on.mediaID, item.id)

    let off = MediaPlaybackResolver.plan(for: item, url: url,
                                         intent: .ordinaryOpen, resumePreference: false)
    XCTAssertEqual(off.startPosition, 0)
  }

  func testCompletedAndManuallyWatchedItemsStartAtZero() {
    let completed = media(position: 99, duration: 100, completed: true)
    let plan = MediaPlaybackResolver.plan(for: completed, url: url,
                                          intent: .ordinaryOpen, resumePreference: true)
    XCTAssertEqual(plan.startPosition, 0)

    let watched = media(position: 20, duration: 100, manualWatched: true)
    let watchedPlan = MediaPlaybackResolver.plan(for: watched, url: url,
                                                 intent: .ordinaryOpen, resumePreference: true)
    XCTAssertEqual(watchedPlan.startPosition, 0)
  }

  func testExplicitResumeAndBeginningDiffer() {
    let item = media(position: 40, duration: 100)
    let resume = MediaPlaybackResolver.plan(for: item, url: url,
                                            intent: .resume, resumePreference: false)
    XCTAssertEqual(resume.startPosition, 40)

    let beginning = MediaPlaybackResolver.plan(for: item, url: url,
                                               intent: .fromBeginning,
                                               resumePreference: true)
    XCTAssertEqual(beginning.startPosition, 0)
  }

  func testLegacyURLKeepsMpvAuthority() {
    let plan = MediaPlaybackResolver.legacyPlan(url: url, intent: .ordinaryOpen,
                                                resumePreference: true)
    XCTAssertNil(plan.mediaID)
    XCTAssertFalse(plan.suppressWatchLater)
    XCTAssertEqual(plan.startPosition, 0)
  }

  func testNaturalCompletionIsTreatedAsFinished() {
    let item = media(position: 97.5, duration: 100)
    XCTAssertTrue(item.isFinished)
    let plan = MediaPlaybackResolver.plan(for: item, url: url,
                                          intent: .ordinaryOpen, resumePreference: true)
    XCTAssertEqual(plan.startPosition, 0)
  }

  func testLoadfileArgumentsCarryTheSingleAuthority() {
    let item = media(position: 40, duration: 100)
    let plan = MediaPlaybackResolver.plan(for: item, url: url,
                                          intent: .resume, resumePreference: true)
    let arguments = PlaybackEngineOptions.loadfileArguments(path: "/tmp/Test.mkv",
                                                           plan: plan)
    XCTAssertEqual(arguments.count, 4)
    XCTAssertEqual(arguments[0], "/tmp/Test.mkv")
    XCTAssertEqual(arguments[1], "replace")
    XCTAssertTrue(arguments[3].contains("resume-playback=no"))
    XCTAssertTrue(arguments[3].contains("start=40.0"))

    let legacy = MediaPlaybackResolver.legacyPlan(url: url, intent: .ordinaryOpen,
                                                  resumePreference: true)
    XCTAssertEqual(PlaybackEngineOptions.loadfileArguments(path: "/tmp/Test.mkv",
                                                           plan: legacy),
                   ["/tmp/Test.mkv"])
  }
}
