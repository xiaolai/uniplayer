//
//  LiveTranslationAudio.swift
//  uniplayer
//
//  The audio seam for live translation. Sources deliver float PCM frames;
//  silence is a permission signal, not an error, because a denied process
//  tap returns zeroes instead of failing.
//

import AVFoundation
import Foundation

enum AudioCaptureState: Equatable {
  case idle
  case starting
  case running
  case permissionDenied
  case failed(String)
}

struct AudioFrame {
  let buffer: AVAudioPCMBuffer
  let time: AVAudioTime?
}

enum AudioCaptureError: LocalizedError, Equatable {
  case alreadyRunning
  case unsupportedFormat
  case noAudioTrack
  case processObjectUnavailable
  case tapCreationFailed(OSStatus)
  case aggregateDeviceFailed(OSStatus)
  case tapListFailed(OSStatus)
  case streamFormatFailed(OSStatus)
  case deviceStartFailed(OSStatus)
  case readerFailed(String)

  var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      return NSLocalizedString(
        "Audio capture is already running.", comment: "Live translation audio error")
    case .unsupportedFormat:
      return NSLocalizedString(
        "The audio format is not supported.", comment: "Live translation audio error")
    case .noAudioTrack:
      return NSLocalizedString(
        "This file has no audio track.", comment: "Live translation audio error")
    case .processObjectUnavailable:
      return NSLocalizedString(
        "The audio process could not be found.", comment: "Live translation audio error")
    case .tapCreationFailed(let status):
      return String(format: NSLocalizedString(
        "System audio capture could not start (error %d).",
        comment: "Live translation audio error"), status)
    case .aggregateDeviceFailed(let status):
      return String(format: NSLocalizedString(
        "The audio device could not be created (error %d).",
        comment: "Live translation audio error"), status)
    case .tapListFailed(let status):
      return String(format: NSLocalizedString(
        "The audio tap could not be attached (error %d).",
        comment: "Live translation audio error"), status)
    case .streamFormatFailed(let status):
      return String(format: NSLocalizedString(
        "The audio format could not be read (error %d).",
        comment: "Live translation audio error"), status)
    case .deviceStartFailed(let status):
      return String(format: NSLocalizedString(
        "The audio device could not start (error %d).",
        comment: "Live translation audio error"), status)
    case .readerFailed(let message):
      return message
    }
  }
}

protocol AudioCapturing: AnyObject {
  var state: AudioCaptureState { get }
  var onStateChange: ((AudioCaptureState) -> Void)? { get set }
  func start() async throws -> AsyncStream<AudioFrame>
  func stop()
}

/// Detects a tap that is delivering digital silence because the system
/// recording permission was denied. Once the time threshold is reached the
/// caller stops the tap and shows the permission state.
struct AudioSilenceDetector {
  /// A denied process tap delivers exact digital zero. A non-zero RMS is
  /// treated as proof that capture works; anything above zero is real audio.
  /// Five seconds avoids a quiet opening being mistaken for a denial; a real
  /// denial still surfaces while the user waits for the first line.
  var threshold: Float = 0
  var requiredSilence: TimeInterval = 5

  private var silentDuration: TimeInterval = 0
  private(set) var hasTripped = false

  mutating func observe(_ buffer: AVAudioPCMBuffer) -> Bool {
    guard !hasTripped else { return true }
    let duration = Double(buffer.frameLength) / buffer.format.sampleRate
    if buffer.rmsLevel <= threshold {
      silentDuration += duration
    } else {
      silentDuration = 0
    }
    if silentDuration >= requiredSilence {
      hasTripped = true
    }
    return hasTripped
  }

  mutating func reset() {
    silentDuration = 0
    hasTripped = false
  }
}

extension AVAudioPCMBuffer {
  /// Linear RMS across all channels, using float samples.
  var rmsLevel: Float {
    guard frameLength > 0, format.commonFormat == .pcmFormatFloat32 else { return 0 }
    let frameCount = Int(frameLength)
    let channelCount = Int(format.channelCount)
    var sum: Float = 0

    if let channels = floatChannelData, !format.isInterleaved {
      let stride = self.stride
      for channel in 0..<channelCount {
        let samples = channels[channel]
        for index in 0..<frameCount {
          let value = samples[index * stride]
          sum += value * value
        }
      }
      return sqrt(sum / Float(frameCount * channelCount))
    }

    // Interleaved float buffers have no channel pointers; read the single
    // buffer as a flat sample array.
    let bufferList = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: audioBufferList))
    guard let first = bufferList.first,
          let data = first.mData?.assumingMemoryBound(to: Float.self) else {
      return 0
    }
    let sampleCount = frameCount * channelCount
    for index in 0..<sampleCount {
      let value = data[index]
      sum += value * value
    }
    return sqrt(sum / Float(sampleCount))
  }
}

final class AudioBufferConverter {
  let outputFormat: AVAudioFormat
  private let converter: AVAudioConverter

  init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      return nil
    }
    self.converter = converter
    self.outputFormat = outputFormat
  }

  func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(
      ceil(Double(buffer.frameLength) * ratio)) + 1024
    guard let output = AVAudioPCMBuffer(
      pcmFormat: outputFormat, frameCapacity: capacity) else {
      throw AudioCaptureError.unsupportedFormat
    }

    var supplied = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
      if supplied {
        outStatus.pointee = .endOfStream
        return nil
      }
      supplied = true
      outStatus.pointee = .haveData
      return buffer
    }
    if let conversionError {
      throw conversionError
    }
    guard status != .error else {
      throw AudioCaptureError.unsupportedFormat
    }
    return output
  }
}

/// Last known system-audio permission result. The tap can only infer it from
/// silence, so "suspected" is a real state, not an oversight: only a non-zero
/// sample confirms the grant, and sustained exact zero is evidence of denial.
final class LiveTranslationAudioPermission {
  enum State: Equatable {
    case unknown
    case granted
    case suspected
    case denied
  }

  static let shared = LiveTranslationAudioPermission()

  private let lock = NSLock()
  private var _state: State = .unknown

  var state: State {
    lock.lock()
    defer { lock.unlock() }
    return _state
  }

  func update(_ state: State) {
    lock.lock()
    let changed = _state != state
    _state = state
    lock.unlock()
    guard changed else { return }
    DispatchQueue.main.async {
      NotificationCenter.default.post(
        name: .iinaLiveTranslationAudioPermissionChanged, object: self)
    }
  }

  func reset() {
    update(.unknown)
  }
}
