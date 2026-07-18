import Foundation

@testable import BSPMuxCore

/// Scripted `ElectionEnvironment` fake: each call to `connect`/`acquireLockNonBlocking` pops
/// the next canned result off its queue, and every call is recorded in `calls` so tests can
/// assert both outcome and call ordering. Crashes (via `fatalError`) if a call happens beyond
/// what's scripted, rather than looping forever or returning a made-up default — a test that
/// hits this needs more scripted steps, not a silent fallback.
final class FakeElectionEnvironment: ElectionEnvironment, @unchecked Sendable {
  enum ConnectResult {
    case success(ConnectionHandle)
    case absent
    case failure(ElectionError)
  }

  enum LockResult {
    case acquired(LockHandle)
    case contended
    case failure(ElectionError)
  }

  private var connectResults: [ConnectResult]
  private var lockResults: [LockResult]
  private(set) var calls: [String] = []
  private(set) var unlinkedPaths: [String] = []

  var listenResult: Result<ListeningHandle, ElectionError> = .success(ListeningHandle(fileDescriptor: 99))
  var detachSessionError: ElectionError?

  init(connectResults: [ConnectResult] = [], lockResults: [LockResult] = []) {
    self.connectResults = connectResults
    self.lockResults = lockResults
  }

  func connect(to socketPath: String) throws -> ConnectionHandle? {
    calls.append("connect")
    guard !connectResults.isEmpty else {
      fatalError("FakeElectionEnvironment: connect() called more times than scripted")
    }
    switch connectResults.removeFirst() {
    case .success(let handle): return handle
    case .absent: return nil
    case .failure(let error): throw error
    }
  }

  func acquireLockNonBlocking(atPath lockPath: String) throws -> LockHandle? {
    calls.append("acquireLock")
    guard !lockResults.isEmpty else {
      fatalError("FakeElectionEnvironment: acquireLockNonBlocking() called more times than scripted")
    }
    switch lockResults.removeFirst() {
    case .acquired(let handle): return handle
    case .contended: return nil
    case .failure(let error): throw error
    }
  }

  func unlinkIfExists(_ path: String) {
    calls.append("unlink")
    unlinkedPaths.append(path)
  }

  func listen(at socketPath: String) throws -> ListeningHandle {
    calls.append("listen")
    return try listenResult.get()
  }

  func ignoreSIGPIPE() {
    calls.append("ignoreSIGPIPE")
  }

  func detachSession() throws {
    calls.append("detachSession")
    if let error = detachSessionError {
      throw error
    }
  }
}
