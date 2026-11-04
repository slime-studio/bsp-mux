import Clocks
import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

/// `RealBSPMuxApplication`'s `.daemon` outcome handling a real `bspMux/stop` over the wire -
/// split out from `RealBSPMuxApplicationTests` (which covers install/relay/daemon-lifecycle/
/// signal-driven teardown) once this grew into its own cohesive chunk, to keep both files under
/// SwiftLint's length limits.
@Suite struct RealBSPMuxApplicationStopTests {
  /// Mirrors `RealBSPMuxApplicationTests.PipeStandardIO` (itself mirroring
  /// `RelaySessionTests.PipeStandardIO`) - small enough that duplicating it per test file beats
  /// a shared test-support type only three files would ever use.
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

  @Test func nonForceStopOverTheWireAttemptsAGracefulBackendShutdownWithoutForceSignaling() async throws {
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

    let stopMessage = #"{"jsonrpc":"2.0","method":"bspMux/stop","params":{"force":false}}"#
    try await io.writeToStandardIn.write(MessageFraming.frame(Data(stopMessage.utf8)))

    let toBackend1 = await backend.waitForNextSentMessage()
    let toBackend2 = await backend.waitForNextSentMessage()
    #expect(try JSONRPCEnvelope(rawBytes: toBackend1).method == .buildShutdown)
    #expect(try JSONRPCEnvelope(rawBytes: toBackend2).method == .buildExit)

    try await run

    // A plain (non-force) stop already got the backend a real BSP shutdown/exit round trip
    // above - DaemonTeardown must not *also* force-signal the process group, which would race
    // that attempt instead of giving it a chance to work (see DaemonTeardown's own doc comment).
    #expect(!environment.calls.contains("signalOwnProcessGroup"))
    #expect(processExiting.exitCodes == [0])

    io.closeTestEnds()
  }

  @Test func forceStopOverTheWireSkipsTheGracefulRoundTripAndSignalsSIGKILL() async throws {
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

    let stopMessage = #"{"jsonrpc":"2.0","method":"bspMux/stop","params":{"force":true}}"#
    try await io.writeToStandardIn.write(MessageFraming.frame(Data(stopMessage.utf8)))

    try await run

    #expect(await backend.sentMessages.isEmpty)
    #expect(environment.signaledProcessGroupSignals == [SIGKILL])
    #expect(processExiting.exitCodes == [0])

    io.closeTestEnds()
  }

  /// Sends a `build/initialize` request over `io`'s stdin, answers it from `backend`, and
  /// waits for the reply on stdout - a real round trip used purely as a synchronization point
  /// (proof the daemon branch has actually run) rather than for its own content.
  private func roundTripInitialize(io: PipeStandardIO, backend: FakeDuplexChannel) async throws {
    let initializeRequestJSON =
      #"{"jsonrpc":"2.0","id":"1","method":"build/initialize","params":{"displayName":"editor","version":"1.0","#
      + #""bspVersion":"2.1.0","rootUri":"file:///workspace","capabilities":{}}}"#
    try await io.writeToStandardIn.write(MessageFraming.frame(Data(initializeRequestJSON.utf8)))
    let forwarded = try JSONRPCEnvelope(rawBytes: await backend.waitForNextSentMessage())

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
    _ = try #require(replyBody)
  }

  @Test func daemonOutcomePersistsAProjectKeyMetaSidecarForStopToFindLater() async throws {
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
    let backendArgv = ["/usr/bin/backend", "serve"]

    let (expectedKey, expectedPaths) = withDependencies {
      $0.fileSystem = fileSystem
    } operation: { () -> (ProjectKey, ProjectPaths) in
      let key = ProjectKey(workspaceRoot: "/workspace", backendArgv: backendArgv)
      return (key, ProjectPaths(key: key))
    }

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
        workspaceRoot: "/workspace", backendArgv: backendArgv, standardIn: io.standardIn, standardOut: io.standardOut
      )
    }

    // Proof the daemon branch has run far enough to have written the sidecar (which happens
    // earlier in that same branch, before `DaemonBootstrap.start` even spawns the backend) -
    // checked *before* stopping, since `DaemonTeardown` removes the sidecar as part of
    // tearing down. Also leaves nothing suspended: the winner session's receive loop processes
    // messages sequentially, so an unanswered `build/initialize` would block it from ever
    // dispatching the `bspMux/stop` sent below.
    try await roundTripInitialize(io: io, backend: backend)

    let metaData = try #require(fileSystem[expectedPaths.metaPath])
    let meta = try JSONDecoder().decode(ProjectKeyMeta.self, from: metaData)
    #expect(meta.fullHash == expectedKey.fullHash)
    #expect(meta.workspaceRoot == "/workspace")
    #expect(meta.backendArgv == backendArgv)

    let stopMessage = #"{"jsonrpc":"2.0","method":"bspMux/stop","params":{"force":true}}"#
    try await io.writeToStandardIn.write(MessageFraming.frame(Data(stopMessage.utf8)))
    try await run

    // DaemonTeardown must have cleaned the sidecar up on the way out too, or it'd shadow a
    // future daemon's own meta lookup after this one's gone.
    #expect(fileSystem[expectedPaths.metaPath] == nil)

    io.closeTestEnds()
  }
}
