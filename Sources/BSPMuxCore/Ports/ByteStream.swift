import Foundation

/// A raw, unframed byte source — stdin, or a connected socket's read direction. Deliberately
/// lower-level than `DuplexChannel`: `Relay` exists specifically to avoid any JSON-RPC parsing,
/// since whatever's on the other end of the socket already does its own per-connection framing.
public protocol ByteSource: Sendable {
  /// Reads the next chunk of available bytes, or `nil` once the source has reached EOF.
  func read() async throws -> Data?
}

/// A raw, unframed byte sink — stdout, or a connected socket's write direction.
public protocol ByteSink: Sendable {
  func write(_ data: Data) async throws
}

/// A connected socket, readable and writable, as both directions of `Relay`'s pump need.
public typealias DuplexByteStream = ByteSource & ByteSink
