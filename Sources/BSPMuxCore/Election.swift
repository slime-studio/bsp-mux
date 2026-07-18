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
/// The lock is acquired non-blocking on the loser's side and, once won, held for the daemon's
/// entire lifetime rather than just across the critical section. A blocking acquire would
/// deadlock the moment a second editor window opens while the first is still running, since
/// the winner never releases the lock. Holding it for the daemon's whole life also makes
/// "lock held" an always-valid liveness signal (not just "someone won the initial race"),
/// which matters if the socket file itself gets deleted out from under a live daemon — a
/// contender then knows not to start a second one and keeps polling `connect()` instead. It's
/// also why acquiring the lock is sufficient proof no live daemon exists, with no need to
/// double-check `connect()` again afterward.
public struct Election: Sendable {
  private let paths: ProjectPaths
  private let environment: ElectionEnvironment
  private let fileSystem: FileSystemProviding
  private let pollInterval: TimeInterval
  private let sleep: @Sendable (TimeInterval) -> Void

  public init(
    paths: ProjectPaths,
    environment: ElectionEnvironment = RealElectionEnvironment(),
    fileSystem: FileSystemProviding = RealFileSystem(),
    pollInterval: TimeInterval = 0.02,
    sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) {
    self.paths = paths
    self.environment = environment
    self.fileSystem = fileSystem
    self.pollInterval = pollInterval
    self.sleep = sleep
  }

  public func run() throws -> ElectionOutcome {
    while true {
      if let connection = try environment.connect(to: paths.socketPath) {
        return .relay(connection)
      }

      if let lock = try environment.acquireLockNonBlocking(atPath: paths.lockPath) {
        fileSystem.remove(atPath: paths.socketPath)
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
