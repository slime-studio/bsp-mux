import Clocks
import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct ElectionTests {
  static let paths = ProjectPaths(
    key: ProjectKey(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: [:]),
    baseDirectory: "/tmp/bsp-mux-test-election"
  )

  /// Runs `election.run()` with an `ImmediateClock` standing in for the real one, so a test
  /// that reaches the poll loop resolves every `sleep` instantly instead of actually waiting.
  static func run(_ election: Election) async throws -> ElectionOutcome {
    try await withDependencies {
      $0.continuousClock = ImmediateClock()
    } operation: {
      try await election.run()
    }
  }

  @Test func immediateConnectSuccessBecomesRelayWithoutTouchingTheLock() async throws {
    let handle = ConnectionHandle(fileDescriptor: 7)
    let env = FakeElectionEnvironment(connectResults: [.success(handle)])
    let election = Election(paths: Self.paths, environment: env)

    let outcome = try await Self.run(election)

    #expect(outcome == .relay(handle))
    #expect(env.calls == ["connect"])
  }

  @Test func connectFailsThenLockAcquiredBecomesDaemonInCorrectOrder() async throws {
    let lock = LockHandle(fileDescriptor: 3)
    let listening = ListeningHandle(fileDescriptor: 4)
    let env = FakeElectionEnvironment(
      connectResults: [.absent],
      lockResults: [.acquired(lock)]
    )
    env.listenResult = .success(listening)
    let fs = InMemoryFileSystem()
    let election = Election(paths: Self.paths, environment: env, fileSystem: fs)

    let outcome = try await Self.run(election)

    #expect(outcome == .daemon(listening, lock))
    #expect(env.calls == ["connect", "acquireLock", "listen", "ignoreSIGPIPE", "detachSession"])
    #expect(fs.removedPaths == [Self.paths.socketPath])
  }

  @Test func connectFailsAndLockContendedThenConnectSucceedsBecomesRelay() async throws {
    let handle = ConnectionHandle(fileDescriptor: 9)
    let env = FakeElectionEnvironment(
      connectResults: [.absent, .success(handle)],
      lockResults: [.contended]
    )
    let election = Election(paths: Self.paths, environment: env)

    let outcome = try await Self.run(election)

    #expect(outcome == .relay(handle))
    #expect(env.calls == ["connect", "acquireLock", "connect"])
  }

  @Test func connectFailsAndLockContendedThenLockFreesUpBecomesDaemon() async throws {
    // Models the previous lock holder dying mid-startup: still no live daemon to connect to
    // on the second attempt, but the lock is free now.
    let lock = LockHandle(fileDescriptor: 5)
    let listening = ListeningHandle(fileDescriptor: 6)
    let env = FakeElectionEnvironment(
      connectResults: [.absent, .absent],
      lockResults: [.contended, .acquired(lock)]
    )
    env.listenResult = .success(listening)
    let fs = InMemoryFileSystem()
    let election = Election(paths: Self.paths, environment: env, fileSystem: fs)

    let outcome = try await Self.run(election)

    #expect(outcome == .daemon(listening, lock))
    #expect(env.calls == ["connect", "acquireLock", "connect", "acquireLock", "listen", "ignoreSIGPIPE", "detachSession"])
    #expect(fs.removedPaths == [Self.paths.socketPath])
  }

  @Test func nonAbsenceConnectErrorPropagatesRatherThanBeingTreatedAsNoDaemon() async {
    let env = FakeElectionEnvironment(connectResults: [.failure(ElectionError(description: "connect failed: permission denied"))])
    let election = Election(paths: Self.paths, environment: env)

    await #expect(throws: ElectionError.self) {
      try await Self.run(election)
    }
  }

  @Test func lockAcquireErrorPropagates() async {
    let env = FakeElectionEnvironment(
      connectResults: [.absent],
      lockResults: [.failure(ElectionError(description: "flock failed: no locks available"))]
    )
    let election = Election(paths: Self.paths, environment: env)

    await #expect(throws: ElectionError.self) {
      try await Self.run(election)
    }
  }

  @Test func listenErrorPropagatesAfterAcquiringLock() async throws {
    let env = FakeElectionEnvironment(
      connectResults: [.absent],
      lockResults: [.acquired(LockHandle(fileDescriptor: 3))]
    )
    env.listenResult = .failure(ElectionError(description: "bind failed: address in use"))
    let fs = InMemoryFileSystem()
    let election = Election(paths: Self.paths, environment: env, fileSystem: fs)

    await #expect(throws: ElectionError.self) {
      try await Self.run(election)
    }
    // Still unlinked the stale socket before the failing listen() attempt.
    #expect(env.calls == ["connect", "acquireLock", "listen"])
    #expect(fs.removedPaths == [Self.paths.socketPath])
  }

  @Test func detachSessionErrorPropagatesAfterListenAndIgnoreSIGPIPE() async throws {
    let env = FakeElectionEnvironment(
      connectResults: [.absent],
      lockResults: [.acquired(LockHandle(fileDescriptor: 3))]
    )
    env.detachSessionError = ElectionError(description: "setsid failed: unexpected errno")
    let election = Election(paths: Self.paths, environment: env)

    await #expect(throws: ElectionError.self) {
      try await Self.run(election)
    }
    #expect(env.calls == ["connect", "acquireLock", "listen", "ignoreSIGPIPE", "detachSession"])
  }
}
