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

    await #expect(throws: BuildServerJSON.Error.self) {
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

    await #expect(throws: BuildServerJSON.Error.self) {
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

  @Test func findRunningProjectKeyPrefersAMatchingMetaSidecarOverRecomputingFromThisProcessesOwnEnvironment() throws {
    // The fresh (env-based) hash this process would compute on its own differs from the
    // sidecar's real one - simulating `stop` running with a different DEVELOPER_DIR/TOOLCHAINS
    // than whatever elected the real daemon. The sidecar, matched on workspaceRoot/backendArgv
    // alone, must win.
    let realFullHash = String(repeating: "a", count: 64)
    let baseDirectory = ProjectPaths.defaultBaseDirectory()
    let meta = ProjectKeyMeta(key: ProjectKey(fullHash: realFullHash), workspaceRoot: "/workspace", backendArgv: ["/usr/bin/backend"])
    let fileSystem = InMemoryFileSystem([
      "\(baseDirectory)/deadbeefdeadbeef.meta.json": try JSONEncoder().encode(meta)
    ])

    let key = withDependencies {
      $0.fileSystem = fileSystem
    } operation: {
      DaemonStopSignal().findRunningProjectKey(workspaceRoot: "/workspace", backendArgv: ["/usr/bin/backend"])
    }

    #expect(key.fullHash == realFullHash)
  }

  @Test func findRunningProjectKeyFallsBackToRecomputingWhenNoSidecarMatches() throws {
    let fileSystem = InMemoryFileSystem()

    let key = withDependencies {
      $0.fileSystem = fileSystem
    } operation: {
      DaemonStopSignal().findRunningProjectKey(workspaceRoot: "/workspace", backendArgv: ["/usr/bin/backend"])
    }

    let expected = withDependencies {
      $0.fileSystem = fileSystem
    } operation: {
      ProjectKey(workspaceRoot: "/workspace", backendArgv: ["/usr/bin/backend"])
    }
    #expect(key.fullHash == expected.fullHash)
  }

  @Test func findRunningProjectKeyIgnoresASidecarForADifferentWorkspace() throws {
    let unrelatedFullHash = String(repeating: "b", count: 64)
    let baseDirectory = ProjectPaths.defaultBaseDirectory()
    let meta = ProjectKeyMeta(
      key: ProjectKey(fullHash: unrelatedFullHash), workspaceRoot: "/some/other/workspace", backendArgv: ["/usr/bin/backend"])
    let fileSystem = InMemoryFileSystem([
      "\(baseDirectory)/cafecafecafecafe.meta.json": try JSONEncoder().encode(meta)
    ])

    let key = withDependencies {
      $0.fileSystem = fileSystem
    } operation: {
      DaemonStopSignal().findRunningProjectKey(workspaceRoot: "/workspace", backendArgv: ["/usr/bin/backend"])
    }

    #expect(key.fullHash != unrelatedFullHash)
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
      let environment = FakeElectionEnvironment(
        connectResults: [.success(ConnectionHandle(fileDescriptor: daemonEnd))],  // the actual send
        // The flock being acquirable (nobody holds it) is what actually confirms the daemon
        // exited - not the socket's disappearance, which happens earlier in its teardown.
        lockResults: [.acquired(LockHandle(fileDescriptor: 999))]
      )

      let result = try await withDependencies {
        $0.fileSystem = fileSystem
        $0.electionEnvironment = environment
        $0.continuousClock = ImmediateClock()
      } operation: {
        try await DaemonStopSignal().stop(workspaceRoot: "/workspace", multiplexerExecutable: Self.multiplexerPath, force: false)
      }

      #expect(result.outcome == .stopped)
      #expect(environment.calls == ["connect", "acquireLock"])
    }
  }

  @Test func wrappedWithADaemonThatNeverConfirmsTeardownThrowsRatherThanHangingForever() async throws {
    try await Self.withRealConnectedFDPair { daemonEnd, _ in
      let fileSystem = InMemoryFileSystem(["/workspace/buildServer.json": try Self.wrappedBuildServerJSON()])
      let environment = FakeElectionEnvironment(
        connectResults: [.success(ConnectionHandle(fileDescriptor: daemonEnd))],  // the actual send
        // The daemon's flock is still held on every poll attempt - never reports .stopped.
        lockResults: Array(repeating: .contended, count: 60)
      )

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
