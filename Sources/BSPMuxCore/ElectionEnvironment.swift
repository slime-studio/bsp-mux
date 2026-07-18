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

/// The socket/lock/process primitives `Election` needs, narrow enough to fake in unit tests.
/// File removal lives on `FileSystemProviding` instead, since deleting a stale socket file
/// isn't election-specific.
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
