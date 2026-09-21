import Clocks
import Dependencies
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import BSPMuxCore

@Suite struct DaemonStopSignalTests {
  private static let multiplexerPath = "/bin/bsp-mux"

  private static func wrappedBuildServerJSON(backendArgv: [String] = ["/usr/bin/backend"]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "argv": [multiplexerPath, "--workspace-root", "/workspace", "--"] + backendArgv
    ])
  }

  @Test func noBuildServerJSONThrowsAClearError() async throws {
    let fileSystem = InMemoryFileSystem()

    await #expect(throws: DaemonStopSignal.Error.self) {
      try await withDependencies {
        $0.fileSystem = fileSystem
      } operation: {
        try await DaemonStopSignal().stop(workspaceRoot: "/workspace", multiplexerExecutable: Self.multiplexerPath, force: false)
      }
    }
  }

  @Test func buildServerJSONWithNoArgvThrows() async throws {
    let fileSystem = InMemoryFileSystem([
      "/workspace/buildServer.json": try JSONSerialization.data(withJSONObject: ["name": "backend"])
    ])

    await #expect(throws: DaemonStopSignal.Error.self) {
      try await withDependencies {
        $0.fileSystem = fileSystem
      } operation: {
        try await DaemonStopSignal().stop(workspaceRoot: "/workspace", multiplexerExecutable: Self.multiplexerPath, force: false)
      }
    }
  }

  @Test func buildServerJSONNotWrappedByUsThrows() async throws {
    let fileSystem = InMemoryFileSystem([
      "/workspace/buildServer.json": try JSONSerialization.data(withJSONObject: ["argv": ["/usr/bin/backend"]])
    ])

    await #expect(throws: DaemonStopSignal.Error.self) {
      try await withDependencies {
        $0.fileSystem = fileSystem
      } operation: {
        try await DaemonStopSignal().stop(workspaceRoot: "/workspace", multiplexerExecutable: Self.multiplexerPath, force: false)
      }
    }
  }

  @Test func wrappedWithNoLiveDaemonReportsNotRunning() async throws {
    let fileSystem = InMemoryFileSystem(["/workspace/buildServer.json": try Self.wrappedBuildServerJSON()])
    let environment = FakeElectionEnvironment(connectResults: [.absent])

    let result = try await withDependencies {
      $0.fileSystem = fileSystem
      $0.electionEnvironment = environment
    } operation: {
      try await DaemonStopSignal().stop(workspaceRoot: "/workspace", multiplexerExecutable: Self.multiplexerPath, force: false)
    }

    #expect(result.outcome == .notRunning)
    #expect(environment.calls == ["connect"])
  }

  /// A real, local `socketpair` fd stands in for the daemon's own accepted connection - not so
  /// this test can read/assert on the bytes sent (`FakeElectionEnvironment` doesn't need that to
  /// prove dispatch), but because `DaemonStopSignal` does a real `FramedDuplexChannel.send()` on
  /// whatever fd `connect()` hands it, and a bogus fd number would fail that write outright.
  private static func withRealConnectedFDPair(_ body: (Int32, Int32) async throws -> Void) async throws {
    var fds: [Int32] = [0, 0]
    let result = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress) }
    #expect(result == 0)
    defer { close(fds[1]) }
    try await body(fds[0], fds[1])
  }

  @Test func wrappedWithALiveDaemonSendsTheStopMessageAndConfirmsTeardown() async throws {
    try await Self.withRealConnectedFDPair { daemonEnd, _ in
      let fileSystem = InMemoryFileSystem(["/workspace/buildServer.json": try Self.wrappedBuildServerJSON()])
      let environment = FakeElectionEnvironment(connectResults: [
        .success(ConnectionHandle(fileDescriptor: daemonEnd)),  // the actual send
        .absent,  // first poll check already finds the socket gone
      ])

      let result = try await withDependencies {
        $0.fileSystem = fileSystem
        $0.electionEnvironment = environment
        $0.continuousClock = ImmediateClock()
      } operation: {
        try await DaemonStopSignal().stop(workspaceRoot: "/workspace", multiplexerExecutable: Self.multiplexerPath, force: false)
      }

      #expect(result.outcome == .stopped)
      #expect(environment.calls == ["connect", "connect"])
    }
  }

  @Test func wrappedWithADaemonThatNeverConfirmsTeardownThrowsRatherThanHangingForever() async throws {
    try await Self.withRealConnectedFDPair { daemonEnd, _ in
      let fileSystem = InMemoryFileSystem(["/workspace/buildServer.json": try Self.wrappedBuildServerJSON()])
      // The send succeeds, but every subsequent poll still finds the socket alive - never
      // reports .stopped. 61 results: 1 for the send + 60 for every poll attempt.
      var connectResults: [FakeElectionEnvironment.ConnectResult] = [.success(ConnectionHandle(fileDescriptor: daemonEnd))]
      connectResults.append(contentsOf: Array(repeating: .success(ConnectionHandle(fileDescriptor: daemonEnd)), count: 60))
      let environment = FakeElectionEnvironment(connectResults: connectResults)

      await #expect(throws: DaemonStopSignal.Error.self) {
        try await withDependencies {
          $0.fileSystem = fileSystem
          $0.electionEnvironment = environment
          $0.continuousClock = ImmediateClock()
        } operation: {
          try await DaemonStopSignal().stop(workspaceRoot: "/workspace", multiplexerExecutable: Self.multiplexerPath, force: false)
        }
      }
    }
  }
}
