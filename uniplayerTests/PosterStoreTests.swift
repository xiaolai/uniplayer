//
//  PosterStoreTests.swift
//  UniPlayerTests
//

import XCTest
@testable import UniPlayer

@MainActor
final class PosterStoreTests: XCTestCase {
  /// AVFoundation and Quick Look do not decode MKV; the poster must come from
  /// the bundled FFmpeg frame extractor instead of an endless Quick Look wait.
  func testMKVPosterUsesTheFFmpegFallback() async throws {
    let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: ffmpeg),
                      "FFmpeg is a test dependency")

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("poster-\(UUID().uuidString).mkv")
    defer { try? FileManager.default.removeItem(at: url) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = [
      "-v", "error", "-f", "lavfi",
      "-i", "testsrc2=size=320x240:rate=24", "-t", "2",
      "-c:v", "libx264", "-pix_fmt", "yuv420p", url.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertGreaterThan((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 0)

    let image = await PosterStore.shared.image(for: url)
    XCTAssertNotNil(image, "an MKV should fall through to the FFmpeg frame extractor")
  }
}
