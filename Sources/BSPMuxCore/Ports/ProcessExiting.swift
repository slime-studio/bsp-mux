import Dependencies

/// Terminates the current process. A separate port (rather than calling `Foundation.exit`
/// directly from `DaemonTeardown`) because a real process exit can't safely run inside the test
/// runner's own process - it would kill the test runner along with whatever it's testing.
public protocol ProcessExiting: Sendable {
  /// Not `-> Never`: the real implementation's body still ends in a call to the real, terminating
  /// `exit()` (Swift allows a `Never`-typed expression as the final statement of a `Void`-
  /// returning function), but a `Void` signature lets a Fake record the call and return normally
  /// - which is what makes this testable at all. A `Never`-typed fake would have to actually
  /// terminate the test process to conform.
  func exit(_ code: Int32)
}

extension DependencyValues {
  public var processExiting: any ProcessExiting {
    get { self[ProcessExitingKey.self] }
    set { self[ProcessExitingKey.self] = newValue }
  }

  private enum ProcessExitingKey: DependencyKey {
    static let liveValue: any ProcessExiting = RealProcessExiting()
  }
}
