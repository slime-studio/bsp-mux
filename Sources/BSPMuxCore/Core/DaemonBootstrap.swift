import Dependencies
import Foundation

/// The winner-of-election path: given `Election.run()`'s `.daemon(ListeningHandle, LockHandle)`
/// outcome, spawns the real backend, constructs the `Daemon` that will multiplex every session
/// onto it, and starts driving the backend's own connection, the winner's own session, and every
/// subsequent client the accept loop hands off - the three loops that exist for the daemon's
/// entire life.
///
/// Deliberately returns once launched rather than blocking until the daemon's life ends (mirrors
/// `RealBackendSpawning.spawn`'s own "returns once launched, keeps running via a background task"
/// shape) - a daemon runs several concurrent, independently-ending things on one shared `Daemon`
/// actor (the backend connection, every client session, the accept loop, the shutdown wait), so
/// this can't itself block on any single one of them without preventing whatever calls it from
/// composing the rest alongside it.
///
/// All three loops' `Task` handles are intentionally discarded, not kept for later cancellation:
/// in the ordinary paths, each ends itself (the backend's own EOF/error ends
/// `BackendSessionLoop`; a client disconnecting ends its own `ClientSessionLoop`; `AcceptLoop`
/// only ends if the listening socket itself breaks, which isn't daemon-fatal - see its own doc
/// comment). If the backend dies while other clients are still connected, though, there's no
/// handle left to reach into their still-blocked `receive()` calls and cancel them - per
/// DESIGN.md, a dead backend means the whole daemon exits regardless ("fail all in-flight
/// requests... close everything... and exit"), so teardown at that point is expected to be the
/// process actually exiting (reclaiming everything), not a graceful cancel-and-join of every
/// session's loop first.

public enum DaemonBootstrap {
  public static func start(
    argv: [String],
    workspaceRoot: String,
    listening: ListeningHandle,
    winnerChannel: any DuplexChannel
  ) async throws -> Daemon {
    @Dependency(\.backendSpawning) var backendSpawning
    let backend = try await backendSpawning.spawn(argv: argv, workingDirectory: workspaceRoot)
    let daemon = Daemon(backend: backend)

    Task { await BackendSessionLoop.run(daemon: daemon, backend: backend) }
    Task { await ClientSessionLoop.run(daemon: daemon, channel: winnerChannel) }
    Task { await AcceptLoop.run(daemon: daemon, listening: listening) }

    return daemon
  }
}
