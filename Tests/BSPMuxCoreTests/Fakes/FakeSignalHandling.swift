@testable import BSPMuxCore

/// Records registered signals and lets a test synchronously simulate one arriving via `fire(_:)`
/// - the mechanism that lets a test exercise "a SIGTERM arrived" with zero real signals.
final class FakeSignalHandling: SignalHandling, @unchecked Sendable {
  private(set) var registeredSignals: [Int32] = []
  private var handlers: [Int32: @Sendable () -> Void] = [:]
  private var registrationWaiters: [CheckedContinuation<Void, Never>] = []

  func onSignal(_ signal: Int32, perform: @escaping @Sendable () -> Void) {
    registeredSignals.append(signal)
    handlers[signal] = perform
    let toWake = registrationWaiters
    registrationWaiters = []
    for waiter in toWake { waiter.resume() }
  }

  func fire(_ signal: Int32) {
    handlers[signal]?()
  }

  /// Suspends until at least `count` signals have been registered - lets a test that races a
  /// concurrently-running `.daemon` case's own registration avoid polling for it, mirroring
  /// `FakeDuplexChannel.waitForNextSentMessage()`'s own continuation-based waiter pattern.
  func waitForRegistrations(count: Int) async {
    while registeredSignals.count < count {
      await withCheckedContinuation { registrationWaiters.append($0) }
    }
  }
}
