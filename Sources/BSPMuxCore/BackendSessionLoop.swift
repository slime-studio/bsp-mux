import Foundation

/// Drives the single backend connection's messages through `EnvelopeReceiveLoop` for as long as
/// it stays open. Unlike `ClientSessionLoop`, this ending always means the daemon's own life is
/// over — there's exactly one backend connection per daemon, and DESIGN.md is explicit that a
/// dead backend fails every in-flight request and tears the whole daemon down rather than trying
/// to respawn it in place - `Daemon.handleBackendDisconnected()` is what actually resolves that.
public enum BackendSessionLoop {
  public static func run(daemon: Daemon, backend: any DuplexChannel) async {
    do {
      try await EnvelopeReceiveLoop.run(
        channel: backend,
        onEnvelope: { envelope in try await daemon.handleBackendMessage(envelope: envelope) },
        // Same "nowhere to report this yet" reasoning as ClientSessionLoop.
        onParseFailure: { _ in }
      )
    } catch {
      // A transport failure ending the loop - same as a clean EOF for our purposes: the backend
      // is gone either way.
    }
    await daemon.handleBackendDisconnected()
  }
}
