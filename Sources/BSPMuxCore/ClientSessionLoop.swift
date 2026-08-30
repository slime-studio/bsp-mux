import Foundation

/// Registers `channel` as a new session on `daemon`, drives its messages through
/// `EnvelopeReceiveLoop` for as long as the channel stays open, and deregisters it once the loop
/// ends (clean EOF, a transport error, or a parse failure severe enough that `receive()` itself
/// throws — see `EnvelopeReceiveLoop`'s own doc comment for that distinction). One session ending
/// only ever means that one client disconnected, never that the daemon's own life is over — the
/// backend connection ending is the only thing that means that (see `BackendSessionLoop`).
///
/// Reused identically for the election winner's own stdio (the daemon bootstrap path) and every
/// connection the accept loop hands off afterward - a session over stdio and a session over an
/// accepted socket look exactly alike to `Daemon` already (that's `DuplexChannel`'s whole point),
/// so there's nothing daemon-bootstrap-specific about driving one.
public enum ClientSessionLoop {
  public static func run(daemon: Daemon, channel: any DuplexChannel) async {
    let sessionID = await daemon.registerSession(channel: channel)
    do {
      try await EnvelopeReceiveLoop.run(
        channel: channel,
        onEnvelope: { envelope in try await daemon.handleClientMessage(from: sessionID, envelope: envelope) },
        // No log destination exists yet (see DESIGN.md's Logging section, and Daemon's own
        // build/logMessage handling) - a malformed individual message is deliberately not fatal
        // to the session (EnvelopeReceiveLoop's own contract), so there's nowhere useful to
        // report this yet beyond silently moving on.
        onParseFailure: { _ in }
      )
    } catch {
      // A transport failure or a parse failure severe enough that receive() itself threw - same
      // outcome as a clean EOF from this loop's perspective, since either way the session is over.
    }
    await daemon.deregisterSession(sessionID)
  }
}
