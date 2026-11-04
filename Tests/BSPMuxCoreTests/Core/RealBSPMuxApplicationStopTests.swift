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

    // Ends the daemon so `run` returns - the sidecar is written as soon as this process wins
    // the election though, well before this.
    let stopMessage = #"{"jsonrpc":"2.0","method":"bspMux/stop","params":{"force":true}}"#
    try await io.writeToStandardIn.write(MessageFraming.frame(Data(stopMessage.utf8)))
    try await run

    let metaData = try #require(fileSystem[expectedPaths.metaPath])
    let meta = try JSONDecoder().decode(ProjectKeyMeta.self, from: metaData)
    #expect(meta.fullHash == expectedKey.fullHash)
    #expect(meta.workspaceRoot == "/workspace")
    #expect(meta.backendArgv == backendArgv)

    io.closeTestEnds()
  }
}
