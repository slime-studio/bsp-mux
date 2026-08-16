import Foundation

@testable import BSPMuxCore

/// In-memory `DuplexChannel` fake: `send` records every message body for assertions, and
/// `receive` yields whatever's been queued via `enqueueIncoming`. An actor (not a class)
/// since `DuplexChannel` requires `Sendable` conformances, and this holds genuinely mutable
/// state `Daemon` calls into concurrently across sessions.
actor FakeDuplexChannel: DuplexChannel {
  private(set) var sentMessages: [Data] = []
  private var pendingIncoming: [Data] = []
  private var readError: Error?

  init(readError: Error? = nil) {
    self.readError = readError
  }

  func send(_ body: Data) async throws {
    sentMessages.append(body)
  }

  func receive() async throws -> Data? {
    if let error = readError {
      readError = nil
      throw error
    }
    guard !pendingIncoming.isEmpty else { return nil }
    return pendingIncoming.removeFirst()
  }

  func enqueueIncoming(_ data: Data) {
    pendingIncoming.append(data)
  }
}
