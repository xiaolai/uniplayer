//
//  LiveTranslationFileAudioSource.swift
//  uniplayer
//
//  Fallback when the process tap is denied, muted or unusable: decode a local
//  file instead of capturing output. `FileAudioSource` uses AVFoundation and
//  covers its containers; `FFmpegFileAudioSource` covers what AVFoundation
//  cannot open at all, Matroska above all. Either way a decode failure is
//  reported, never silently treated as silence, and decoding is paced to the
//  playback rate so captions track the video instead of racing ahead through
//  the whole file.
//

import AVFoundation
import Foundation

final class FileAudioSource: AudioCapturing {
  private let url: URL
  private let targetFormat: AVAudioFormat
  private let stateLock = NSLock()
  private let dataLock = NSLock()

  private var reader: AVAssetReader?
  private var task: Task<Void, Never>?
  private var continuation: AsyncStream<AudioFrame>.Continuation?
  private var generation = 0
  /// AVFoundation's media-type track order is the only mapping available from
  /// mpv's aid, which is a playlist id, not an AVAssetTrack id. Selecting by
  /// ordinal matches ordinary single-track and ordered multi-track files; a
  /// mismatched container remains a known limitation.
  private let trackIndex: Int
  /// The selected audio track's mpv language tag. When AVFoundation's track
  /// order differs, the language is a more reliable identity than an ordinal.
  private let languageHint: String?

  private var _state: AudioCaptureState = .idle
  var state: AudioCaptureState {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _state
  }
  var onStateChange: ((AudioCaptureState) -> Void)?
  let isFileBacked = true

  init(url: URL, targetFormat: AVAudioFormat, trackIndex: Int = 0,
       languageHint: String? = nil) {
    self.url = url
    self.targetFormat = targetFormat
    self.trackIndex = max(0, trackIndex)
    self.languageHint = languageHint
  }

  func start() async throws -> AsyncStream<AudioFrame> {
    try await start(at: 0, rate: 1)
  }

  func start(at seconds: TimeInterval,
             rate: Double = 1) async throws -> AsyncStream<AudioFrame> {
    guard beginStarting() else {
      throw AudioCaptureError.alreadyRunning
    }
    // Allocate the attempt before the first suspension so stop() during
    // loadTracks invalidates this startup instead of letting it publish a
    // reader over a newer one.
    dataLock.lock()
    generation += 1
    let attempt = generation
    dataLock.unlock()

    let asset = AVURLAsset(url: url)
    let tracks: [AVAssetTrack]
    do {
      tracks = try await asset.loadTracks(withMediaType: .audio)
    } catch {
      guard isCurrent(attempt) else { throw CancellationError() }
      setState(.failed(error.localizedDescription))
      throw AudioCaptureError.readerFailed(error.localizedDescription)
    }
    guard isCurrent(attempt) else { throw CancellationError() }
    let track: AVAssetTrack
    if let hint = languageHint, !hint.isEmpty,
       let matched = tracks.first(where: {
         Self.matchesLanguage($0, hint: hint)
       }) {
      track = matched
    } else if tracks.indices.contains(trackIndex) {
      track = tracks[trackIndex]
    } else if let first = tracks.first {
      Logger.log(
        "Live translation audio track \(trackIndex) is out of range; using the first track",
        level: .debug)
      track = first
    } else {
      guard isCurrent(attempt) else { throw CancellationError() }
      setState(.failed(AudioCaptureError.noAudioTrack.localizedDescription))
      throw AudioCaptureError.noAudioTrack
    }

    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      guard isCurrent(attempt) else { throw CancellationError() }
      setState(.failed(error.localizedDescription))
      throw AudioCaptureError.readerFailed(error.localizedDescription)
    }

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsNonInterleaved: false,
      AVLinearPCMIsBigEndianKey: false,
      AVSampleRateKey: targetFormat.sampleRate,
      AVNumberOfChannelsKey: targetFormat.channelCount,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      guard isCurrent(attempt) else { throw CancellationError() }
      setState(.failed(AudioCaptureError.unsupportedFormat.localizedDescription))
      throw AudioCaptureError.unsupportedFormat
    }
    reader.add(output)
    if seconds > 0 {
      reader.timeRange = CMTimeRange(
        start: CMTime(seconds: seconds, preferredTimescale: 600),
        duration: .positiveInfinity)
    }
    guard reader.startReading() else {
      let message = reader.error?.localizedDescription
        ?? NSLocalizedString("The audio could not be read.",
                             comment: "Live translation audio error")
      guard isCurrent(attempt) else { throw CancellationError() }
      setState(.failed(message))
      throw AudioCaptureError.readerFailed(message)
    }
    guard isCurrent(attempt) else {
      reader.cancelReading()
      throw CancellationError()
    }
    dataLock.lock()
    guard attempt == generation else {
      dataLock.unlock()
      reader.cancelReading()
      throw CancellationError()
    }
    self.reader = reader
    dataLock.unlock()

    let generation = attempt

    let stream = AsyncStream<AudioFrame>(
      bufferingPolicy: .bufferingNewest(16)) { continuation in
      dataLock.lock()
      self.continuation = continuation
      dataLock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.stop()
      }
    }

    guard isCurrent(attempt) else {
      reader.cancelReading()
      throw CancellationError()
    }
    setState(.running)

    task = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      let playbackRate = max(0.1, rate)
      let clockStart = ContinuousClock.now
      let origin = seconds
      var firstPresentation: CMTime?
      var fallbackFrames: AVAudioFramePosition = 0
      var yielded = 0
      var skipped = 0
      var decodeFailure: String?
      while !Task.isCancelled, self.isCurrent(generation),
            reader.status == .reading,
            let sample = output.copyNextSampleBuffer() {
        guard let frame = Self.frame(from: sample) else {
          skipped += 1
          if skipped >= 50, yielded == 0 {
            decodeFailure = NSLocalizedString(
              "The audio track could not be decoded.",
              comment: "Live translation audio error")
            break
          }
          continue
        }
        skipped = 0

        // Pace decoded audio to the playback clock. The presentation time is
        // media time, so subtract the requested start position, not the first
        // decoded sample: an initial gap must stay a gap.
        let elapsed: TimeInterval
        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        if presentation.isValid, presentation.isNumeric {
          if firstPresentation == nil { firstPresentation = presentation }
          elapsed = CMTimeGetSeconds(presentation) - origin
        } else {
          fallbackFrames += AVAudioFramePosition(frame.buffer.frameLength)
          elapsed = Double(fallbackFrames) / frame.buffer.format.sampleRate
        }
        if elapsed.isFinite, elapsed > 0 {
          let target = clockStart.advanced(
            by: .seconds(elapsed / playbackRate))
          if target > ContinuousClock.now {
            try? await Task.sleep(until: target, clock: .continuous)
          }
          if Task.isCancelled { break }
        }
        yielded += 1
        self.dataLock.lock()
        guard generation == self.generation else {
          self.dataLock.unlock()
          return
        }
        let continuation = self.continuation
        self.dataLock.unlock()
        continuation?.yield(frame)
      }
      let failure = decodeFailure ?? (reader.status == .failed
        ? reader.error?.localizedDescription
        : nil)
      self.dataLock.lock()
      guard generation == self.generation else {
        self.dataLock.unlock()
        return
      }
      let pending = self.continuation
      self.continuation = nil
      self.reader = nil
      // Publish the terminal state before the consumer observes end-of-stream;
      // otherwise it reads .running and skips the EOF flush/failure branch.
      // The data lock makes the generation check and the state write atomic
      // with respect to stop()/start().
      guard generation == self.generation else {
        self.dataLock.unlock()
        return
      }
      if let failure {
        self.setState(.failed(failure))
      } else if !self.hasFailed {
        self.setState(.idle)
      }
      self.dataLock.unlock()
      pending?.onTermination = nil
      pending?.finish()
    }

    return stream
  }

  func stop() {
    dataLock.lock()
    generation += 1
    let pending = continuation
    continuation = nil
    reader?.cancelReading()
    reader = nil
    dataLock.unlock()
    pending?.onTermination = nil
    pending?.finish()
    task?.cancel()
    task = nil
    if !hasFailed {
      setState(.idle)
    }
  }

  private func isCurrent(_ generation: Int) -> Bool {
    dataLock.lock()
    defer { dataLock.unlock() }
    return generation == self.generation
  }

  private func beginStarting() -> Bool {
    stateLock.lock()
    switch _state {
    case .idle, .failed:
      _state = .starting
      let callback = onStateChange
      stateLock.unlock()
      if let callback {
        DispatchQueue.main.async {
          callback(.starting)
        }
      }
      return true
    default:
      stateLock.unlock()
      return false
    }
  }

  private var hasFailed: Bool {
    if case .failed = state { return true }
    return false
  }

  private static func matchesLanguage(_ track: AVAssetTrack,
                                      hint: String) -> Bool {
    let tag = track.extendedLanguageTag ?? track.languageCode ?? ""
    guard !tag.isEmpty else { return false }
    return primaryLanguage(tag) == primaryLanguage(hint)
  }

  private static func primaryLanguage(_ raw: String) -> String {
    let lower = raw.lowercased()
      .replacingOccurrences(of: "_", with: "-")
    let first = lower.split(separator: "-").first.map(String.init) ?? lower
    let iso3: [String: String] = [
      "kor": "ko", "jpn": "ja", "fra": "fr", "fre": "fr",
      "ita": "it", "eng": "en", "zho": "zh", "chi": "zh",
      "cmn": "zh", "yue": "yue",
    ]
    return iso3[first] ?? first
  }

  private static func frame(from sample: CMSampleBuffer) -> AudioFrame? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sample),
          let streamDescription =
            CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
          let format = AVAudioFormat(streamDescription: streamDescription) else {
      return nil
    }
    let frames = CMSampleBufferGetNumSamples(sample)
    guard frames > 0,
          let pcm = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
      return nil
    }
    pcm.frameLength = AVAudioFrameCount(frames)
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sample, at: 0, frameCount: Int32(frames),
      into: pcm.mutableAudioBufferList)
    guard status == noErr else { return nil }
    return AudioFrame(buffer: pcm, time: nil)
  }

  private func setState(_ state: AudioCaptureState) {
    stateLock.lock()
    let changed = _state != state
    _state = state
    let callback = onStateChange
    stateLock.unlock()
    guard changed, let callback else { return }
    if Thread.isMainThread {
      callback(state)
    } else {
      DispatchQueue.main.async {
        callback(state)
      }
    }
  }
}

/// Decodes the selected audio track with the bundled FFmpeg.
///
/// `FileAudioSource` exists for the same job but depends on AVFoundation,
/// which has no Matroska demuxer: an MKV failed to load its tracks at all, so
/// live translation could only work while the system-audio tap was permitted.
/// This source opens any container libavformat understands, so MKV, TS and AVI
/// behave like MP4 and stop depending on the tap. Samples arrive as float32 at
/// the track's own rate; `AVAudioConverter` does the resample and downmix,
/// because reimplementing those would put audio quality at risk.
final class FFmpegFileAudioSource: AudioCapturing {
  private let url: URL
  private let targetFormat: AVAudioFormat
  private let trackIndex: Int
  private let languageHint: String?

  private let stateLock = NSLock()
  private let dataLock = NSLock()

  private var task: Task<Void, Never>?
  private var continuation: AsyncStream<AudioFrame>.Continuation?
  private var generation = 0

  private var _state: AudioCaptureState = .idle
  var state: AudioCaptureState {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _state
  }
  var onStateChange: ((AudioCaptureState) -> Void)?
  let isFileBacked = true

  init(url: URL, targetFormat: AVAudioFormat, trackIndex: Int = 0,
       languageHint: String? = nil) {
    self.url = url
    self.targetFormat = targetFormat
    self.trackIndex = max(0, trackIndex)
    self.languageHint = languageHint
  }

  func start() async throws -> AsyncStream<AudioFrame> {
    try await start(at: 0, rate: 1)
  }

  func start(at seconds: TimeInterval,
             rate: Double = 1) async throws -> AsyncStream<AudioFrame> {
    guard beginStarting() else {
      throw AudioCaptureError.alreadyRunning
    }
    dataLock.lock()
    generation += 1
    let attempt = generation
    dataLock.unlock()

    let decoder: FFmpegAudioDecoder
    do {
      decoder = try FFmpegAudioDecoder(
        url: url, trackOrdinal: trackIndex, languageHint: languageHint)
    } catch {
      guard isCurrent(attempt) else { throw CancellationError() }
      let message = error.localizedDescription
      setState(.failed(message))
      throw AudioCaptureError.readerFailed(message)
    }
    if seconds > 0 {
      do {
        try decoder.seek(toSeconds: seconds)
      } catch {
        decoder.close()
        guard isCurrent(attempt) else { throw CancellationError() }
        let message = error.localizedDescription
        setState(.failed(message))
        throw AudioCaptureError.readerFailed(message)
      }
    }

    guard isCurrent(attempt) else {
      decoder.close()
      throw CancellationError()
    }

    let currentGeneration = attempt
    let stream = AsyncStream<AudioFrame>(
      bufferingPolicy: .bufferingNewest(16)) { continuation in
      dataLock.lock()
      self.continuation = continuation
      dataLock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.stop()
      }
    }

    guard isCurrent(attempt) else {
      decoder.close()
      throw CancellationError()
    }
    setState(.running)

    task = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      defer { decoder.close() }
      let playbackRate = max(0.1, rate)
      let clockStart = ContinuousClock.now
      let origin = seconds
      var yielded = 0
      var decodeFailure: String?
      // Built from the first decoded frame and owned by this task alone: the
      // input format is only known once libavcodec produced one, and it does
      // not change mid-track. Keeping it here rather than on the object means
      // stop() cannot race the conversion.
      var chunkConverter: AudioBufferConverter?
      var chunkConverterFormat: AVAudioFormat?
      let targetFormat = self.targetFormat

      while !Task.isCancelled, self.isCurrent(currentGeneration) {
        var chunkSeconds = 0.0
        let chunk: AVAudioPCMBuffer?
        do {
          chunk = try decoder.nextBuffer(withSeconds: &chunkSeconds)
        } catch {
          decodeFailure = error.localizedDescription
          break
        }
        // The decoder signals the end of the track with an empty buffer; nil
        // means it threw, so reaching here with nil is the end of the file.
        guard let chunk else { break }
        if chunk.frameLength == 0 { break }

        let frame: AudioFrame
        do {
          if chunkConverter == nil || chunkConverterFormat != chunk.format {
            guard let created = AudioBufferConverter(
              inputFormat: chunk.format, outputFormat: targetFormat) else {
              throw AudioCaptureError.unsupportedFormat
            }
            chunkConverter = created
            chunkConverterFormat = chunk.format
          }
          guard let converter = chunkConverter else {
            throw AudioCaptureError.unsupportedFormat
          }
          frame = AudioFrame(buffer: try converter.convert(chunk), time: nil)
        } catch {
          decodeFailure = error.localizedDescription
          break
        }
        yielded += 1

        // Pace decoded audio to the playback clock, exactly as the
        // AVFoundation source does: the presentation time is media time, so
        // subtract the requested start position and keep an initial gap a gap.
        let elapsed = chunkSeconds - origin
        if elapsed.isFinite, elapsed > 0 {
          let target = clockStart.advanced(by: .seconds(elapsed / playbackRate))
          if target > ContinuousClock.now {
            try? await Task.sleep(until: target, clock: .continuous)
          }
          if Task.isCancelled { break }
        }

        self.dataLock.lock()
        guard currentGeneration == self.generation else {
          self.dataLock.unlock()
          return
        }
        let continuation = self.continuation
        self.dataLock.unlock()
        continuation?.yield(frame)
      }

      self.dataLock.lock()
      guard currentGeneration == self.generation else {
        self.dataLock.unlock()
        return
      }
      let pending = self.continuation
      self.continuation = nil
      // Publish the terminal state before the consumer observes end of
      // stream, so it reads the outcome instead of .running.
      if let decodeFailure {
        self.publishState(.failed(decodeFailure))
      } else if !self.hasFailed {
        self.publishState(.idle)
      }
      self.dataLock.unlock()
      pending?.onTermination = nil
      pending?.finish()
      Logger.log("Live translation FFmpeg audio stream ended after \(yielded) frames",
                 level: .debug)
    }

    return stream
  }

  func stop() {
    dataLock.lock()
    generation += 1
    let pending = continuation
    continuation = nil
    dataLock.unlock()
    pending?.onTermination = nil
    pending?.finish()
    // The decoding task owns the decoder and closes it on the way out, so a
    // read in flight never runs against freed libav contexts.
    task?.cancel()
    task = nil
    if !hasFailed {
      setState(.idle)
    }
  }

  private func isCurrent(_ generation: Int) -> Bool {
    dataLock.lock()
    defer { dataLock.unlock() }
    return generation == self.generation
  }

  private func beginStarting() -> Bool {
    stateLock.lock()
    switch _state {
    case .idle, .failed:
      _state = .starting
      let callback = onStateChange
      stateLock.unlock()
      if let callback {
        DispatchQueue.main.async {
          callback(.starting)
        }
      }
      return true
    default:
      stateLock.unlock()
      return false
    }
  }

  private var hasFailed: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    if case .failed = _state { return true }
    return false
  }

  /// State write for the terminal path, which already holds `dataLock`: the
  /// same lock makes the generation check and the state change atomic against
  /// `start` and `stop`.
  private func publishState(_ state: AudioCaptureState) {
    stateLock.lock()
    let changed = _state != state
    _state = state
    let callback = onStateChange
    stateLock.unlock()
    guard changed, let callback else { return }
    if Thread.isMainThread {
      callback(state)
    } else {
      DispatchQueue.main.async {
        callback(state)
      }
    }
  }

  private func setState(_ state: AudioCaptureState) {
    publishState(state)
  }
}
