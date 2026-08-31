import Foundation

@testable import BSPMuxCore

/// In-memory `ByteSource`/`ByteSink` fake, backed by a single `AsyncStream` so `read` suspends
/// naturally when nothing's queued instead of polling. `continuation` is exposed directly
/// (`AsyncStream.Continuation` is itself `Sendable`) so a test can push more data mid-test
/// without hopping through the actor, and so `read` never has to hold a mutable `Iterator` as
/// actor-isolated state across a suspension point - each call makes a fresh iterator over the
/// same underlying stream instead. Confirmed empirically that `AsyncStream.Iterator.next()`
/// returns `nil` as soon as the awaiting task is cancelled, even with nothing ever yielded and
/// the stream never finished — exactly `Relay`'s `group.cancelAll()` once one direction ends —
/// so leaving the continuation unfinished (via `remainsOpenWhenExhausted`) is enough to simulate
/// "still connected, nothing to read yet" for exercising cross-cancellation, with no manual
/// cancellation handling needed here.
actor FakeByteStream: ByteSource, ByteSink {
  private(set) var writtenChunks: [Data] = []
  private let stream: AsyncStream<Data>
  let continuation: AsyncStream<Data>.Continuation
  private var readError: Error?

  init(chunks: [Data] = [], remainsOpenWhenExhausted: Bool = false, readError: Error? = nil) {
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    self.stream = stream
    self.continuation = continuation
    for chunk in chunks {
      continuation.yield(chunk)
    }
    if !remainsOpenWhenExhausted {
      continuation.finish()
    }
    self.readError = readError
  }

  func read() async throws -> Data? {
    if let error = readError {
      readError = nil
      throw error
    }
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
  }

  func write(_ data: Data) async throws {
    writtenChunks.append(data)
  }
}
