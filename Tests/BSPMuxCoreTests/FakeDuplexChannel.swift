import Foundation

@testable import BSPMuxCore

/// In-memory `DuplexChannel` fake: `send` records every message body for assertions, and
/// `receive` yields whatever's been queued via `enqueueIncoming`. An actor (not a class)
/// since `DuplexChannel` requires `Sendable` conformances, and this holds genuinely mutable
/// state `Daemon` calls into concurrently across sessions.
///
/// `remainsOpenWhenExhausted` mirrors `FakeByteStream`'s own flag of the same name and for the
/// same reason: the default (`false`) preserves every existing test's "drain the queue, then
/// receive() returns nil immediately" behavior, but a caller driving a loop that's meant to keep
/// running across several separately-timed `enqueueIncoming` calls (e.g. testing `DaemonBootstrap`'s
/// detached background loops, where a response can only be enqueued after the request that
/// produces it has actually been forwarded) needs `receive()` to suspend and wait for more
/// instead of ending the loop the moment the queue is momentarily empty. `finishIncoming()` is
/// the explicit opt-in counterpart - only meaningful (and only needed) when this flag is set.
actor FakeDuplexChannel: DuplexChannel {
  private(set) var sentMessages: [Data] = []
  private var pendingIncoming: [Data] = []
  private var readError: Error?
  private let remainsOpenWhenExhausted: Bool
  private var isFinished = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(readError: Error? = nil, remainsOpenWhenExhausted: Bool = false) {
    self.readError = readError
    self.remainsOpenWhenExhausted = remainsOpenWhenExhausted
  }

  func send(_ body: Data) async throws {
    sentMessages.append(body)
  }

  func receive() async throws -> Data? {
    if let error = readError {
      readError = nil
      throw error
    }
    while pendingIncoming.isEmpty {
      guard remainsOpenWhenExhausted, !isFinished else { return nil }
      await withCheckedContinuation { waiters.append($0) }
    }
    return pendingIncoming.removeFirst()
  }

  func enqueueIncoming(_ data: Data) {
    pendingIncoming.append(data)
    wakeWaiters()
  }

  /// Only meaningful alongside `remainsOpenWhenExhausted: true` - ends the channel (any
  /// currently-suspended or future `receive()` call returns `nil`) once the queue drains,
  /// rather than staying open forever.
  func finishIncoming() {
    isFinished = true
    wakeWaiters()
  }

  private func wakeWaiters() {
    let toWake = waiters
    waiters = []
    for waiter in toWake { waiter.resume() }
  }
}
