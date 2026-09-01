import Foundation

@testable import BSPMuxCore

/// Scripted `SocketAccepting` fake, mirroring `FakeElectionEnvironment`/`FakeBackendSpawning`'s
/// own scripted-queue convention with one deliberate deviation: once `results` is exhausted,
/// `accept()` **throws** a terminal error rather than crashing (`fatalError`) or suspending
/// forever. `AcceptLoop.run` calls `accept()` in an infinite loop, so "crash when exhausted"
/// would fire almost immediately in any test that doesn't script infinitely many connections,
/// and "suspend forever" would leave an unobservable task behind with no way to assert the loop
/// actually ended. Throwing means every test - even one that doesn't care about the accept loop
/// at all - gets a real, observable exercise of `AcceptLoop`'s own "accept() failing ends the
/// loop, not the daemon" path for free.
final class FakeSocketAccepting: SocketAccepting, @unchecked Sendable {
  enum AcceptResult {
    case success(ConnectionHandle)
    case failure(SocketAcceptError)
  }

  private var results: [AcceptResult]
  private(set) var acceptCalls: [ListeningHandle] = []

  init(results: [AcceptResult] = []) {
    self.results = results
  }

  func accept(on listening: ListeningHandle) async throws -> ConnectionHandle {
    acceptCalls.append(listening)
    guard !results.isEmpty else {
      throw SocketAcceptError(description: "FakeSocketAccepting: no more scripted connections")
    }
    switch results.removeFirst() {
    case .success(let handle): return handle
    case .failure(let error): throw error
    }
  }
}
