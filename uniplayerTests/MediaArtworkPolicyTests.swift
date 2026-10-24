//
//  MediaArtworkPolicyTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

final class MediaArtworkPolicyTests: XCTestCase {

  private func media(rootKind: MediaSourceKind?, url: URL?,
                     presence: MediaPresence = .present) -> CatalogMedia {
    CatalogMedia(
      id: UUID(), rootID: rootKind == nil ? nil : UUID(), directoryID: nil,
      relativePath: url?.lastPathComponent, comparisonKey: nil,
      name: "A.mkv", foldedSearchText: "a.mkv", providerFileID: nil,
      size: nil, modifiedAt: nil, duration: nil, firstDiscoveredAt: Date(),
      presence: presence, hiddenAt: nil, reasons: [.explicit],
      playState: nil, rootDisplayName: nil, rootKind: rootKind, url: url)
  }

  func testLocalReadableFileMayUseThePosterCache() {
    let item = media(rootKind: .local, url: URL(fileURLWithPath: "/tmp/A.mkv"))
    XCTAssertTrue(MediaArtworkPolicy.shouldLoadArtwork(for: item))
  }

  func testMountedShareNeverStartsARemoteProbe() {
    let item = media(rootKind: .mountedSMB, url: URL(fileURLWithPath: "/Volumes/NAS/A.mkv"))
    XCTAssertFalse(MediaArtworkPolicy.shouldLoadArtwork(for: item))
  }

  func testMissingAndLegacyItemsDoNotProbe() {
    let missing = media(rootKind: .local, url: URL(fileURLWithPath: "/tmp/A.mkv"),
                        presence: .missing)
    XCTAssertFalse(MediaArtworkPolicy.shouldLoadArtwork(for: missing))

    let legacy = media(rootKind: nil, url: URL(fileURLWithPath: "/tmp/A.mkv"))
    XCTAssertFalse(MediaArtworkPolicy.shouldLoadArtwork(for: legacy))

    let remote = media(rootKind: nil, url: URL(string: "https://example.com/A.mkv"))
    XCTAssertFalse(MediaArtworkPolicy.shouldLoadArtwork(for: remote))
  }
}
