import BSPMuxCore
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct TimeoutError: Error {}

/// One spawned real `bsp-mux run` process, standing in for an editor/BSP client. Reuses
/// `BSPMuxCore`'s own `RealByteSource`/`RealByteSink`/`FramedDuplexChannel` for framing over the
/// real pipes rather than hand-rolling a third framing implementation alongside `bsp-mux`'s own
/// and `fake-bsp-backend`'s - this is exactly the abstraction a real client-side driver needs.
/// `@unchecked Sendable`: `channel` is itself an actor (thread-safe internally), and everything
/// else here is only ever touched sequentially by the test driving this client - matches this
/// codebase's own established convention for test-support types in exactly this position (e.g.
/// `FakeBSPBackendTests`' own `Recorder`).
final class SimulatedClient: @unchecked Sendable {
  let process: Process
  private let channel: FramedDuplexChannel
  private let stdinHandle: FileHandle

  static func launch(workspaceRoot: String, backendArgv: [String]) throws -> SimulatedClient {
    let process = Process()
    process.executableURL = BinaryLocator.bspMux
    process.arguments = ["run", "--workspace-root", workspaceRoot, "--"] + backendArgv

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()  // discarded - keeps stderr from leaking into the test's own

    try process.run()

    let source = RealByteSource(fileDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor)
    let sink = RealByteSink(fileDescriptor: stdinPipe.fileHandleForWriting.fileDescriptor)
    let channel = FramedDuplexChannel(source: source, sink: sink)
    return SimulatedClient(process: process, channel: channel, stdinHandle: stdinPipe.fileHandleForWriting)
  }

  private init(process: Process, channel: FramedDuplexChannel, stdinHandle: FileHandle) {
    self.process = process
    self.channel = channel
    self.stdinHandle = stdinHandle
  }

  func send(_ body: Data) async throws {
    try await channel.send(body)
  }

  /// Suspends for at most `timeoutSeconds` waiting for the next complete message body, or
  /// `nil` on a clean EOF. Throws `TimeoutError` if nothing arrives in time - the tool this
  /// suite's whole point is to distinguish "failed promptly" from "hung forever".
  func receive(timeoutSeconds: Double = 5) async throws -> Data? {
    try await withThrowingTaskGroup(of: Data?.self) { group in
      group.addTask { try await self.channel.receive() }
      group.addTask {
        try await Task.sleep(for: .seconds(timeoutSeconds))
        throw TimeoutError()
      }
      let result = try await group.next()!
      group.cancelAll()
      return result
    }
  }

  /// Closing the write end of the client's own stdin is what a real editor closing/exiting
  /// looks like from `bsp-mux`'s side - drives the same EOF-based session-end path as a real
  /// disconnect.
  func closeStdin() {
    try? stdinHandle.close()
  }

  var isRunning: Bool { process.isRunning }

  @discardableResult
  func waitForExit(timeoutSeconds: Double = 10) -> Int32? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    return process.isRunning ? nil : process.terminationStatus
  }

  /// Ends this process immediately rather than waiting on whatever natural shutdown path it
  /// would otherwise take - a winner client's own natural exit is gated behind the real 5s
  /// idle-grace period, which is worth paying exactly once (the scenario that specifically tests
  /// that path), not in every other scenario's own teardown once its assertions are done.
  func forceKillIfRunning() {
    guard process.isRunning else { return }
    process.terminate()
    _ = waitForExit(timeoutSeconds: 2)
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }
  }
}
