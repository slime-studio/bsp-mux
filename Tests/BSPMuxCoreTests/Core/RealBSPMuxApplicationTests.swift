import Clocks
import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct RealBSPMuxApplicationTests {
  /// Real OS pipes standing in for a process's own stdin/stdout, mirroring
  /// `RelaySessionTests.PipeStandardIO` - each retained via its owning `Pipe` (a `FileHandle`
  /// closes its fd on dealloc, so the `Pipe` itself must outlive the fds derived from it).
  private struct PipeStandardIO {
    let inPipe = Pipe()
    let outPipe = Pipe()

    var standardIn: RealByteSource { RealByteSource(fileDescriptor: inPipe.fileHandleForReading.fileDescriptor) }
    var writeToStandardIn: RealByteSink { RealByteSink(fileDescriptor: inPipe.fileHandleForWriting.fileDescriptor) }
    var standardOut: RealByteSink { RealByteSink(fileDescriptor: outPipe.fileHandleForWriting.fileDescriptor) }
    var readFromStandardOut: RealByteSource { RealByteSource(fileDescriptor: outPipe.fileHandleForReading.fileDescriptor) }

    func closeTestEnds() {
      try? inPipe.fileHandleForWriting.close()
      try? outPipe.fileHandleForReading.close()
    }
  }

  // MARK: - install

  @Test func installDelegatesToInstaller() throws {
    let fs = InMemoryFileSystem()
    let buildServerJSONPath = "/workspace/buildServer.json"
    let originalJSON: [String: Any] = [
      "name": "sourcekit-xcode-bsp", "version": "0.1.0", "bspVersion": "2.1.0",
      "languages": ["swift"], "argv": ["/usr/local/bin/sourcekit-xcode-bsp", "serve"],
    ]
    try fs.write(try JSONSerialization.data(withJSONObject: originalJSON), toPath: buildServerJSONPath)

    try withDependencies {
      $0.fileSystem = fs
    } operation: {
      let result = try RealBSPMuxApplication().install(
        workspaceRoot: "/workspace", multiplexerExecutable: "/bin/bsp-mux", force: false
      )
      #expect(result.changed)
      #expect(
        result.wrappedArgv == [
          "/bin/bsp-mux", "--workspace-root", "/workspace", "--",
          "/usr/local/bin/sourcekit-xcode-bsp", "serve",
        ])
    }
  }

  // MARK: - run: .relay

  /// Mirrors `RealDuplexByteStreamTests`/`RelaySessionTests`' own helper: a real, connected
  /// `AF_UNIX` socket pair standing in for `Election.run()`'s `.relay(ConnectionHandle)` case
  /// (`clientConnection`) and the live daemon on the other end (`serverConnection`).
  private static func withConnectedSocketPair(
    _ body: (ConnectionHandle, ConnectionHandle) async throws -> Void
  ) async throws {
    let path = "/tmp/bsp-mux-application-test-\(UUID().uuidString).sock"
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

  @Test func relayOutcomePumpsBytesBetweenInjectedStdioAndTheLiveDaemonSocket() async throws {
    try await Self.withConnectedSocketPair { clientConnection, serverConnection in
      let io = PipeStandardIO()
      let application = RealBSPMuxApplication()
      let environment = FakeElectionEnvironment(connectResults: [.success(clientConnection)])

      async let run: Void = withDependencies {
        $0.electionEnvironment = environment
        $0.fileSystem = InMemoryFileSystem()
      } operation: {
        try await application.run(
          workspaceRoot: "/workspace", backendArgv: ["/usr/bin/backend"],
          standardIn: io.standardIn, standardOut: io.standardOut
        )
      }

      let serverSource = RealByteSource(fileDescriptor: serverConnection.fileDescriptor)
      let serverSink = RealByteSink(fileDescriptor: serverConnection.fileDescriptor)

      try await io.writeToStandardIn.write(Data("ping".utf8))
      var receivedByServer = Data()
      while receivedByServer.count < 4, let chunk = try await serverSource.read() {
        receivedByServer.append(chunk)
      }
      #expect(receivedByServer == Data("ping".utf8))

      try await serverSink.write(Data("pong".utf8))
      var receivedByStandardOut = Data()
      while receivedByStandardOut.count < 4, let chunk = try await io.readFromStandardOut.read() {
        receivedByStandardOut.append(chunk)
      }
      #expect(receivedByStandardOut == Data("pong".utf8))

      // The server closing first is what ends the relay - a clean socket EOF.
      close(serverConnection.fileDescriptor)
      try await run

      io.closeTestEnds()
    }
  }

  // MARK: - run: .daemon

  @Test func daemonOutcomeRoundTripsInitializeThroughRealFramingAndShutsDownOnBackendDisconnect() async throws {
    let backend = FakeDuplexChannel(remainsOpenWhenExhausted: true)
    let spawning = FakeBackendSpawning(results: [.success(backend)])
    let io = PipeStandardIO()
    let application = RealBSPMuxApplication()
    let environment = FakeElectionEnvironment(
      connectResults: [.absent],
      lockResults: [.acquired(LockHandle(fileDescriptor: 999))]
    )
    let fileSystem = InMemoryFileSystem()
    let processExiting = FakeProcessExiting()

    // A `Task { }` created inside `operation` (DaemonBootstrap's detached background loops)
    // captures these overridden dependencies at creation time and keeps them for its own full
    // lifetime, independent of `withDependencies`' own dynamic scope ending - matching
    // `DaemonBootstrapTests.withTestDependencies`'s own reasoning for the same setup.
    async let run: Void = withDependencies {
      $0.electionEnvironment = environment
      $0.fileSystem = fileSystem
      $0.backendSpawning = spawning
      $0.socketAccepting = FakeSocketAccepting()
      $0.continuousClock = TestClock()
      $0.signalHandling = FakeSignalHandling()
      $0.processExiting = processExiting
    } operation: {
      try await application.run(
        workspaceRoot: "/workspace", backendArgv: ["/usr/bin/backend", "serve"],
        standardIn: io.standardIn, standardOut: io.standardOut
      )
    }

    let initializeRequestJSON =
      #"{"jsonrpc":"2.0","id":"1","method":"build/initialize","params":{"displayName":"editor","version":"1.0","#
      + #""bspVersion":"2.1.0","rootUri":"file:///workspace","capabilities":{}}}"#
    try await io.writeToStandardIn.write(MessageFraming.frame(Data(initializeRequestJSON.utf8)))

    let forwardedBytes = await backend.waitForNextSentMessage()
    let forwarded = try JSONRPCEnvelope(rawBytes: forwardedBytes)
    #expect(forwarded.method == "build/initialize")

    let backendResponse = Data(
      #"{"jsonrpc":"2.0","id":\#(forwarded.id!.rawText),"result":{"displayName":"backend","version":"1.0","bspVersion":"2.1.0","capabilities":{}}}"#
        .utf8)
    await backend.enqueueIncoming(backendResponse)

    var reader = MessageFrameReader()
    var replyBody: Data?
    while replyBody == nil {
      guard let chunk = try await io.readFromStandardOut.read() else { break }
      replyBody = try reader.feed(chunk).first
    }
    let reply = try JSONRPCEnvelope(rawBytes: try #require(replyBody))
    #expect(reply.id == JSONRPCRawID(rawText: #""1""#))  // the original request's id was the JSON string "1"

    // The backend process dying is exactly this: its channel has nothing more to give -
    // per DESIGN.md, that alone ends the whole daemon regardless of client sessions.
    await backend.finishIncoming()
    try await run

    // Proves `.daemon`'s normal-shutdown path really reaches `DaemonTeardown`, not just that
    // `DaemonTeardown` works in isolation (`DaemonTeardownTests` already covers that) - mirrors
    // this suite's own "prove real wiring" philosophy. Two removals, not one: `Election` itself
    // already removes any stale socket at the same path before binding (see `Election.swift`),
    // and `DaemonTeardown` removes it again on the way out.
    #expect(fileSystem.removedPaths.count == 2)
    #expect(processExiting.exitCodes == [0])
    #expect(!environment.calls.contains("signalOwnProcessGroup"))

    io.closeTestEnds()
  }

  @Test func aSignalArrivingWhileDaemonEndsTeardownThroughTheGroupSignalPath() async throws {
    let backend = FakeDuplexChannel(remainsOpenWhenExhausted: true)
    let spawning = FakeBackendSpawning(results: [.success(backend)])
    let io = PipeStandardIO()
    let application = RealBSPMuxApplication()
    let environment = FakeElectionEnvironment(
      connectResults: [.absent],
      lockResults: [.acquired(LockHandle(fileDescriptor: 999))]
    )
    let fileSystem = InMemoryFileSystem()
    let processExiting = FakeProcessExiting()
    let signalHandling = FakeSignalHandling()

    async let run: Void = withDependencies {
      $0.electionEnvironment = environment
      $0.fileSystem = fileSystem
      $0.backendSpawning = spawning
      $0.socketAccepting = FakeSocketAccepting()
      $0.continuousClock = TestClock()
      $0.signalHandling = signalHandling
      $0.processExiting = processExiting
    } operation: {
      try await application.run(
        workspaceRoot: "/workspace", backendArgv: ["/usr/bin/backend", "serve"],
        standardIn: io.standardIn, standardOut: io.standardOut
      )
    }

    // Wait for the daemon's own signal registration to actually happen before firing - otherwise
    // `fire` below could race `.daemon`'s own setup and find nothing registered yet.
    await signalHandling.waitForRegistrations(count: 2)
    #expect(signalHandling.registeredSignals.contains(SIGTERM))

    // `fire` runs the registered handler synchronously, which spawns an unstructured `Task` to
    // perform the actual (async) teardown - that `Task` captures whatever dependencies are
    // ambient at the moment it's *created*, not at the moment the handler closure was originally
    // written. Since `fire` is called from this test's own top-level scope (outside `run`'s own
    // `withDependencies`), it needs its own matching scope here, or the spawned `Task` falls back
    // to live (non-test) dependencies and traps - same "captured at creation time" reasoning
    // `DaemonBootstrapTests`/`AcceptLoopTests` already rely on for their own detached loops.
    withDependencies {
      $0.electionEnvironment = environment
      $0.fileSystem = fileSystem
      $0.signalHandling = signalHandling
      $0.processExiting = processExiting
    } operation: {
      signalHandling.fire(SIGTERM)
    }

    // `FakeProcessExiting` doesn't actually terminate the process, so the signal-triggered
    // teardown `Task` and this test's own `run` both keep going - wait for the exit call to land
    // rather than racing it.
    await processExiting.waitForExit()

    // Two removals, not one: `Election` itself already removed the (nonexistent) stale socket
    // before binding (see `Election.swift`), and `DaemonTeardown`'s signal path removes it again.
    #expect(fileSystem.removedPaths.count == 2)
    #expect(environment.calls.contains("signalOwnProcessGroup"))
    #expect(processExiting.exitCodes == [0])

    await backend.finishIncoming()
    try await run
    io.closeTestEnds()
  }
}
