import Foundation

/// Composes a `RealByteSource` and a `RealByteSink` over the same file descriptor into a single
/// `DuplexByteStream` — what `Relay.run`'s `socket:` parameter needs, and what a client's own
/// stdio needs when wiring it up as a session's channel. `RealByteSource`/`RealByteSink` stay
/// separate types (matching `ByteSource`/`ByteSink` being separate protocols) since not every
/// caller needs both directions on the same fd - `Relay`'s `standardIn`/`standardOut` are two
/// distinct fds, each needing only one direction.
///
/// Safe for both to independently set the fd non-blocking (each does, in its own `init`):
/// `O_NONBLOCK` is a property of the shared underlying open file description, so both ends up
/// applying the same flag redundantly, not conflicting settings - and both `RealByteSource` and
/// `RealByteSink` are already written to handle that shared-fd non-blocking behavior correctly
/// (see their doc comments).
public struct RealDuplexByteStream: ByteSource, ByteSink {
  private let source: RealByteSource
  private let sink: RealByteSink

  public init(fileDescriptor: Int32) {
    self.source = RealByteSource(fileDescriptor: fileDescriptor)
    self.sink = RealByteSink(fileDescriptor: fileDescriptor)
  }

  public func read() async throws -> Data? {
    try await source.read()
  }

  public func write(_ data: Data) async throws {
    try await sink.write(data)
  }
}
