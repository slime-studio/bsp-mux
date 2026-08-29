import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The loser-of-election path wired to real file descriptors: relays between this process's own
/// stdio and the daemon's socket connection returned by `Election.run()`'s `.relay` case. Thin
/// glue over `Relay`/`RealDuplexByteStream` — what's specific here is owning `connection`'s
/// lifetime, since `Election`/`ElectionEnvironment` hand it back as a caller-owned resource with
/// nothing else closing it.
///
/// `standardIn`/`standardOut` are taken as already-constructed streams rather than defaulted to
/// real fds 0/1 here, so tests can inject real-pipe-backed streams instead of hijacking the test
/// runner's own stdio — the literal fd 0/1 wiring belongs to whoever constructs these for a real
/// process (the CLI entry point), not to this type.
public enum RelaySession {
  public static func run(
    connection: ConnectionHandle,
    standardIn: any ByteSource,
    standardOut: any ByteSink
  ) async throws {
    // When the relay ends via the socket's own EOF, its `RealByteSource` has already cancelled
    // its underlying `DispatchSourceRead` by the time this `defer` runs. When it ends via
    // `standardIn` or an error instead, `Relay`'s `group.cancelAll()` only stops the Swift task
    // reading the socket (confirmed empirically: `AsyncStream.Iterator.next()` returns promptly
    // on task cancellation) - the GCD-level read source itself is never told to stop and is left
    // registered on `connection.fileDescriptor` when it's closed here. Confirmed via stress runs
    // this doesn't misbehave: kqueue automatically drops a filter when its fd closes, so the
    // abandoned source goes silently inert rather than ever observing whatever the fd number
    // gets reused for next - just a small leaked source+queue for the remainder of the process,
    // which is irrelevant here since a relay process has nothing left to do afterward anyway.
    defer { close(connection.fileDescriptor) }
    try await Relay.run(
      standardIn: standardIn,
      standardOut: standardOut,
      socket: RealDuplexByteStream(fileDescriptor: connection.fileDescriptor)
    )
  }
}
