import Clocks
import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct DaemonBootstrapTests {
  /// A `Task { }` created inside `operation` captures the overridden dependencies at creation
  /// time and keeps them for its own full lifetime, independent of `withDependencies`' own
  /// dynamic scope ending - the same reasoning `RealBackendSpawning.spawn`'s own detached task
  /// already relies on. `continuousClock` has to be overridden here too, alongside
  /// `backendSpawning`: a test ending a session via `finishIncoming()` below drives it to
  /// `deregisterSession`, which starts `Daemon`'s idle-grace timer - without this, that timer
  /// reads the real (unimplemented-in-tests) clock and traps, exactly like
  /// `DaemonTests`/`ClientSessionLoopTests` already have to guard against for the same reason.
  static func withTestDependencies<R>(
    backendSpawning: FakeBackendSpawning, operation: () async throws -> R
  ) async rethrows -> R {
    try await withDependencies {
      $0.backendSpawning = backendSpawning
      $0.continuousClock = TestClock()
    } operation: {
      try await operation()
    }
  }

  @Test func spawnsWithTheGivenArgvAndWorkingDirectory() async throws {
    let backend = FakeDuplexChannel(remainsOpenWhenExhausted: true)
    let winnerChannel = FakeDuplexChannel(remainsOpenWhenExhausted: true)
    let spawning = FakeBackendSpawning(results: [.success(backend)])

    _ = try await Self.withTestDependencies(backendSpawning: spawning) {
      try await DaemonBootstrap.start(
        argv: ["/usr/bin/backend", "serve"], workspaceRoot: "/tmp/project", winnerChannel: winnerChannel
      )
    }

    #expect(spawning.spawnCalls.count == 1)
    #expect(spawning.spawnCalls[0].argv == ["/usr/bin/backend", "serve"])
    #expect(spawning.spawnCalls[0].workingDirectory == "/tmp/project")

    await backend.finishIncoming()
    await winnerChannel.finishIncoming()
  }

  @Test func spawnFailurePropagates() async throws {
    let winnerChannel = FakeDuplexChannel(remainsOpenWhenExhausted: true)
    let spawning = FakeBackendSpawning(results: [.failure(BackendSpawnError(description: "no such executable"))])

    await #expect(throws: BackendSpawnError.self) {
      try await Self.withTestDependencies(backendSpawning: spawning) {
        try await DaemonBootstrap.start(argv: ["/nonexistent"], workspaceRoot: "/tmp/project", winnerChannel: winnerChannel)
      }
    }

    await winnerChannel.finishIncoming()
  }

  @Test func winnersInitializeRoundTripsThroughTheRealDaemonWiring() async throws {
    // Proves DaemonBootstrap actually WIRED the pieces (backend spawned, Daemon constructed,
    // winner's session registered and driven, backend's own loop driven) rather than merely
    // constructing them - the winner's build/initialize request has to travel through the real
    // ClientSessionLoop -> Daemon.handleClientMessage -> BackendSessionLoop -> back again, with
    // nothing in the test calling Daemon's methods directly.
    let backend = FakeDuplexChannel(remainsOpenWhenExhausted: true)
    let winnerChannel = FakeDuplexChannel(remainsOpenWhenExhausted: true)
    let spawning = FakeBackendSpawning(results: [.success(backend)])

    let initializeRequestJSON =
      #"{"jsonrpc":"2.0","id":"1","method":"build/initialize","params":{"displayName":"editor","version":"1.0","#
      + #""bspVersion":"2.1.0","rootUri":"file:///workspace","capabilities":{}}}"#
    let initializeRequest = Data(initializeRequestJSON.utf8)
    await winnerChannel.enqueueIncoming(initializeRequest)

    _ = try await Self.withTestDependencies(backendSpawning: spawning) {
      try await DaemonBootstrap.start(
        argv: ["/usr/bin/backend", "serve"], workspaceRoot: "/tmp/project", winnerChannel: winnerChannel
      )
    }

    // The daemon mints backend-facing request ids starting at "0" - deterministic, since this
    // is the very first request this Daemon instance ever forwards.
    let forwardedBytes = await backend.waitForNextSentMessage()
    let forwarded = try JSONRPCEnvelope(rawBytes: forwardedBytes)
    #expect(forwarded.method == "build/initialize")

    // rawText already carries whatever raw JSON representation the id used (mintBackendRequestID
    // produces a bare number, not a quoted string) - no extra quotes here, matching
    // DaemonTests/DaemonLifecycleTests' own response(id:)/initializeResponse(id:) helpers.
    let backendResponse = Data(
      #"{"jsonrpc":"2.0","id":\#(forwarded.id!.rawText),"result":{"displayName":"backend","version":"1.0","bspVersion":"2.1.0","capabilities":{}}}"#
        .utf8)
    await backend.enqueueIncoming(backendResponse)

    let replyBytes = await winnerChannel.waitForNextSentMessage()
    let reply = try JSONRPCEnvelope(rawBytes: replyBytes)
    #expect(reply.id == JSONRPCRawID(rawText: #""1""#))  // the original request's id was the JSON string "1"

    await backend.finishIncoming()
    await winnerChannel.finishIncoming()
  }

  @Test func backendDisconnectingEventuallyResolvesDaemonShutdown() async throws {
    let backend = FakeDuplexChannel(remainsOpenWhenExhausted: true)
    let winnerChannel = FakeDuplexChannel(remainsOpenWhenExhausted: true)
    let spawning = FakeBackendSpawning(results: [.success(backend)])

    let daemon = try await Self.withTestDependencies(backendSpawning: spawning) {
      try await DaemonBootstrap.start(
        argv: ["/usr/bin/backend", "serve"], workspaceRoot: "/tmp/project", winnerChannel: winnerChannel
      )
    }

    // The backend process dying is exactly this: its channel has nothing more to give.
    await backend.finishIncoming()
    await daemon.waitForShutdown()

    await winnerChannel.finishIncoming()
  }
}
