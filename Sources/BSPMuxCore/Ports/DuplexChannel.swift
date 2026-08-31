import Foundation

/// An abstract bidirectional message channel — the daemon's own stdio for the client that won
/// election, or an accepted socket connection for every subsequent client. `Daemon` never
/// needs to know which one it's holding; both look identical here. Deals in message bodies,
/// not raw wire bytes — framing (`Content-Length`) is each conformance's own concern.
public protocol DuplexChannel: Sendable {
  /// Sends a single message body. The conformance is responsible for framing it on the wire.
  func send(_ body: Data) async throws

  /// Awaits and returns the next complete message body, or `nil` once the channel has closed
  /// (EOF/disconnect) with nothing further to deliver.
  func receive() async throws -> Data?
}

/// Identifies one connected client for as long as it stays connected. Minted by `Daemon` when
/// a session registers; never reused within a daemon's lifetime.
public struct SessionID: Sendable, Hashable {
  public let value: Int

  public init(_ value: Int) {
    self.value = value
  }
}

/// Per-connection state over an abstract `DuplexChannel`. Deliberately thin today — the
/// meatier multiplexing state (id-rewrite tables, originId ownership, the session registry
/// itself) lives on `Daemon`, since it's about routing *between* sessions rather than being
/// specific to any one of them.
public struct ClientSession: Sendable {
  public let id: SessionID
  public let channel: any DuplexChannel

  public init(id: SessionID, channel: any DuplexChannel) {
    self.id = id
    self.channel = channel
  }

  public func send(_ body: Data) async throws {
    try await channel.send(body)
  }
}
