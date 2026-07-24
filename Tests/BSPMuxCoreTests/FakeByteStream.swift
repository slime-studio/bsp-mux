import Foundation

@testable import BSPMuxCore

/// In-memory `ByteSource`/`ByteSink` fake. `write` records every chunk for assertions; `read`
/// yields the preset chunks in order, then either signals EOF (the default — matches a real
/// stream that's actually done) or hangs until cancelled if `remainsOpenWhenExhausted` is set,
/// which is how tests simulate "still connected, nothing to read yet" to exercise `Relay`'s
/// cross-cancellation behavior without deadlocking the test itself.
actor FakeByteStream: ByteSource, ByteSink {
  private(set) var writtenChunks: [Data] = []
  private var pendingChunks: [Data]
  private let remainsOpenWhenExhausted: Bool
  private var readError: Error?

  init(chunks: [Data] = [], remainsOpenWhenExhausted: Bool = false, readError: Error? = nil) {
    self.pendingChunks = chunks
    self.remainsOpenWhenExhausted = remainsOpenWhenExhausted
    self.readError = readError
  }

  func read() async throws -> Data? {
    if !pendingChunks.isEmpty {
      return pendingChunks.removeFirst()
    }
    if let error = readError {
      readError = nil
      throw error
    }
    guard remainsOpenWhenExhausted else { return nil }
    while !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
  }

  func write(_ data: Data) async throws {
    writtenChunks.append(data)
  }
}
