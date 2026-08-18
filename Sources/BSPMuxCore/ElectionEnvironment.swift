import Dependencies
import Foundation

/// A connected socket, owned by whichever process lost the election and became a relay.
public struct ConnectionHandle: Sendable, Equatable {
  public let fileDescriptor: Int32
  public init(fileDescriptor: Int32) { self.fileDescriptor = fileDescriptor }
}

/// A bound, listening socket, owned by whichever process won the election and became daemon.
public struct ListeningHandle: Sendable, Equatable {
  public let fileDescriptor: Int32
  public init(fileDescriptor: Int32) { self.fileDescriptor = fileDescriptor }
}

/// The daemon's exclusive lock, held for its entire lifetime (see `Election`). Deliberately
/// has no `release()` — the only correct way to give it up is process exit, which the kernel
/// turns into an automatic unlock.
public struct LockHandle: Sendable, Equatable {
  public let fileDescriptor: Int32
  public init(fileDescriptor: Int32) { self.fileDescriptor = fileDescriptor }
}

/// The socket/lock/process-identity primitives `Election` needs to run the connect/flock race
/// and become a daemon (`connect`/`acquireLockNonBlocking`/`listen`/`ignoreSIGPIPE`/
/// `detachSession`), plus the process-group signaling a daemon eventually needs at the other end
/// of its life to make sure it doesn't leave anything behind — narrow enough to fake in unit
/// tests. File removal lives on `FileSystemProviding` instead, since deleting a stale socket
/// file isn't election-specific.
public protocol ElectionEnvironment: Sendable {
  /// Attempts to connect to the daemon's socket at `socketPath`. Returns `nil` if nothing is
  /// listening there yet (the socket path doesn't exist, or exists but is stale/refused) —
  /// that's a legitimate "no daemon" signal, not an error. Any other failure throws.
  func connect(to socketPath: String) throws -> ConnectionHandle?

  /// Non-blocking exclusive lock attempt on `lockPath` (creating the file if needed). Returns
  /// `nil` if another process currently holds it — never blocks waiting for it to free up
  /// (see `Election` for why a blocking acquire would be wrong here).
  func acquireLockNonBlocking(atPath lockPath: String) throws -> LockHandle?

  /// Binds and starts listening on `socketPath`. Must only be called while holding the lock
  /// for that same project key, so a concurrent unlink/bind from another process can't race it.
  func listen(at socketPath: String) throws -> ListeningHandle

  /// Ignores `SIGPIPE` for this process. Idempotent.
  func ignoreSIGPIPE()

  /// Detaches this process into its own session (`setsid()`) so it survives its parent exiting.
  func detachSession() throws

  /// Sends `signal` to this process's own process group — deliberately the whole group, not
  /// just this one process — as the backstop that guarantees a spawned backend (and anything
  /// *it* itself spawns) doesn't outlive the daemon as an orphan. Reaches the daemon itself too,
  /// since it's meant to be called as (one of) the daemon's own last acts before it exits, not
  /// from inside its normal operation. Relies on `detachSession()` having already made this
  /// process its own process-group leader — every backend spawned afterward inherits that same
  /// group by default (confirmed empirically against `swift-subprocess`). A pure OS-level
  /// backstop, not a substitute for `Daemon`'s own graceful `build/shutdown`/`build/exit` flow -
  /// that stays the primary path; this is what still runs when the daemon never gets the chance
  /// to attempt that (an external `SIGTERM`/`SIGINT`, or an unexpected internal error).
  func signalOwnProcessGroup(_ signal: Int32)
}

public struct ElectionError: Swift.Error, CustomStringConvertible, Equatable {
  public let description: String

  public init(description: String) {
    self.description = description
  }
}

extension DependencyValues {
  public var electionEnvironment: any ElectionEnvironment {
    get { self[ElectionEnvironmentKey.self] }
    set { self[ElectionEnvironmentKey.self] = newValue }
  }

  private enum ElectionEnvironmentKey: DependencyKey {
    static let liveValue: any ElectionEnvironment = RealElectionEnvironment()
  }
}
