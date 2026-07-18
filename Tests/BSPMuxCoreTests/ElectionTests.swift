import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct ElectionTests {
  static let paths = ProjectPaths(
    key: ProjectKey(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: [:]),
    baseDirectory: "/tmp/bsp-mux-test-election"
  )

  /// A sleep that just records how many times it was asked to wait, instead of actually
  /// waiting — keeps the poll-loop tests instant.
  static func noOpSleep(callCount: UnsafeSendableBox<Int>) -> @Sendable (TimeInterval) -> Void {
    { _ in callCount.value += 1 }
  }

  @Test func immediateConnectSuccessBecomesRelayWithoutTouchingTheLock() throws {
    let handle = ConnectionHandle(fileDescriptor: 7)
    let env = FakeElectionEnvironment(connectResults: [.success(handle)])
    let election = Election(paths: Self.paths, environment: env, sleep: { _ in })

    let outcome = try election.run()

    #expect(outcome == .relay(handle))
    #expect(env.calls == ["connect"])
  }

  @Test func connectFailsThenLockAcquiredBecomesDaemonInCorrectOrder() throws {
    let lock = LockHandle(fileDescriptor: 3)
    let listening = ListeningHandle(fileDescriptor: 4)
    let env = FakeElectionEnvironment(
      connectResults: [.absent],
      lockResults: [.acquired(lock)]
    )
    env.listenResult = .success(listening)
    let election = Election(paths: Self.paths, environment: env, sleep: { _ in })

    let outcome = try election.run()

    #expect(outcome == .daemon(listening, lock))
    #expect(env.calls == ["connect", "acquireLock", "unlink", "listen", "ignoreSIGPIPE", "detachSession"])
    #expect(env.unlinkedPaths == [Self.paths.socketPath])
  }

  @Test func connectFailsAndLockContendedThenConnectSucceedsBecomesRelay() throws {
    let handle = ConnectionHandle(fileDescriptor: 9)
    let callCount = UnsafeSendableBox(0)
    let env = FakeElectionEnvironment(
      connectResults: [.absent, .success(handle)],
      lockResults: [.contended]
    )
    let election = Election(paths: Self.paths, environment: env, sleep: Self.noOpSleep(callCount: callCount))

    let outcome = try election.run()

    #expect(outcome == .relay(handle))
    #expect(env.calls == ["connect", "acquireLock", "connect"])
    #expect(callCount.value == 1)
  }

  @Test func connectFailsAndLockContendedThenLockFreesUpBecomesDaemon() throws {
    // Models the previous lock holder dying mid-startup: still no live daemon to connect to
    // on the second attempt, but the lock is free now.
    let lock = LockHandle(fileDescriptor: 5)
    let listening = ListeningHandle(fileDescriptor: 6)
    let callCount = UnsafeSendableBox(0)
    let env = FakeElectionEnvironment(
      connectResults: [.absent, .absent],
      lockResults: [.contended, .acquired(lock)]
    )
    env.listenResult = .success(listening)
    let election = Election(paths: Self.paths, environment: env, sleep: Self.noOpSleep(callCount: callCount))

    let outcome = try election.run()

    #expect(outcome == .daemon(listening, lock))
    #expect(env.calls == ["connect", "acquireLock", "connect", "acquireLock", "unlink", "listen", "ignoreSIGPIPE", "detachSession"])
    #expect(callCount.value == 1)
  }

  @Test func nonAbsenceConnectErrorPropagatesRatherThanBeingTreatedAsNoDaemon() {
    let env = FakeElectionEnvironment(connectResults: [.failure(ElectionError(description: "connect failed: permission denied"))])
    let election = Election(paths: Self.paths, environment: env, sleep: { _ in })

    #expect(throws: ElectionError.self) {
      try election.run()
    }
  }

  @Test func lockAcquireErrorPropagates() {
    let env = FakeElectionEnvironment(
      connectResults: [.absent],
      lockResults: [.failure(ElectionError(description: "flock failed: no locks available"))]
    )
    let election = Election(paths: Self.paths, environment: env, sleep: { _ in })

    #expect(throws: ElectionError.self) {
      try election.run()
    }
  }

  @Test func listenErrorPropagatesAfterAcquiringLock() {
    let env = FakeElectionEnvironment(
      connectResults: [.absent],
      lockResults: [.acquired(LockHandle(fileDescriptor: 3))]
    )
    env.listenResult = .failure(ElectionError(description: "bind failed: address in use"))
    let election = Election(paths: Self.paths, environment: env, sleep: { _ in })

    #expect(throws: ElectionError.self) {
      try election.run()
    }
    // Still unlinked the stale socket before the failing listen() attempt.
    #expect(env.calls == ["connect", "acquireLock", "unlink", "listen"])
  }

  @Test func detachSessionErrorPropagatesAfterListenAndIgnoreSIGPIPE() {
    let env = FakeElectionEnvironment(
      connectResults: [.absent],
      lockResults: [.acquired(LockHandle(fileDescriptor: 3))]
    )
    env.detachSessionError = ElectionError(description: "setsid failed: unexpected errno")
    let election = Election(paths: Self.paths, environment: env, sleep: { _ in })

    #expect(throws: ElectionError.self) {
      try election.run()
    }
    #expect(env.calls == ["connect", "acquireLock", "unlink", "listen", "ignoreSIGPIPE", "detachSession"])
  }
}

/// Plain reference box for counting calls from a `@Sendable` closure in tests. Not
/// thread-safe, which is fine: `Election.run()` calls `sleep` synchronously on one thread.
final class UnsafeSendableBox<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}
