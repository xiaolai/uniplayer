//
//  SourceIO.swift
//  uniplayer
//
//  Bounded admission for media-source filesystem work. Source paths can be on
//  a sleeping NAS or a removed disk; a blocked kernel call must not consume a
//  Swift cooperative thread, a UI thread, or unbounded capacity. Work runs on
//  dedicated blocking queues, one operation per observed volume, with a
//  separate local and network budget and a quarantine for calls that outlive
//  their logical timeout.
//

import Foundation

enum SourceIOLane: String, Sendable {
  case local
  case network

  /// Mounted shares appear below /Volumes. The catalog's network lane is
  /// conservative: a local external disk that lands there waits in the network
  /// queue, which is better than an SMB lookup occupying a local slot.
  static func forPath(_ path: String) -> SourceIOLane {
    path.hasPrefix("/Volumes/") ? .network : .local
  }
}

struct SourceIOLimits: Sendable {
  /// One boot-volume slot is reserved so a blocked external disk cannot make
  /// the startup volume unreadable to the source layer.
  var bootLocalOutstanding = 1
  var otherLocalOutstanding = 1
  var networkOutstanding = 4
  var networkActive = 2
  var totalOutstanding = 6
  /// Four blocked network calls circuit-break the network lane. The local lane
  /// and local catalog queries remain usable.
  var quarantinedNetworkLimit = 4
  var defaultTimeout: TimeInterval = 45
}

/// Resumes a continuation exactly once. A timed-out operation may still finish
/// later; that late result is discarded while its capacity stays counted.
private final class ResumeOnce<T> {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?
  private var expired = false

  init(_ continuation: CheckedContinuation<T, Error>) {
    self.continuation = continuation
  }

  @discardableResult
  func complete(_ result: Result<T, Error>, beforeResume: () -> Void) -> Bool {
    lock.lock()
    guard let continuation, !expired else {
      lock.unlock()
      return false
    }
    self.continuation = nil
    beforeResume()
    lock.unlock()
    continuation.resume(with: result)
    return true
  }

  /// Returns true when this call won the timeout race. `beforeResume` runs
  /// while the result is still owned by this object, so the quarantine budget
  /// is updated before the awaiting task can observe the count.
  func expire(beforeResume: () -> Void) -> Bool {
    lock.lock()
    guard let continuation, !expired else {
      lock.unlock()
      return false
    }
    expired = true
    self.continuation = nil
    beforeResume()
    lock.unlock()
    continuation.resume(throwing: MediaSourceError.timedOut)
    return true
  }
}

private struct SourceIOTicket {
  let id: UInt64
  let lane: SourceIOLane
  let volumeKey: String
  let isBootVolume: Bool
}

/// A cancellation flag shared between a call and the handler that the task
/// runtime may run on another thread.
private final class SourceIOCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

/// Serial and bounded executor for blocking source calls. It is deliberately
/// not an actor: the whole point is to keep blocking work off the cooperative
/// executor. All mutable state is protected by `lock`.
final class SourceIOExecutor: @unchecked Sendable {
  static let shared = SourceIOExecutor()

  private struct Waiter {
    let id: UInt64
    let lane: SourceIOLane
    let volumeKey: String
    let isBootVolume: Bool
    let continuation: CheckedContinuation<SourceIOTicket, Error>
  }

  private let limits: SourceIOLimits
  private let lock = NSLock()
  private let localQueue = DispatchQueue(label: "UniPlayerSourceIO.local", qos: .utility, attributes: .concurrent)
  private let networkQueue = DispatchQueue(label: "UniPlayerSourceIO.network", qos: .utility, attributes: .concurrent)

  private var nextTicketID: UInt64 = 0
  private var bootActive = 0
  private var otherLocalActive = 0
  private var networkOutstanding = 0
  private var networkActive = 0
  private var quarantinedNetwork = 0
  private var activeVolumes: Set<String> = []
  private var waiters: [Waiter] = []

  init(limits: SourceIOLimits = SourceIOLimits()) {
    self.limits = limits
  }

  var outstandingCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return bootActive + otherLocalActive + networkOutstanding
  }

  var activeNetworkCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return networkActive
  }

  var quarantinedNetworkCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return quarantinedNetwork
  }

  /// Run one blocking source operation. The operation may outlive `timeout`;
  /// when it does, the caller gets `.timedOut` and the operation remains
  /// counted as quarantined until it actually exits. Cancelling the calling
  /// task gives up a queued admission and prevents a queued operation from
  /// starting; an operation already in the kernel still has to exit, because
  /// no portable way to interrupt it exists, and is then counted normally.
  func perform<T>(lane: SourceIOLane, volumeKey: String, isBootVolume: Bool = false,
                  timeout: TimeInterval? = nil,
                  operation: @escaping () throws -> T) async throws -> T {
    let effectiveTimeout = timeout ?? limits.defaultTimeout
    let id = nextID()
    let cancellation = SourceIOCancellation()
    return try await withTaskCancellationHandler {
      let ticket = try await admit(lane: lane, volumeKey: volumeKey,
                                   isBootVolume: isBootVolume,
                                   timeout: effectiveTimeout, id: id,
                                   cancellation: cancellation)
      let queue = lane == .local ? localQueue : networkQueue
      let executor = self

      return try await withCheckedThrowingContinuation { continuation in
        let once = ResumeOnce<T>(continuation)
        queue.async {
          if cancellation.isCancelled {
            let finished = once.complete(.failure(MediaSourceError.cancelled)) {
              executor.release(ticket)
            }
            if !finished { executor.release(ticket) }
            return
          }
          do {
            let value = try operation()
            let finished = once.complete(.success(value)) {
              executor.release(ticket)
            }
            if !finished { executor.release(ticket) }
          } catch {
            let finished = once.complete(.failure(error)) {
              executor.release(ticket)
            }
            if !finished { executor.release(ticket) }
          }
        }
        queue.asyncAfter(deadline: .now() + effectiveTimeout) {
          _ = once.expire {
            executor.quarantine(ticket)
          }
        }
      }
    } onCancel: {
      cancellation.cancel()
      self.cancelWaiter(id: id)
    }
  }

  /// Remove a request that has not been admitted yet. The waiter's own timeout
  /// and this removal race for the same entry under the lock, so exactly one
  /// resumes the continuation.
  private func cancelWaiter(id: UInt64) {
    lock.lock()
    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
      lock.unlock()
      return
    }
    let waiter = waiters.remove(at: index)
    lock.unlock()
    waiter.continuation.resume(throwing: MediaSourceError.cancelled)
  }

  private func admit(lane: SourceIOLane, volumeKey: String,
                     isBootVolume: Bool, timeout: TimeInterval, id: UInt64,
                     cancellation: SourceIOCancellation) async throws -> SourceIOTicket {
    if Task.isCancelled || cancellation.isCancelled {
      throw MediaSourceError.cancelled
    }
    return try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if canAdmitLocked(lane: lane, volumeKey: volumeKey, isBootVolume: isBootVolume) {
        let ticket = takeLocked(id: id, lane: lane, volumeKey: volumeKey, isBootVolume: isBootVolume)
        lock.unlock()
        continuation.resume(returning: ticket)
      } else if lane == .network && quarantinedNetwork >= limits.quarantinedNetworkLimit {
        lock.unlock()
        continuation.resume(throwing: MediaSourceError.quarantined)
      } else if cancellation.isCancelled {
        lock.unlock()
        continuation.resume(throwing: MediaSourceError.cancelled)
      } else {
        waiters.append(Waiter(id: id, lane: lane, volumeKey: volumeKey,
                              isBootVolume: isBootVolume, continuation: continuation))
        lock.unlock()
        // A queued request behind a blocked volume must time out as a user
        // intent too. It owns no kernel call, so it does not consume the
        // quarantine budget.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
          guard let self else { return }
          self.lock.lock()
          guard let index = self.waiters.firstIndex(where: { $0.id == id }) else {
            self.lock.unlock()
            return
          }
          let waiter = self.waiters.remove(at: index)
          self.lock.unlock()
          waiter.continuation.resume(throwing: MediaSourceError.timedOut)
        }
        // Close the gap between the check above and the append: a cancellation
        // that ran during this window found no waiter to remove.
        if cancellation.isCancelled { cancelWaiter(id: id) }
      }
    }
  }

  private func nextID() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    nextTicketID += 1
    return nextTicketID
  }

  private func canAdmitLocked(lane: SourceIOLane, volumeKey: String, isBootVolume: Bool) -> Bool {
    guard !activeVolumes.contains(volumeKey) else { return false }
    guard bootActive + otherLocalActive + networkOutstanding < limits.totalOutstanding else { return false }
    switch lane {
    case .local:
      if isBootVolume { return bootActive < limits.bootLocalOutstanding }
      return otherLocalActive < limits.otherLocalOutstanding
    case .network:
      if quarantinedNetwork >= limits.quarantinedNetworkLimit { return false }
      return networkOutstanding < limits.networkOutstanding && networkActive < limits.networkActive
    }
  }

  private func takeLocked(id: UInt64, lane: SourceIOLane, volumeKey: String,
                          isBootVolume: Bool) -> SourceIOTicket {
    activeVolumes.insert(volumeKey)
    switch lane {
    case .local:
      if isBootVolume { bootActive += 1 } else { otherLocalActive += 1 }
    case .network:
      networkOutstanding += 1
      networkActive += 1
    }
    return SourceIOTicket(id: id, lane: lane, volumeKey: volumeKey,
                          isBootVolume: isBootVolume)
  }

  private func release(_ ticket: SourceIOTicket) {
    lock.lock()
    let wasQuarantined = quarantinedTicketIDs.remove(ticket.id) != nil
    activeVolumes.remove(ticket.volumeKey)
    switch ticket.lane {
    case .local:
      if ticket.isBootVolume { bootActive = max(0, bootActive - 1) }
      else { otherLocalActive = max(0, otherLocalActive - 1) }
    case .network:
      networkOutstanding = max(0, networkOutstanding - 1)
      if wasQuarantined {
        quarantinedNetwork = max(0, quarantinedNetwork - 1)
      } else {
        networkActive = max(0, networkActive - 1)
      }
    }
    drainWaitersLocked()
    lock.unlock()
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .mediaSourceStateDidChange, object: nil)
    }
  }

  /// Mark a timed-out ticket as quarantined. Its volume and lane capacity stay
  /// occupied until the underlying call returns.
  private func quarantine(_ ticket: SourceIOTicket) {
    lock.lock()
    // A ticket can time out only once; make the budget change idempotent.
    let inserted = quarantinedTicketIDs.insert(ticket.id).inserted
    if inserted && ticket.lane == .network {
      quarantinedNetwork += 1
      // A quarantined call no longer counts as one of the two actively
      // executing nonquarantined calls. It still counts outstanding.
      networkActive = max(0, networkActive - 1)
    }
    drainWaitersLocked()
    lock.unlock()
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .mediaSourceStateDidChange, object: nil)
    }
  }

  private var quarantinedTicketIDs: Set<UInt64> = []

  private func drainWaitersLocked() {
    guard !waiters.isEmpty else { return }
    var remaining: [Waiter] = []
    for waiter in waiters {
      if canAdmitLocked(lane: waiter.lane, volumeKey: waiter.volumeKey,
                        isBootVolume: waiter.isBootVolume) {
        let ticket = takeLocked(id: waiter.id, lane: waiter.lane,
                                volumeKey: waiter.volumeKey, isBootVolume: waiter.isBootVolume)
        waiter.continuation.resume(returning: ticket)
      } else if waiter.lane == .network && quarantinedNetwork >= limits.quarantinedNetworkLimit {
        waiter.continuation.resume(throwing: MediaSourceError.quarantined)
      } else {
        remaining.append(waiter)
      }
    }
    waiters = remaining
  }
}
