//
//  LiveTranslationAudioTests.swift
//  UniPlayerTests
//

import AVFoundation
import XCTest
@testable import UniPlayer

@MainActor
final class LiveTranslationAudioTests: XCTestCase {

  private var temporaryFiles: [URL] = []

  override func tearDown() {
    for url in temporaryFiles {
      try? FileManager.default.removeItem(at: url)
    }
    temporaryFiles = []
    LiveTranslationAudioPermission.shared.reset()
    super.tearDown()
  }

  private func format(
    sampleRate: Double = 16_000,
    channels: AVAudioChannelCount = 1,
    interleaved: Bool = false
  ) -> AVAudioFormat {
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: channels,
      interleaved: interleaved)!
  }

  private func buffer(
    format: AVAudioFormat,
    frames: AVAudioFrameCount,
    value: Float
  ) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    if format.isInterleaved,
       let first = buffer.audioBufferList.pointee.mBuffers.mData?
        .assumingMemoryBound(to: Float.self) {
      // Interleaved buffers share one flat allocation; the channel pointers do
      // not describe that layout.
      let count = Int(frames) * Int(format.channelCount)
      for index in 0..<count {
        first[index] = value
      }
    } else if let channels = buffer.floatChannelData {
      for channel in 0..<Int(format.channelCount) {
        for index in 0..<Int(frames) {
          channels[channel][index] = value
        }
      }
    } else if let first = buffer.audioBufferList.pointee.mBuffers.mData?
      .assumingMemoryBound(to: Float.self) {
      let count = Int(frames) * Int(format.channelCount)
      for index in 0..<count {
        first[index] = value
      }
    }
    return buffer
  }

  private func sine(
    format: AVAudioFormat,
    frames: AVAudioFrameCount,
    frequency: Double = 440
  ) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    guard let channels = buffer.floatChannelData else { return buffer }
    for channel in 0..<Int(format.channelCount) {
      for index in 0..<Int(frames) {
        channels[channel][index] = Float(
          sin(2 * .pi * frequency * Double(index) / format.sampleRate)) * 0.5
      }
    }
    return buffer
  }

  // MARK: - Silence

  func testSilenceDetectorTripsAfterTheRequiredDuration() {
    var detector = AudioSilenceDetector()
    let format = format()
    // 8,000 frames at 16 kHz is half a second; the detector requires five
    // seconds of exact digital silence.
    for _ in 0..<9 {
      XCTAssertFalse(detector.observe(
        buffer(format: format, frames: 8_000, value: 0)))
    }
    XCTAssertTrue(detector.observe(
      buffer(format: format, frames: 8_000, value: 0)))
    XCTAssertTrue(detector.hasTripped)
  }

  func testSilenceDetectorDoesNotTripOnQuietSignal() {
    var detector = AudioSilenceDetector()
    let format = format()
    for _ in 0..<20 {
      XCTAssertFalse(detector.observe(
        buffer(format: format, frames: 8_000, value: 0.0001)))
    }
    XCTAssertFalse(detector.hasTripped)
  }

  func testSilenceDetectorResetsOnSignal() {
    var detector = AudioSilenceDetector()
    let format = format()
    XCTAssertFalse(detector.observe(buffer(format: format, frames: 8_000, value: 0)))
    XCTAssertFalse(detector.observe(buffer(format: format, frames: 8_000, value: 0.2)))
    XCTAssertFalse(detector.observe(buffer(format: format, frames: 4_000, value: 0)))
    XCTAssertFalse(detector.hasTripped)
  }

  func testSilenceDetectorHandlesInterleavedStereo() {
    var detector = AudioSilenceDetector()
    let format = format(channels: 2, interleaved: true)
    XCTAssertFalse(detector.observe(buffer(format: format, frames: 8_000, value: 0.3)))
    XCTAssertGreaterThan(
      buffer(format: format, frames: 100, value: 0.3).rmsLevel, 0.2)
  }

  func testPlanarStereoRMSUsesTheChannelStride() {
    let format = format(channels: 2, interleaved: false)
    let pcm = buffer(format: format, frames: 1_000, value: 0.25)
    XCTAssertEqual(pcm.rmsLevel, 0.25, accuracy: 0.001)
  }

  // MARK: - Format conversion

  func testConverterDownsamplesStereoToMono() throws {
    let inputFormat = format(sampleRate: 48_000, channels: 2)
    let outputFormat = format(sampleRate: 16_000, channels: 1)
    let converter = try XCTUnwrap(
      AudioBufferConverter(inputFormat: inputFormat, outputFormat: outputFormat))
    let input = sine(format: inputFormat, frames: 48_000)
    let output = try converter.convert(input)

    XCTAssertEqual(output.format.sampleRate, 16_000)
    XCTAssertEqual(output.format.channelCount, 1)
    XCTAssertEqual(Double(output.frameLength), 16_000, accuracy: 4)
    XCTAssertGreaterThan(output.rmsLevel, 0.2)
  }

  func testConverterKeepsTheSameFormat() throws {
    let format = format()
    let converter = try XCTUnwrap(
      AudioBufferConverter(inputFormat: format, outputFormat: format))
    let input = sine(format: format, frames: 1_600)
    let output = try converter.convert(input)
    XCTAssertEqual(output.frameLength, input.frameLength)
    XCTAssertGreaterThan(output.rmsLevel, 0.2)
  }

  // MARK: - Ring buffer

  func testRingBufferPreservesOrderAndWraps() {
    let ring = AudioRingBuffer(capacity: 8)
    let first: [Float] = [1, 2, 3, 4, 5]
    first.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }

    var output = [Float](repeating: 0, count: 3)
    output.withUnsafeMutableBufferPointer { pointer in
      XCTAssertEqual(ring.read(into: pointer.baseAddress!, count: 3), 3)
    }
    XCTAssertEqual(output, [1, 2, 3])

    let second: [Float] = [6, 7, 8, 9]
    second.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }

    output = [Float](repeating: 0, count: 6)
    output.withUnsafeMutableBufferPointer { pointer in
      XCTAssertEqual(ring.read(into: pointer.baseAddress!, count: 6), 6)
    }
    XCTAssertEqual(output, [4, 5, 6, 7, 8, 9])
  }

  func testRingBufferDropsTheIncomingBlockWhenFull() {
    let ring = AudioRingBuffer(capacity: 4)
    let first: [Float] = [1, 2, 3, 4]
    first.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
    let second: [Float] = [5, 6]
    second.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
    XCTAssertEqual(ring.available, 4)

    var output = [Float](repeating: 0, count: 4)
    output.withUnsafeMutableBufferPointer { pointer in
      XCTAssertEqual(ring.read(into: pointer.baseAddress!, count: 4), 4)
    }
    XCTAssertEqual(output, [1, 2, 3, 4])
  }

  // MARK: - Permission state

  func testPermissionStateTransitions() {
    let permission = LiveTranslationAudioPermission.shared
    XCTAssertEqual(permission.state, .unknown)
    permission.update(.granted)
    XCTAssertEqual(permission.state, .granted)
    permission.update(.denied)
    XCTAssertEqual(permission.state, .denied)
    permission.reset()
    XCTAssertEqual(permission.state, .unknown)
  }

  // MARK: - File source

  private func writeTone(to url: URL, format: AVAudioFormat) throws {
    let file = try AVAudioFile(
      forWriting: url, settings: format.settings,
      commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: sine(format: format, frames: 48_000))
  }

  func testFileSourceDeliversPCMAndStops() async throws {
    let inputFormat = format(sampleRate: 48_000, channels: 1)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translation-\(UUID().uuidString).wav")
    temporaryFiles.append(url)
    try writeTone(to: url, format: inputFormat)

    let source = FileAudioSource(
      url: url, targetFormat: format(sampleRate: 16_000, channels: 1))
    let stream = try await source.start()
    var iterator = stream.makeAsyncIterator()
    let frame = await iterator.next()

    XCTAssertNotNil(frame)
    XCTAssertEqual(frame?.buffer.format.sampleRate, 16_000)
    XCTAssertEqual(frame?.buffer.format.channelCount, 1)
    XCTAssertGreaterThan(frame?.buffer.frameLength ?? 0, 0)
    source.stop()
    XCTAssertEqual(source.state, .idle)
  }

  func testFileSourceRejectsAFileWithoutAudio() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translation-\(UUID().uuidString).txt")
    temporaryFiles.append(url)
    try Data("not audio".utf8).write(to: url)

    let source = FileAudioSource(url: url, targetFormat: format())
    do {
      _ = try await source.start()
      XCTFail("expected a missing audio track")
    } catch AudioCaptureError.noAudioTrack {
      // Expected.
    } catch {
      // AVFoundation may reject the asset before it can report a missing
      // track; either failure is honest.
    }
  }
}
