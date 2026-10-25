//
//  SubtitleExtensionTests.swift
//  UniPlayerTests
//

import XCTest
@testable import UniPlayer

final class SubtitleExtensionTests: XCTestCase {
  func testJavaScriptIsNotASubtitleExtension() {
    XCTAssertFalse(Utility.supportedFileExt[.sub]!.contains("js"))
    XCTAssertNil(Utility.mediaType(forExtension: "js"))
  }

  func testCommonSubtitleExtensionsStillMapToSubtitles() {
    for ext in ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup", "smi", "lrc", "jss"] {
      XCTAssertEqual(Utility.mediaType(forExtension: ext), .sub, ext)
    }
  }
}
