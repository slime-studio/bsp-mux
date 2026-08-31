import Clocks
import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct ElectionTests {
  // A computed property, not `static let`: a stored `let` would construct its ProjectKey (and
  // so read @Dependency(\.fileSystem)) lazily on first access from whichever test happens to
  // touch it first - outside any withDependencies scope, and nondeterministically depending on
  // test execution order. Recomputing it fresh inside its own scope every time sidesteps that.
  static var paths: ProjectPaths {
    withDependencies {
      $0.fileSystem = InMemoryFileSystem()
    } operation: {
      ProjectPaths(
        key: ProjectKey(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: [:]),
        baseDirectory: "/tmp/bsp-mux-test-election"
      )
    }
  }

  /// Runs `election.run()` with fakes standing in for its dependencies: an `ImmediateClock` so
  /// a test that reaches the poll loop resolves every `sleep` instantly instead of actually
  /// waiting, the given `ElectionEnvironment` fake, and an in-memory filesystem by default.
  static func run(
    _ election: Election,
    environment: ElectionEnvironment,
    fileSystem: FileSystemProviding = InMemoryFileSystem()
  ) async throws -> ElectionOutcome {
    try await withDependencies {
      $0.continuousClock = ImmediateClock()
      $0.electionEnvironment = environment
      $0.fileSystem = fileSystem
    } operation: {
      try await election.run()
    }
  }

  @Test func immediateConnectSuccessBecomesRelayWithoutTouchingTheLock() async throws {
    let handle = ConnectionHandle(fileDescriptor: 7)
    let env = FakeElectionEnvironment(connectResults: [.success(handle)])
    let election = Election(paths: Self.paths)

    let outcome = try await Self.run(election, environment: env)

    #expect(outcome == .relay(handle))
    #expect(env.calls == ["connect", "ignoreSIGPIPE"])
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
    let election = Election(paths: Self.paths)

    let outcome = try await Self.run(election, environment: env, fileSystem: fs)

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
    let election = Election(paths: Self.paths)

    let outcome = try await Self.run(election, environment: env)

    #expect(outcome == .relay(handle))
    #expect(env.calls == ["connect", "acquireLock", "connect", "ignoreSIGPIPE"])
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
    let election = Election(paths: Self.paths)

    let outcome = try await Self.run(election, environment: env, fileSystem: fs)

    #expect(outcome == .daemon(listening, lock))
    #expect(env.calls == ["connect", "acquireLock", "connect", "acquireLock", "listen", "ignoreSIGPIPE", "detachSession"])
    #expect(fs.removedPaths == [Self.paths.socketPath])
  }

  @Test func nonAbsenceConnectErrorPropagatesRatherThanBeingTreatedAsNoDaemon() async {
    let env = FakeElectionEnvironment(connectResults: [.failure(ElectionError(description: "connect failed: permission denied"))])
    let election = Election(paths: Self.paths)

    await #expect(throws: ElectionError.self) {
      try await Self.run(election, environment: env)
    }
  }

  @Test func lockAcquireErrorPropagates() async {
    let env = FakeElectionEnvironment(
      connectResults: [.absent],
      lockResults: [.failure(ElectionError(description: "flock failed: no locks available"))]
    )
    let election = Election(paths: Self.paths)

    await #expect(throws: ElectionError.self) {
      try await Self.run(election, environment: env)
    }
  }

  @Test func listenErrorPropagatesAfterAcquiringLock() async throws {
    let env = FakeElectionEnvironment(
      connectResults: [.absent],
      lockResults: [.acquired(LockHandle(fileDescriptor: 3))]
    )
    env.listenResult = .failure(ElectionError(description: "bind failed: address in use"))
    let fs = InMemoryFileSystem()
    let election = Election(paths: Self.paths)

    await #expect(throws: ElectionError.self) {
      try await Self.run(election, environment: env, fileSystem: fs)
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
    let election = Election(paths: Self.paths)

    await #expect(throws: ElectionError.self) {
      try await Self.run(election, environment: env)
    }
    #expect(env.calls == ["connect", "acquireLock", "listen", "ignoreSIGPIPE", "detachSession"])
  }
}
