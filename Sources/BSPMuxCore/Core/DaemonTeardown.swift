import Dependencies

public enum ShutdownReason: Sendable, Equatable {
  /// Idle-timeout or backend-disconnect - `Daemon` already best-effort attempted a graceful
  /// `build/shutdown`/`build/exit` round trip with the backend before resolving.
  case normal
  /// An external SIGTERM/SIGINT arrived - no graceful attempt was possible.
  case signal(Int32)
}

/// What runs once a daemon process is done, on both the graceful and abrupt paths - the natural
/// counterpart to `DaemonBootstrap`. Per DESIGN.md's crash-path spec ("close everything, unlink
/// the socket, and exit"): no fd gets explicitly closed here (process exit reclaims the whole fd
/// table - same "deliberately never closed here" rule already documented for the lock and
/// listening fds), only the socket's named filesystem entry needs explicit cleanup, since the OS
/// won't reclaim that on its own. Order is load-bearing and guaranteed by being plain sequential
/// statements (no actual concurrency inside this function): unlink before signaling the group,
/// both before exiting.
public enum DaemonTeardown {
  public static func run(reason: ShutdownReason, socketPath: String) async {
    @Dependency(\.fileSystem) var fileSystem
    @Dependency(\.electionEnvironment) var electionEnvironment
    @Dependency(\.processExiting) var processExiting

    fileSystem.remove(atPath: socketPath)

    // Only the signal path force-signals the backend's process group. The normal path already
    // sent a graceful `build/shutdown`/`build/exit` - signaling the group here too would race
    // that attempt instead of giving it a chance to work.
    if case .signal(let signal) = reason {
      electionEnvironment.signalOwnProcessGroup(signal)
    }

    processExiting.exit(0)
  }
}
