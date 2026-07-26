import Foundation

/// Composes any `ByteSource`/`ByteSink` pair with `MessageFraming`/`MessageFrameReader` to
/// satisfy `DuplexChannel`'s "complete message body" contract - the thing `Daemon`/`ClientSession`
/// actually need over a real socket or stdio connection, versus `Relay`'s raw, framing-free path.
/// Pure composition with no I/O of its own, so it's fully testable against `FakeByteStream`
/// rather than needing a separate real/fake split the way `RealByteSource`/`RealByteSink` do.
///
/// An actor, with explicit turn-taking on `receive()` for the same reason `RealByteSource` has
/// its own: only one caller is expected to drive a channel's receive loop today, but a plain
/// actor's reentrancy wouldn't actually prevent two concurrent `receive()` calls from
/// interleaving their own `source.read()` attempts against the same shared `frameReader` state
/// in a way that delivers a message to whichever call happened to complete it rather than
/// whichever asked first. `send()` doesn't need the same treatment - it touches no state of its
/// own, just delegates straight to `sink.write()`, which (for `RealByteSink`) already serializes
/// itself.
public actor FramedDuplexChannel: DuplexChannel {
  private let source: any ByteSource
  private let sink: any ByteSink
  private var frameReader = MessageFrameReader()
  private var pendingMessages: [Data] = []
  private var isReceiving = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(source: any ByteSource, sink: any ByteSink) {
    self.source = source
    self.sink = sink
  }

  public func send(_ body: Data) async throws {
    try await sink.write(MessageFraming.frame(body))
  }

  public func receive() async throws -> Data? {
    await acquireTurn()
    defer { releaseTurn() }

    if !pendingMessages.isEmpty {
      return pendingMessages.removeFirst()
    }

    while true {
      guard let chunk = try await source.read() else {
        if frameReader.hasBufferedPartialData {
          throw MessageFrameError(description: "connection closed with a partial message still buffered")
        }
        return nil
      }
      let messages = try frameReader.feed(chunk)
      guard !messages.isEmpty else { continue }
      pendingMessages = messages
      return pendingMessages.removeFirst()
    }
  }

  private func acquireTurn() async {
    guard isReceiving else {
      isReceiving = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func releaseTurn() {
    guard !waiters.isEmpty else {
      isReceiving = false
      return
    }
    waiters.removeFirst().resume()
  }
}
