import Foundation

public enum ElectionOutcome: Sendable, Equatable {
  /// Lost the election (or won it outright with no contention): a live daemon is listening at
  /// this connection.
  case relay(ConnectionHandle)
  /// Won the election: this process is now the daemon, holding `lock` for its entire
  /// remaining lifetime.
  case daemon(ListeningHandle, LockHandle)
}

/// The connect/flock race described in DESIGN.md's "Election race": every process launched
/// for a project either finds a live daemon and becomes a relay, or becomes the daemon itself.
///
/// The lock is acquired non-blocking, never blocking, on the loser's side, and — once won —
/// held for the daemon's entire lifetime rather than just across the critical section. Both
/// choices are load-bearing, not incidental:
///
/// - A *blocking* acquire would be correct for the instant of the race but wrong for
///   everything after: since the winner holds the lock for its whole life, a blocking loser
///   would hang until the daemon exits, not until it finishes `listen()` — deadlocking the
///   project's primary scenario (a second editor window opened while the first is still
///   running).
/// - Holding the lock for the daemon's whole life (rather than releasing right after
///   `listen()`) turns "lock held" into an always-valid "a daemon is alive right now" signal,
///   not just "someone won the initial race." That matters because the socket file itself can
///   be invalidated out from under a live daemon (e.g. external cleanup under `/tmp`) without
///   the daemon knowing; a contender that finds the socket gone but the lock still held knows
///   definitively not to start a second daemon, and keeps polling `connect()` instead. It also
///   means acquiring the lock is itself sufficient proof no live daemon exists — a live one
///   would still be holding it — so there's no need to double-check `connect()` again
///   afterward.
public struct Election: Sendable {
  private let paths: ProjectPaths
  private let environment: ElectionEnvironment
  private let pollInterval: TimeInterval
  private let sleep: @Sendable (TimeInterval) -> Void

  public init(
    paths: ProjectPaths,
    environment: ElectionEnvironment = RealElectionEnvironment(),
    pollInterval: TimeInterval = 0.02,
    sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) {
    self.paths = paths
    self.environment = environment
    self.pollInterval = pollInterval
    self.sleep = sleep
  }

  public func run() throws -> ElectionOutcome {
    while true {
      if let connection = try environment.connect(to: paths.socketPath) {
        return .relay(connection)
      }

      if let lock = try environment.acquireLockNonBlocking(atPath: paths.lockPath) {
        environment.unlinkIfExists(paths.socketPath)
        // bind()+listen() before spawning the backend, so racing connects can queue instead
        // of serializing behind backend startup latency (spawning happens in the caller).
        let listening = try environment.listen(at: paths.socketPath)
        environment.ignoreSIGPIPE()
        try environment.detachSession()
        return .daemon(listening, lock)
      }

      // Neither connected nor won the lock: another process is either mid-election or is
      // already the live daemon (about to finish `listen()`), or the previous lock holder
      // died mid-startup and will free up on the next iteration. Poll rather than block.
      sleep(pollInterval)
    }
  }
}
