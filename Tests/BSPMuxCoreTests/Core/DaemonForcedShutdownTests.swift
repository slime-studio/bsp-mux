import Clocks
import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

/// `Daemon.requestForcedShutdown`/the `bspMux/stop` message that triggers it - split out from
/// `DaemonTests` (which covers the rest of `Daemon`'s id-rewrite/notification-routing/lifecycle
/// behavior) once this grew into its own cohesive chunk, to keep both files under SwiftLint's
/// length limits.
@Suite struct DaemonForcedShutdownTests {
  static func request(id: String, method: String) throws -> JSONRPCEnvelope {
    let raw = Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":{}}"#.utf8)
    return try JSONRPCEnvelope(rawBytes: raw)
  }

  @Test func requestForcedShutdownFailsInFlightRequestsAndRecordsWhetherHardKillWasWanted() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)

    try await daemon.handleClientMessage(from: session, envelope: Self.request(id: #""abc""#, method: "buildTarget/sources"))
    #expect(await backend.sentMessages.count == 1)

    #expect(await daemon.forcedShutdown == .none)
    async let shutdown: Void = daemon.waitForShutdown()
    await daemon.requestForcedShutdown(hardKill: true)
    await shutdown

    #expect(await daemon.forcedShutdown == .requested(hardKill: true))
    let toClient = await clientChannel.sentMessages
    #expect(toClient.count == 1)
    let replyString = try String(bytes: JSONRPCEnvelope(rawBytes: toClient[0]).rawBytes, encoding: .utf8)
    // An intentional admin stop, not the backend dying unexpectedly - must not reuse that wording.
    #expect(replyString?.contains("administrative request") == true)
    #expect(replyString?.contains("disconnected unexpectedly") == false)
  }

  @Test func requestForcedShutdownWithoutHardKillGivesTheBackendARealShutdownExitRoundTrip() async throws {
    let backend = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)

    async let shutdown: Void = daemon.waitForShutdown()
    await daemon.requestForcedShutdown(hardKill: false)
    await shutdown

    let toBackend = await backend.sentMessages
    #expect(toBackend.count == 2)
    #expect(try JSONRPCEnvelope(rawBytes: toBackend[0]).method == .buildShutdown)
    #expect(try JSONRPCEnvelope(rawBytes: toBackend[1]).method == .buildExit)
  }

  @Test func concurrentRequestForcedShutdownCallsOnlySendTheBackendOneShutdownExitPair() async throws {
    // Two bspMux/stop messages arriving close together (or one racing performShutdown's idle
    // timeout) must not each independently pass the "nothing's shutting down yet" guard and
    // duplicate the backend round trip - answers the PR review's "what happens if several
    // shutdown requests arrive around the same time?".
    let backend = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)

    async let first: Void = daemon.requestForcedShutdown(hardKill: false)
    async let second: Void = daemon.requestForcedShutdown(hardKill: false)
    _ = await (first, second)

    let toBackend = await backend.sentMessages
    #expect(toBackend.count == 2)
    #expect(try JSONRPCEnvelope(rawBytes: toBackend[0]).method == .buildShutdown)
    #expect(try JSONRPCEnvelope(rawBytes: toBackend[1]).method == .buildExit)
  }

  @Test func requestForcedShutdownRacingHandleBackendDisconnectedOnlyOneWins() async throws {
    // A backend crash racing an admin `bsp-mux stop` for the same daemon - whichever of the two
    // shutdown paths the actor runs first must exclude the other, not just itself.
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)
    try await daemon.handleClientMessage(from: session, envelope: Self.request(id: #""abc""#, method: "buildTarget/sources"))

    async let forced: Void = daemon.requestForcedShutdown(hardKill: false)
    async let disconnected: Void = daemon.handleBackendDisconnected()
    _ = await (forced, disconnected)

    // Whichever path won, the in-flight request got exactly one failure response, not one from
    // each (which would mean both paths ran their own failPendingWork over the same request).
    #expect(await clientChannel.sentMessages.count == 1)
  }

  @Test func requestForcedShutdownWithHardKillSkipsTheGracefulBackendRoundTrip() async throws {
    // --force exists for a backend that's unresponsive/ignoring SIGTERM - asking it nicely
    // first via BSP would just be more of what it's already not responding to.
    let backend = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)

    async let shutdown: Void = daemon.waitForShutdown()
    await daemon.requestForcedShutdown(hardKill: true)
    await shutdown

    #expect(await backend.sentMessages.isEmpty)
  }

  @Test func bspMuxStopMessageDispatchesToRequestForcedShutdownWithTheRequestedForceFlag() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)

    let stopMessage = try JSONRPCEnvelope(
      rawBytes: Data(#"{"jsonrpc":"2.0","method":"bspMux/stop","params":{"force":true}}"#.utf8))
    async let shutdown: Void = daemon.waitForShutdown()
    try await daemon.handleClientMessage(from: session, envelope: stopMessage)
    await shutdown

    #expect(await daemon.forcedShutdown == .requested(hardKill: true))
  }

  @Test func bspMuxStopMessageWithoutForceRequestsAGracefulSignal() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)

    let stopMessage = try JSONRPCEnvelope(
      rawBytes: Data(#"{"jsonrpc":"2.0","method":"bspMux/stop","params":{"force":false}}"#.utf8))
    async let shutdown: Void = daemon.waitForShutdown()
    try await daemon.handleClientMessage(from: session, envelope: stopMessage)
    await shutdown

    #expect(await daemon.forcedShutdown == .requested(hardKill: false))
  }
}
