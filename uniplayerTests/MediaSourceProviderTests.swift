//
//  MediaSourceProviderTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

final class LocalFolderProviderTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("video".utf8).write(to: root.appendingPathComponent("A.mkv"))
    try Data("text".utf8).write(to: root.appendingPathComponent("notes.txt"))
    try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Sub"),
                                            withIntermediateDirectories: true)
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-outside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("Link"), withDestinationURL: outside)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testObserveIdentityReportsMountAndRelativePath() throws {
    let provider = LocalFolderProvider()
    let identity = try provider.observeIdentity(at: root)
    XCTAssertEqual(identity.namespace.kind, .local)
    XCTAssertTrue(identity.isVerified || identity.namespace.volumeIdentity.isEmpty == false)
    XCTAssertFalse(identity.pathInNamespace.isEmpty)
    XCTAssertFalse(identity.mountPath.isEmpty)
    XCTAssertTrue(identity.comparison.unicodeNormalizing)
  }

  func testListDirectorySkipsHiddenAndDoesNotTraverseSymlinks() throws {
    let provider = LocalFolderProvider()
    let listing = try provider.listDirectory(at: root, generation: 7)
    XCTAssertTrue(listing.isComplete)
    XCTAssertEqual(listing.generation, 7)
    let names = listing.entries.map(\.name)
    XCTAssertTrue(names.contains("A.mkv"))
    XCTAssertTrue(names.contains("notes.txt"))
    XCTAssertTrue(names.contains("Sub"))
    XCTAssertTrue(names.contains("Link"))
    XCTAssertFalse(names.contains(".hidden"))
    let link = listing.entries.first { $0.name == "Link" }
    XCTAssertNotNil(link)
    XCTAssertFalse(link?.isDirectory ?? true)
    XCTAssertTrue(link?.isSymbolicLink ?? false)
    XCTAssertTrue(listing.entries.first?.isDirectory ?? false)
  }

  func testStatReportsSizeAndReadability() throws {
    let provider = LocalFolderProvider()
    let stat = try provider.stat(at: root.appendingPathComponent("A.mkv"))
    XCTAssertFalse(stat.isDirectory)
    XCTAssertEqual(stat.size, 5)
    XCTAssertTrue(stat.isReadable)
  }
}

final class LegacyLibrarySnapshotTests: XCTestCase {
  func testSnapshotDoesNotProbeSourcePaths() {
    let url = URL(fileURLWithPath: "/definitely/missing/uniplayer-source.mkv")
    let entry = PlaybackHistorySnapshot(
      url: url, name: url.lastPathComponent, played: true, addedDate: Date(),
      duration: 10, progress: nil, title: nil)
    let snapshot = LibraryModel.snapshot(
      history: [entry], recent: [], lastPlayed: nil, hidden: [], watched: [:])
    XCTAssertEqual(snapshot.allItems.count, 1)
    XCTAssertFalse(snapshot.allItems[0].isMissing,
                   "presence must remain unknown until bounded observation")
  }
}

final class SourceIOExecutorTests: XCTestCase {

  func testDifferentNetworkVolumesRunConcurrently() async throws {
    let executor = SourceIOExecutor(limits: SourceIOLimits(
      bootLocalOutstanding: 1, otherLocalOutstanding: 1,
      networkOutstanding: 2, networkActive: 2, totalOutstanding: 2,
      quarantinedNetworkLimit: 2, defaultTimeout: 2))
    let gate = DispatchSemaphore(value: 0)
    let started = (0..<2).map { _ in DispatchSemaphore(value: 0) }

    let first = Task {
      try await executor.perform(lane: .network, volumeKey: "v1") {
        started[0].signal()
        gate.wait()
        return 1
      }
    }
    XCTAssertEqual(started[0].wait(timeout: .now() + 1), .success)

    let second = Task {
      try await executor.perform(lane: .network, volumeKey: "v2") {
        started[1].signal()
        gate.wait()
        return 2
      }
    }
    XCTAssertEqual(started[1].wait(timeout: .now() + 1), .success,
                   "different network volumes should run concurrently")

    gate.signal()
    gate.signal()
    _ = try await first.value
    _ = try await second.value
  }

  func testTimeoutQuarantinesUntilTheCallActuallyExits() async throws {
    let executor = SourceIOExecutor(limits: SourceIOLimits(
      bootLocalOutstanding: 1, otherLocalOutstanding: 1,
      networkOutstanding: 4, networkActive: 4, totalOutstanding: 6,
      quarantinedNetworkLimit: 2, defaultTimeout: 0.05))
    let release = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)

    let blocked = Task {
      try await executor.perform(lane: .network, volumeKey: "nas1") {
        started.signal()
        release.wait()
        return 1
      }
    }
    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    do {
      _ = try await blocked.value
      XCTFail("expected timeout")
    } catch {
      XCTAssertEqual(error as? MediaSourceError, .timedOut)
    }
    XCTAssertEqual(executor.quarantinedNetworkCount, 1)

    release.signal()
    let deadline = Date().addingTimeInterval(1)
    while executor.quarantinedNetworkCount != 0 && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(executor.quarantinedNetworkCount, 0)
  }

  func testCancellingAQueuedRequestGivesUpItsPlace() async throws {
    let executor = SourceIOExecutor(limits: SourceIOLimits(
      bootLocalOutstanding: 1, otherLocalOutstanding: 1,
      networkOutstanding: 1, networkActive: 1, totalOutstanding: 2,
      quarantinedNetworkLimit: 2, defaultTimeout: 5))
    let release = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    let blocker = Task {
      try await executor.perform(lane: .network, volumeKey: "nas1") {
        started.signal()
        release.wait()
        return 1
      }
    }
    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

    // The network budget is full, so this request waits for admission.
    let queued = Task {
      try await executor.perform(lane: .network, volumeKey: "nas2") { 2 }
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    queued.cancel()
    do {
      _ = try await queued.value
      XCTFail("expected cancellation while queued")
    } catch {
      XCTAssertEqual(error as? MediaSourceError, .cancelled)
    }

    release.signal()
    _ = try await blocker.value
    XCTAssertEqual(executor.outstandingCount, 0)
  }

  func testQuarantinedCallsFreeActiveCapacity() async throws {
    let executor = SourceIOExecutor(limits: SourceIOLimits(
      bootLocalOutstanding: 1, otherLocalOutstanding: 1,
      networkOutstanding: 4, networkActive: 2, totalOutstanding: 6,
      quarantinedNetworkLimit: 4, defaultTimeout: 0.05))
    let release = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var startedCount = 0
    let blocked = (0..<2).map { index in
      Task {
        try await executor.perform(lane: .network, volumeKey: "nas\(index)") {
          lock.lock()
          startedCount += 1
          if startedCount == 2 { started.signal() }
          lock.unlock()
          release.wait()
          return index
        }
      }
    }
    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    for task in blocked {
      do {
        _ = try await task.value
        XCTFail("expected timeout")
      } catch {
        XCTAssertEqual(error as? MediaSourceError, .timedOut)
      }
    }
    XCTAssertEqual(executor.quarantinedNetworkCount, 2)

    // The two blocked calls no longer occupy the two active slots.
    let value = try await executor.perform(lane: .network, volumeKey: "nas3") { 3 }
    XCTAssertEqual(value, 3)
    XCTAssertEqual(executor.activeNetworkCount, 0)

    release.signal()
    release.signal()
    let deadline = Date().addingTimeInterval(1)
    while executor.quarantinedNetworkCount != 0 && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(executor.quarantinedNetworkCount, 0)
  }

  func testQuarantineLimitRefusesNewNetworkWork() async throws {
    let executor = SourceIOExecutor(limits: SourceIOLimits(
      bootLocalOutstanding: 1, otherLocalOutstanding: 1,
      networkOutstanding: 4, networkActive: 4, totalOutstanding: 6,
      quarantinedNetworkLimit: 2, defaultTimeout: 0.05))
    let release = DispatchSemaphore(value: 0)
    let bothStarted = DispatchSemaphore(value: 0)
    var signalCount = 0
    let lock = NSLock()

    let tasks = (0..<2).map { index in
      Task {
        try await executor.perform(lane: .network, volumeKey: "nas\(index)") {
          lock.lock()
          signalCount += 1
          if signalCount == 2 { bothStarted.signal() }
          lock.unlock()
          release.wait()
          return index
        }
      }
    }
    XCTAssertEqual(bothStarted.wait(timeout: .now() + 1), .success)
    for task in tasks {
      do {
        _ = try await task.value
        XCTFail("expected timeout")
      } catch {
        XCTAssertEqual(error as? MediaSourceError, .timedOut)
      }
    }
    XCTAssertEqual(executor.quarantinedNetworkCount, 2)

    do {
      _ = try await executor.perform(lane: .network, volumeKey: "nas3") { 3 }
      XCTFail("expected quarantine refusal")
    } catch {
      XCTAssertEqual(error as? MediaSourceError, .quarantined)
    }

    release.signal()
    release.signal()
    let deadline = Date().addingTimeInterval(1)
    while executor.quarantinedNetworkCount != 0 && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(executor.quarantinedNetworkCount, 0)
  }

  func testQueuedRequestTimesOutBehindABlockedVolume() async throws {
    let executor = SourceIOExecutor(limits: SourceIOLimits(
      bootLocalOutstanding: 1, otherLocalOutstanding: 1,
      networkOutstanding: 1, networkActive: 1, totalOutstanding: 2,
      quarantinedNetworkLimit: 1, defaultTimeout: 2))
    let release = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    let blocked = Task {
      try await executor.perform(lane: .local, volumeKey: "v", timeout: 2) {
        started.signal()
        release.wait()
        return 1
      }
    }
    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

    let queued = Task {
      try await executor.perform(lane: .local, volumeKey: "v", timeout: 0.05) { 2 }
    }
    do {
      _ = try await queued.value
      XCTFail("expected queued admission timeout")
    } catch {
      XCTAssertEqual(error as? MediaSourceError, .timedOut)
    }

    release.signal()
    let blockedValue = try await blocked.value
    XCTAssertEqual(blockedValue, 1)
  }

  func testBlockedNonBootDiskDoesNotConsumeTheBootSlot() async throws {    let executor = SourceIOExecutor(limits: SourceIOLimits(
      bootLocalOutstanding: 1, otherLocalOutstanding: 1,
      networkOutstanding: 1, networkActive: 1, totalOutstanding: 2,
      quarantinedNetworkLimit: 1, defaultTimeout: 2))
    let release = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    let blocked = Task {
      try await executor.perform(lane: .local, volumeKey: "external", isBootVolume: false) {
        started.signal()
        release.wait()
        return 1
      }
    }
    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

    let boot = try await executor.perform(lane: .local, volumeKey: "/", isBootVolume: true) {
      2
    }
    XCTAssertEqual(boot, 2)
    release.signal()
    _ = try await blocked.value
  }
}
