//
//  LiveTranslationAudioSourceTests.swift
//  UniPlayerTests
//

import AVFoundation
import XCTest
@testable import UniPlayer

final class LiveTranslationAudioSourceTests: XCTestCase {
  private static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
  private static let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
    interleaved: false)!

  /// The reason this source exists: AVFoundation has no Matroska demuxer, so
  /// MKV audio used to be reachable only through the process tap. The FFmpeg
  /// source must decode the same file and hand back recognizer-ready audio.
  func testDecodesMatroskaAudioAVFoundationCannotOpen() async throws {
    try XCTSkipUnless(
      FileManager.default.isExecutableFile(atPath: Self.ffmpeg),
      "FFmpeg is a test dependency")
    let url = try makeMatroska(seconds: 2)

    let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
    XCTAssertEqual(
      tracks?.count ?? 0, 0,
      "AVFoundation opening this MKV would make the FFmpeg fallback unnecessary")

    let source = FFmpegFileAudioSource(
      url: url, targetFormat: Self.targetFormat)
    // A high rate keeps the pacing sleep out of the test's wall clock.
    let stream = try await source.start(at: 0, rate: 1_000)

    var frames = 0
    var peak: Float = 0
    for await frame in stream {
      XCTAssertEqual(frame.buffer.format.sampleRate, 16_000)
      XCTAssertEqual(frame.buffer.format.channelCount, 1)
      peak = max(peak, frame.buffer.rmsLevel)
      frames += 1
    }

    XCTAssertGreaterThan(frames, 0, "the tone should decode into frames")
    XCTAssertGreaterThan(
      peak, 0.01, "a decoded 440 Hz tone must not arrive as silence")
    XCTAssertEqual(source.state, .idle, "end of track is not a failure")
  }

  /// Seeking must move the decode start, or a caption session resumed in the
  /// middle of a film would replay it from the beginning.
  func testSeekingStartsNearTheRequestedPosition() async throws {
    try XCTSkipUnless(
      FileManager.default.isExecutableFile(atPath: Self.ffmpeg),
      "FFmpeg is a test dependency")
    let url = try makeMatroska(seconds: 4)

    let full = FFmpegFileAudioSource(url: url, targetFormat: Self.targetFormat)
    let fullFrames = await countFrames(try await full.start(at: 0, rate: 1_000))

    let tail = FFmpegFileAudioSource(url: url, targetFormat: Self.targetFormat)
    let tailFrames = await countFrames(try await tail.start(at: 3, rate: 1_000))

    XCTAssertGreaterThan(fullFrames, 0)
    XCTAssertGreaterThan(tailFrames, 0)
    XCTAssertLessThan(
      tailFrames, fullFrames,
      "starting three seconds into a four second file must decode less audio")
  }

  /// A file with no audio, or one libavformat cannot open, is a reported
  /// failure rather than an empty stream that looks like silence.
  func testUnreadableFileFailsInsteadOfReturningSilence() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("not-media-\(UUID().uuidString).mkv")
    try Data("this is not a media file".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let source = FFmpegFileAudioSource(
      url: url, targetFormat: Self.targetFormat)
    do {
      _ = try await source.start(at: 0, rate: 1_000)
      XCTFail("a non-media file must not start a capture")
    } catch {
      XCTAssertNotNil(error as? AudioCaptureError)
    }
    guard case .failed = source.state else {
      return XCTFail("the failure must be visible in the source state")
    }
  }

  private func countFrames(_ stream: AsyncStream<AudioFrame>) async -> Int {
    var count = 0
    for await _ in stream { count += 1 }
    return count
  }

  private func makeMatroska(seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("audio-\(UUID().uuidString).mkv")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: Self.ffmpeg)
    process.arguments = [
      "-v", "error",
      "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
      "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=12",
      "-map", "0:a", "-map", "1:v",
      "-c:a", "aac", "-c:v", "libx264", "-pix_fmt", "yuv420p",
      "-t", "\(seconds)", url.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "ffmpeg should build the fixture")
    XCTAssertGreaterThan(
      (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 0)
    return url
  }
}
