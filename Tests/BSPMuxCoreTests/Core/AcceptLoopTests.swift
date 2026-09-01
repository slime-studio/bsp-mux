import Clocks
import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct AcceptLoopTests {
  private static func requestBody(id: String, method: String) -> Data {
    Data(#"{"jsonrpc":"2.0","id":"\#(id)","method":"\#(method)","params":{}}"#.utf8)
  }

  /// Mirrors `RelaySessionTests`/`RealDuplexByteStreamTests`/`RealBSPMuxApplicationTests`'s own
  /// helper: a real, connected `AF_UNIX` socket pair standing in for what a real `accept()` would
  /// hand back.
  private static func withConnectedSocketPair(
    _ body: (ConnectionHandle, ConnectionHandle) async throws -> Void
  ) async throws {
    let path = "/tmp/bsp-mux-accept-loop-test-\(UUID().uuidString).sock"
    defer { unlink(path) }

    let environment = RealElectionEnvironment()
    let listening = try environment.listen(at: path)
    defer { close(listening.fileDescriptor) }

    async let accepted = RealSocketAccepting().accept(on: listening)
    guard let clientConnection = try environment.connect(to: path) else {
      Issue.record("expected connect() to succeed against a live listener")
      return
    }

    let serverConnection = try await accepted
    try await body(clientConnection, serverConnection)
  }

  private static func clientChannel(over connection: ConnectionHandle) -> FramedDuplexChannel {
    let stream = RealDuplexByteStream(fileDescriptor: connection.fileDescriptor)
    return FramedDuplexChannel(source: stream, sink: stream)
  }

  /// Spawns both background loops `AcceptLoop` needs alongside it to be exercised end to end -
  /// `BackendSessionLoop` (nothing calls `Daemon.handleBackendMessage` without it; unlike
  /// `DaemonTests`, which calls `Daemon`'s methods directly, these tests drive the real loops) -
  /// under one shared `withDependencies` scope, matching `DaemonBootstrap.start`'s own reasoning
  /// for why every `Task {}` it spawns has to be created inside the same scope: each captures
  /// the overridden dependencies at creation time, independent of `withDependencies`' own dynamic
  /// scope ending. `continuousClock` has to be overridden here for the same reason
  /// `DaemonBootstrapTests.withTestDependencies` does: a client disconnecting drives
  /// `deregisterSession`, which starts `Daemon`'s idle-grace timer.
  private static func spawnLoops(
    daemon: Daemon, backend: FakeDuplexChannel, accepting: FakeSocketAccepting, listening: ListeningHandle
  ) -> (backendTask: Task<Void, Never>, acceptTask: Task<Void, Never>) {
    withDependencies {
      $0.socketAccepting = accepting
      $0.continuousClock = TestClock()
    } operation: {
      let backendTask = Task { await BackendSessionLoop.run(daemon: daemon, backend: backend) }
      let acceptTask = Task { await AcceptLoop.run(daemon: daemon, listening: listening) }
      return (backendTask, acceptTask)
    }
  }

  @Test func acceptedConnectionBecomesAClientSessionAndRoutesMessagesThenTheLoopEndsCleanly() async throws {
    try await Self.withConnectedSocketPair { clientConnection, serverConnection in
      let backend = FakeDuplexChannel(remainsOpenWhenExhausted: true)
      let daemon = Daemon(backend: backend)
      let accepting = FakeSocketAccepting(results: [.success(serverConnection)])
      let loops = Self.spawnLoops(
        daemon: daemon, backend: backend, accepting: accepting, listening: ListeningHandle(fileDescriptor: 999)
      )

      let client = Self.clientChannel(over: clientConnection)
      try await client.send(Self.requestBody(id: "1", method: "buildTarget/sources"))

      let forwardedBytes = await backend.waitForNextSentMessage()
      let forwarded = try JSONRPCEnvelope(rawBytes: forwardedBytes)
      #expect(forwarded.method == "buildTarget/sources")

      let backendResponse = Data(#"{"jsonrpc":"2.0","id":\#(forwarded.id!.rawText),"result":{}}"#.utf8)
      await backend.enqueueIncoming(backendResponse)

      let replyBytes = try await client.receive()
      let reply = try JSONRPCEnvelope(rawBytes: try #require(replyBytes))
      #expect(reply.id == JSONRPCRawID(rawText: #""1""#))

      // Closing the client end ends the server-side session (EOF), which - via AcceptLoop's own
      // `defer { close(...) }` - closes serverConnection's fd too; the loop then finds
      // `accepting`'s single scripted result already consumed and returns. Awaiting the task
      // proves that termination actually happens rather than just inferring it.
      close(clientConnection.fileDescriptor)
      await loops.acceptTask.value
      await backend.finishIncoming()
    }
  }

  @Test func acceptFailureEndsTheLoopWithoutEverHandlingAConnection() async throws {
    let daemon = Daemon(backend: FakeDuplexChannel(remainsOpenWhenExhausted: true))
    let accepting = FakeSocketAccepting(results: [])

    await withDependencies {
      $0.socketAccepting = accepting
    } operation: {
      await AcceptLoop.run(daemon: daemon, listening: ListeningHandle(fileDescriptor: 999))
    }

    #expect(accepting.acceptCalls.count == 1)
  }

  /// Empirical verification for the fd-close/fd-reuse question `AcceptLoop`'s own doc comment
  /// discusses: many connections in a row, each fully closed (both ends) before the next opens,
  /// so their underlying fd *numbers* are very likely reused by the OS - if a stale, not-quite-
  /// cancelled `DispatchSourceRead`/`DispatchSourceWrite` from a previous connection ever
  /// misdelivered onto a reused fd, this would show up here as a wrong id or a parse failure on
  /// some later iteration, not just on the first. Run via `swift test --filter AcceptLoopTests`
  /// repeated 15-40x locally before trusting this, per this codebase's established convention for
  /// anything touching real fds/concurrency - a single green run isn't the bar.
  @Test func manySequentialConnectionsEachReachTheirOwnSessionWithoutCrossTalk() async throws {
    let backend = FakeDuplexChannel(remainsOpenWhenExhausted: true)
    let daemon = Daemon(backend: backend)
    // Spawned once, outside the loop - one Daemon's backend connection lives for its whole life,
    // not once per accepted connection (unlike AcceptLoop itself, which genuinely does need a
    // fresh call per connection below, since each only has one connection scripted).
    withDependencies {
      $0.continuousClock = TestClock()
    } operation: {
      Task { await BackendSessionLoop.run(daemon: daemon, backend: backend) }
    }

    for index in 0..<20 {
      try await Self.withConnectedSocketPair { clientConnection, serverConnection in
        let accepting = FakeSocketAccepting(results: [.success(serverConnection)])
        let acceptTask = withDependencies {
          $0.socketAccepting = accepting
          $0.continuousClock = TestClock()
        } operation: {
          Task { await AcceptLoop.run(daemon: daemon, listening: ListeningHandle(fileDescriptor: 999)) }
        }

        let client = Self.clientChannel(over: clientConnection)
        try await client.send(Self.requestBody(id: "\(index)", method: "ping"))

        let forwardedBytes = await backend.waitForNextSentMessage()
        let forwarded = try JSONRPCEnvelope(rawBytes: forwardedBytes)
        #expect(forwarded.method == "ping")

        let backendResponse = Data(#"{"jsonrpc":"2.0","id":\#(forwarded.id!.rawText),"result":{}}"#.utf8)
        await backend.enqueueIncoming(backendResponse)

        let replyBytes = try await client.receive()
        let reply = try JSONRPCEnvelope(rawBytes: try #require(replyBytes))
        #expect(reply.id == JSONRPCRawID(rawText: "\"\(index)\""))

        close(clientConnection.fileDescriptor)
        await acceptTask.value
      }
    }

    await backend.finishIncoming()
  }
}
