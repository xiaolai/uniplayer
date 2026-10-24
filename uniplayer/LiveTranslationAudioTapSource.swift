//
//  LiveTranslationAudioTapSource.swift
//  uniplayer
//
//  Captures UniPlayer's own output with a Core Audio process tap. The IOProc
//  runs on the real-time thread and only copies samples into a lock-free ring;
//  a separate pump turns ring data into AVAudioPCMBuffer frames.
//
//  Limitation: a process tap is per-process, not per-window. WebKit plays
//  channel audio in helper processes, so descendants are included; a second
//  audible player still produces one mixed signal, which is why live
//  translation runs only when this player is the sole audible one.
//

import AVFoundation
import CoreAudio
import Darwin
import Foundation
import Synchronization

/// Single-producer, single-consumer float ring. The producer never blocks or
/// drops the newest data silently: if the ring is full the incoming block is
/// dropped and the caller can observe the gap through the stream.
final class AudioRingBuffer {
  private let capacity: Int
  private let storage: UnsafeMutablePointer<Float>
  private let writeIndex = Synchronization.Atomic<Int>(0)
  private let readIndex = Synchronization.Atomic<Int>(0)

  init(capacity: Int = 96_000) {
    self.capacity = capacity
    self.storage = .allocate(capacity: capacity)
    self.storage.initialize(repeating: 0, count: capacity)
  }

  deinit {
    storage.deinitialize(count: capacity)
    storage.deallocate()
  }

  func reset() {
    readIndex.store(0, ordering: .releasing)
    writeIndex.store(0, ordering: .releasing)
  }

  func write(_ source: UnsafePointer<Float>, count: Int) {
    guard count > 0 else { return }
    let write = writeIndex.load(ordering: .relaxed)
    let read = readIndex.load(ordering: .acquiring)
    guard capacity - (write - read) >= count else { return }
    for index in 0..<count {
      storage[(write + index) % capacity] = source[index]
    }
    writeIndex.store(write + count, ordering: .releasing)
  }

  func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
    let read = readIndex.load(ordering: .relaxed)
    let write = writeIndex.load(ordering: .acquiring)
    let available = min(count, write - read)
    for index in 0..<available {
      destination[index] = storage[(read + index) % capacity]
    }
    readIndex.store(read + available, ordering: .releasing)
    return available
  }

  var available: Int {
    writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring)
  }
}

final class AudioTapSource: AudioCapturing {
  private let controlQueue = DispatchQueue(
    label: "UniPlayer.LiveTranslation.AudioTapControl", qos: .userInitiated)
  private let dataLock = NSLock()
  private let stateLock = NSLock()

  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var ioProcID: AudioDeviceIOProcID?
  private var tapFormat: AVAudioFormat?
  private var ring: AudioRingBuffer?
  private var pumpTask: Task<Void, Never>?
  private var continuation: AsyncStream<AudioFrame>.Continuation?
  private var detector = AudioSilenceDetector()
  private var probeActive = true
  private var processedFrames: AVAudioFramePosition = 0

  private var _state: AudioCaptureState = .idle
  var state: AudioCaptureState {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _state
  }
  var onStateChange: ((AudioCaptureState) -> Void)?

  var isRunning: Bool {
    if case .running = state { return true }
    return false
  }

  deinit {
    cleanup()
  }

  func start() async throws -> AsyncStream<AudioFrame> {
    guard beginStarting() else {
      throw AudioCaptureError.alreadyRunning
    }

    let stream = AsyncStream<AudioFrame>(
      bufferingPolicy: .bufferingNewest(16)) { continuation in
      dataLock.lock()
      self.continuation = continuation
      dataLock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.stop()
      }
    }

    return try await withCheckedThrowingContinuation { continuation in
      controlQueue.async { [weak self] in
        guard let self else {
          continuation.resume(throwing: AudioCaptureError.tapCreationFailed(-1))
          return
        }
        do {
          try self.setup()
          self.startPump()
          self.setState(.running)
          continuation.resume(returning: stream)
        } catch {
          self.cleanup()
          self.setState(.failed(error.localizedDescription))
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func stop() {
    controlQueue.async { [weak self] in
      guard let self else { return }
      self.cleanup()
      if self.state != .permissionDenied {
        self.setState(.idle)
      }
    }
  }

  // MARK: - Setup

  private func setup() throws {
    guard let processObject = Self.processObjectID(for: getpid()) else {
      throw AudioCaptureError.processObjectUnavailable
    }

    let description = CATapDescription()
    description.name = "UniPlayer Live Translation"
    description.processes = [processObject]
      + Self.descendantProcessObjects(of: getpid())
    description.isPrivate = true
    description.muteBehavior = .unmuted
    description.isMixdown = true
    description.isMono = true
    description.isExclusive = false

    var tap = AudioObjectID(kAudioObjectUnknown)
    let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
    guard tapStatus == noErr else {
      throw AudioCaptureError.tapCreationFailed(tapStatus)
    }
    tapID = tap

    var formatAddress = Self.propertyAddress(kAudioTapPropertyFormat)
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var streamDescription = AudioStreamBasicDescription()
    let formatStatus = AudioObjectGetPropertyData(
      tap, &formatAddress, 0, nil, &formatSize, &streamDescription)
    guard formatStatus == noErr,
          let format = AVAudioFormat(streamDescription: &streamDescription) else {
      throw AudioCaptureError.streamFormatFailed(formatStatus)
    }
    // The IOProc reads the buffer as mono float32; anything else would be
    // reinterpreted as noise. Fail loudly instead of transcribing garbage.
    guard format.commonFormat == .pcmFormatFloat32,
          !format.isInterleaved,
          format.channelCount == 1 else {
      throw AudioCaptureError.unsupportedFormat
    }
    tapFormat = format

    guard let tapUID = Self.tapUID(tap) else {
      throw AudioCaptureError.tapCreationFailed(-1)
    }
    let aggregateDescription: [String: Any] = [
      kAudioAggregateDeviceNameKey: "UniPlayer Live Translation",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [],
      kAudioAggregateDeviceTapListKey: [
        [
          kAudioSubTapUIDKey: tapUID,
          kAudioSubTapDriftCompensationKey: true,
        ],
      ],
    ]
    var aggregate = AudioObjectID(kAudioObjectUnknown)
    let aggregateStatus = AudioHardwareCreateAggregateDevice(
      aggregateDescription as CFDictionary, &aggregate)
    guard aggregateStatus == noErr else {
      throw AudioCaptureError.aggregateDeviceFailed(aggregateStatus)
    }
    aggregateID = aggregate

    let ring = AudioRingBuffer(
      capacity: max(48_000, Int(format.sampleRate) * 2))
    self.ring = ring
    self.detector.reset()
    self.probeActive = true
    self.processedFrames = 0

    var procID: AudioDeviceIOProcID?
    let procStatus = AudioDeviceCreateIOProcIDWithBlock(
      &procID, aggregate, nil
    ) { _, inputData, _, _, _ in
      guard let first = inputData.pointee.mBuffers.mData else { return }
      let count = Int(inputData.pointee.mBuffers.mDataByteSize)
        / MemoryLayout<Float>.size
      guard count > 0 else { return }
      let pointer = first.assumingMemoryBound(to: Float.self)
      ring.write(pointer, count: count)
    }
    guard procStatus == noErr, let procID else {
      throw AudioCaptureError.deviceStartFailed(procStatus)
    }
    ioProcID = procID

    // The first start may show the System Audio Recording permission prompt.
    // This runs on the control queue so the main thread stays responsive.
    let startStatus = AudioDeviceStart(aggregate, procID)
    guard startStatus == noErr else {
      throw AudioCaptureError.deviceStartFailed(startStatus)
    }
  }

  private func startPump() {
    dataLock.lock()
    let format = tapFormat
    let ring = ring
    dataLock.unlock()
    guard let format, let ring else { return }

    pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(20))
        guard !Task.isCancelled else { return }
        self.pump(format: format, ring: ring)
      }
    }
  }

  private func pump(format: AVAudioFormat, ring: AudioRingBuffer) {
    let available = min(ring.available, 4_096)
    guard available > 0 else { return }

    dataLock.lock()
    let continuation = self.continuation
    dataLock.unlock()
    guard let continuation else { return }

    var scratch = [Float](repeating: 0, count: available)
    let read = scratch.withUnsafeMutableBufferPointer { buffer -> Int in
      guard let base = buffer.baseAddress else { return 0 }
      return ring.read(into: base, count: min(available, buffer.count))
    }
    guard read > 0,
          let pcm = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(read)) else {
      return
    }
    pcm.frameLength = AVAudioFrameCount(read)
    guard let destination = pcm.floatChannelData?[0] else { return }
    scratch.withUnsafeBufferPointer { source in
      if let base = source.baseAddress {
        destination.update(from: base, count: read)
      }
    }

    let time = AVAudioTime(
      sampleTime: processedFrames, atRate: format.sampleRate)
    processedFrames += AVAudioFramePosition(read)

    if probeActive {
      if pcm.rmsLevel > detector.threshold {
        probeActive = false
        Task { @MainActor in
          LiveTranslationAudioPermission.shared.update(.granted)
        }
      } else if detector.observe(pcm) {
        Task { @MainActor in
          LiveTranslationAudioPermission.shared.update(.suspected)
        }
        setState(.permissionDenied)
        stop()
        return
      }
    }

    continuation.yield(AudioFrame(buffer: pcm, time: time))
  }

  private func cleanup() {
    pumpTask?.cancel()
    pumpTask = nil

    dataLock.lock()
    let pending = continuation
    continuation = nil
    tapFormat = nil
    ring = nil
    dataLock.unlock()
    pending?.onTermination = nil
    pending?.finish()

    if aggregateID != kAudioObjectUnknown {
      if let ioProcID {
        AudioDeviceStop(aggregateID, ioProcID)
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
      }
      AudioHardwareDestroyAggregateDevice(aggregateID)
    }
    if tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tapID)
    }
    ioProcID = nil
    aggregateID = AudioObjectID(kAudioObjectUnknown)
    tapID = AudioObjectID(kAudioObjectUnknown)
  }

  private func setState(_ state: AudioCaptureState) {
    stateLock.lock()
    let changed = _state != state
    _state = state
    let callback = onStateChange
    stateLock.unlock()
    guard changed, let callback else { return }
    DispatchQueue.main.async {
      callback(state)
    }
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

  // MARK: - Core Audio helpers

  private static func propertyAddress(
    _ selector: AudioObjectPropertySelector
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  static func processObjectID(for pid: pid_t) -> AudioObjectID? {
    var pid = pid
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      UInt32(MemoryLayout<pid_t>.size),
      &pid,
      &size,
      &objectID)
    guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
    return objectID
  }

  /// WebKit and other helpers play audio in child processes. Include the
  /// descendants so channel/web-view audio is captured; the owning player
  /// still gates captions to one source.
  static func descendantProcessObjects(of pid: pid_t) -> [AudioObjectID] {
    var result: [AudioObjectID] = []
    var queue = [pid]
    var seen: Set<pid_t> = [pid]
    var budget = 64
    while let parent = queue.popLast(), budget > 0 {
      var children = [pid_t](repeating: 0, count: 128)
      let returned = proc_listchildpids(
        parent, &children,
        Int32(children.count * MemoryLayout<pid_t>.size))
      guard returned > 0 else { continue }
      let count = min(Int(returned), children.count)
      for index in 0..<count {
        let child = children[index]
        guard child > 0, budget > 0,
              seen.insert(child).inserted else { continue }
        budget -= 1
        queue.append(child)
        if let object = processObjectID(for: child) {
          result.append(object)
        }
      }
    }
    return result
  }

  private static func tapUID(_ tapID: AudioObjectID) -> String? {
    var address = propertyAddress(kAudioTapPropertyUID)
    var size = UInt32(MemoryLayout<CFString>.stride)
    var uid: CFString = "" as CFString
    let status = withUnsafeMutablePointer(to: &uid) { pointer in
      AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { return nil }
    return uid as String
  }
}
