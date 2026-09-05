import Dependencies

/// Registers a callback for a POSIX signal (SIGTERM/SIGINT). A port rather than a direct
/// `DispatchSource` call because real signal delivery can't safely be exercised inside the test
/// runner's own process - the real implementation's `signal(sig, SIG_IGN)` prerequisite (see
/// `RealSignalHandling`) would suppress the test runner's own signal handling for the rest of
/// that process's life.
public protocol SignalHandling: Sendable {
  /// `perform` runs on an arbitrary background queue, not the caller's task - callers that need
  /// to run `async` work in response should spawn their own `Task`.
  func onSignal(_ signal: Int32, perform: @escaping @Sendable () -> Void)
}

extension DependencyValues {
  public var signalHandling: any SignalHandling {
    get { self[SignalHandlingKey.self] }
    set { self[SignalHandlingKey.self] = newValue }
  }

  private enum SignalHandlingKey: DependencyKey {
    static let liveValue: any SignalHandling = RealSignalHandling()
  }
}
