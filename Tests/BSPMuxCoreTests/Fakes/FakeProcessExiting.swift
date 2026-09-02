@testable import BSPMuxCore

/// Records `exit` calls instead of actually terminating the test process.
final class FakeProcessExiting: ProcessExiting, @unchecked Sendable {
  private(set) var exitCodes: [Int32] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func exit(_ code: Int32) {
    exitCodes.append(code)
    let toWake = waiters
    waiters = []
    for waiter in toWake { waiter.resume() }
  }

  /// Suspends until `exit` has been called at least once - lets a test await a signal-triggered
  /// `DaemonTeardown`'s own unstructured `Task` reaching `exit` without polling for it, mirroring
  /// `FakeDuplexChannel.waitForNextSentMessage()`'s own continuation-based waiter pattern.
  func waitForExit() async {
    while exitCodes.isEmpty {
      await withCheckedContinuation { waiters.append($0) }
    }
  }
}
