import Dependencies
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Accepts new client connections on the daemon's listening socket for as long as the daemon
/// runs, handing each one off to its own `ClientSessionLoop` - the piece `DaemonBootstrap`'s own
/// doc comment used to describe as "a separate, later piece" beyond the winner's own session.
/// Reused identically with the winner's own stdio session: a session over an accepted socket
/// looks exactly like one over stdio to `Daemon` already, since both are just a `DuplexChannel`.
///
/// Ending this loop is **not** daemon-fatal, mirroring `ClientSessionLoop`'s own framing ("one
/// session ending only ever means that one client disconnected, never that the daemon's own life
/// is over"): `accept()` failing only means no *future* new clients can join. Already-connected
/// sessions and the backend connection are unaffected, and nothing here ever reports this to
/// `Daemon` - there's nothing for it to react to.
///
/// `listening.fileDescriptor` is deliberately never closed here - same rule as the lock fd (see
/// `ElectionEnvironment`'s doc comment): process exit is the only correct release. Stated
/// explicitly so a later close doesn't get added that races a pending `accept()`.
///
/// Each accepted connection's `defer { close(...) }` can run without its `RealByteSource` having
/// been explicitly cancelled first. The read side is provably safe regardless: `RealByteSource`
/// only self-cancels on EOF/read-error, and that self-cancellation is exactly what lets
/// `ClientSessionLoop.run` return in the first place - so by the time this `defer` fires, the
/// read side's `DispatchSourceRead` is already inert. The write side is the real theoretical gap:
/// a concurrent in-flight `RealByteSink.write()` (e.g. `BackendSessionLoop` routing a response to
/// this same client at the exact moment its read side hits EOF) could still be registered when
/// `close` runs. `RelaySession` already carries the identical risk for its own connection and
/// resolved it the same way this does - "confirmed via stress runs this doesn't misbehave: kqueue
/// automatically drops a filter when its fd closes, so the abandoned source goes silently inert
/// rather than ever observing whatever the fd number gets reused for next." The one thing that
/// reasoning does *not* carry over automatically: `RelaySession` also notes this is "irrelevant
/// here since a relay process has nothing left to do afterward anyway" - untrue for a daemon,
/// which keeps running and immediately hands the freed fd number to the *next* `accept()`. That's
/// exactly why `AcceptLoopTests` includes its own stress case (many sequential connections,
/// asserting every response reaches its own session) rather than resting on `RelaySession`'s
/// verification alone.
public enum AcceptLoop {
  public static func run(daemon: Daemon, listening: ListeningHandle) async {
    @Dependency(\.socketAccepting) var socketAccepting

    while true {
      let connection: ConnectionHandle
      do {
        connection = try await socketAccepting.accept(on: listening)
      } catch {
        return
      }

      let stream = RealDuplexByteStream(fileDescriptor: connection.fileDescriptor)
      let channel = FramedDuplexChannel(source: stream, sink: stream)
      Task {
        defer { close(connection.fileDescriptor) }
        await ClientSessionLoop.run(daemon: daemon, channel: channel)
      }
    }
  }
}
