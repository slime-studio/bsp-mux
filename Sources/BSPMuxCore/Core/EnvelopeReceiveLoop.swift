import Foundation

/// Drives one `DuplexChannel`'s `receive()` loop, parsing each complete message body into a
/// `JSONRPCEnvelope` and handing it to `onEnvelope` - the thing `Daemon`'s own doc comments
/// call "the not-yet-built receive loop" that parsing and failure policy were deliberately left
/// to. One generic loop, reused for both a client session and the backend connection: what
/// differs between them (deregistering one session and continuing versus failing everything and
/// exiting the daemon) is policy that belongs to whoever calls this, not to the loop itself.
///
/// A malformed *individual* message doesn't end the loop: `MessageFraming`/`FramedDuplexChannel`
/// already delimited its byte boundaries correctly by the time `receive()` returns it, so a
/// parse failure means only that one message's content was bad, not that the stream is broken -
/// reported via `onParseFailure`, then the loop moves on to the next message. Everything else
/// ends the loop and propagates to the caller: a clean EOF (`receive()` returns `nil`),
/// `receive()` itself throwing (a transport failure, or a connection that died mid-frame), or
/// `onEnvelope` throwing (e.g. `Daemon` failing to relay a reply because its own channel broke).
public enum EnvelopeReceiveLoop {
  public static func run(
    channel: any DuplexChannel,
    onEnvelope: (JSONRPCEnvelope) async throws -> Void,
    onParseFailure: (Error) -> Void
  ) async throws {
    while let body = try await channel.receive() {
      let envelope: JSONRPCEnvelope
      do {
        envelope = try JSONRPCEnvelope(rawBytes: body)
      } catch {
        // Scoped to just the parse step, deliberately: onEnvelope's own errors (e.g. Daemon
        // failing to relay a reply because its channel broke) must always propagate, even if
        // onEnvelope happens to throw a JSONRPCEnvelopeError for an unrelated reason - that's
        // not "this one message was malformed," it's a real failure the caller needs to see.
        onParseFailure(error)
        continue
      }
      try await onEnvelope(envelope)
    }
  }
}
