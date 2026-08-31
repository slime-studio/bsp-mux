import Foundation

@testable import BSPMuxCore

/// Scripted `BackendSpawning` fake, mirroring `FakeElectionEnvironment`'s own scripted-queue
/// convention: each call to `spawn` pops the next canned result off the queue and records its
/// arguments for assertions.
final class FakeBackendSpawning: BackendSpawning, @unchecked Sendable {
  enum SpawnResult {
    case success(any DuplexChannel)
    case failure(BackendSpawnError)
  }

  private var results: [SpawnResult]
  private(set) var spawnCalls: [(argv: [String], workingDirectory: String)] = []

  init(results: [SpawnResult]) {
    self.results = results
  }

  func spawn(argv: [String], workingDirectory: String) async throws -> any DuplexChannel {
    spawnCalls.append((argv, workingDirectory))
    guard !results.isEmpty else {
      fatalError("FakeBackendSpawning: spawn() called more times than scripted")
    }
    switch results.removeFirst() {
    case .success(let channel): return channel
    case .failure(let error): throw error
    }
  }
}
