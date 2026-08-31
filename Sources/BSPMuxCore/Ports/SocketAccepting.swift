import Dependencies

/// Accepts new client connections on the daemon's listening socket, one at a time, for as long
/// as the daemon runs. Deliberately separate from `ElectionEnvironment`: that protocol is scoped
/// to the connect/flock race `Election` performs once at startup, not the ongoing acceptance of
/// new sessions throughout the daemon's life.
public protocol SocketAccepting: Sendable {
  /// Awaits and returns the next connection accepted on `listening`.
  func accept(on listening: ListeningHandle) async throws -> ConnectionHandle
}

public struct SocketAcceptError: Swift.Error, CustomStringConvertible, Equatable {
  public let description: String

  public init(description: String) {
    self.description = description
  }
}

extension DependencyValues {
  public var socketAccepting: any SocketAccepting {
    get { self[SocketAcceptingKey.self] }
    set { self[SocketAcceptingKey.self] = newValue }
  }

  private enum SocketAcceptingKey: DependencyKey {
    static let liveValue: any SocketAccepting = RealSocketAccepting()
  }
}
