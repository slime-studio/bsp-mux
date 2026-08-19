import Dependencies

/// Spawns the real backend process named by (resolved, per `ProjectKey`'s own key-derivation
/// assumptions) `argv` and wires its stdin/stdout into a `DuplexChannel` — the thing `Daemon`
/// actually talks to as `backend`.
///
/// `async throws` rather than plain `throws`: the real implementation is backed by
/// `swift-subprocess`, whose interactive I/O only exists inside a closure-scoped call that
/// itself represents the process's entire running lifetime — there's no separate synchronous
/// "just launch it" step the way `Foundation.Process`/`ElectionEnvironment.listen` have. `spawn`
/// only returns once the process has actually launched (confirmed empirically: a launch
/// failure - bad executable, bad working directory - throws before that closure ever starts
/// running), with the ongoing session kept alive in the background for as long as the returned
/// channel is used.
public protocol BackendSpawning: Sendable {
  /// - Parameters:
  ///   - argv: The backend's executable and arguments. `argv[0]` must already be an absolute,
  ///     resolvable path — this doesn't perform its own `PATH` search, consistent with
  ///     `ProjectKey` treating `argv[0]` as something already realpath'd for key derivation.
  ///   - workingDirectory: The directory the backend is launched in — the project's workspace
  ///     root, so any relative paths the backend itself resolves land where it expects.
  func spawn(argv: [String], workingDirectory: String) async throws -> any DuplexChannel
}

public struct BackendSpawnError: Swift.Error, CustomStringConvertible, Equatable {
  public let description: String

  public init(description: String) {
    self.description = description
  }
}

extension DependencyValues {
  public var backendSpawning: any BackendSpawning {
    get { self[BackendSpawningKey.self] }
    set { self[BackendSpawningKey.self] = newValue }
  }

  private enum BackendSpawningKey: DependencyKey {
    static let liveValue: any BackendSpawning = RealBackendSpawning()
  }
}
