import Dependencies
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What `bsp-mux`'s CLI drives: install a project's `buildServer.json`, or actually run
/// (become the daemon or relay to one) — the "driving port" side of the hexagon, mirroring the
/// "driven port" protocols (`ElectionEnvironment`, `BackendSpawning`, `FileSystemProviding`,
/// ...) `Election`/`DaemonBootstrap`/`Installer` already depend on for the opposite direction.
/// Deliberately independent of `ArgumentParser`/`CLICommand` — plain `String`/`Bool`/`[String]`
/// params — so nothing about parsing argv leaks into what "install" or "run" actually mean.
public protocol BSPMuxApplication: Sendable {
  @discardableResult
  func install(workspaceRoot: String, multiplexerExecutable: String, force: Bool) throws -> InstallResult

  /// `standardIn`/`standardOut` are the winner-or-relay's own stdio - passed in per call, not
  /// stored, so a caller that never reaches `.run` (e.g. `install`) never pays for constructing
  /// them. Protocol requirements can't carry default argument values, so the CLI entry point
  /// (`main.swift`) is what actually supplies real fds - matching `RelaySession.run`'s own
  /// existing convention that fd 0/1 wiring belongs to whoever constructs a real process, not to
  /// the type doing the work.
  func run(workspaceRoot: String, backendArgv: [String], standardIn: any ByteSource, standardOut: any ByteSink) async throws
}

/// The one production implementation of `BSPMuxApplication`: orchestrates `Installer`,
/// `Election`, `RelaySession`, and `DaemonBootstrap` — the composition `main.swift` (the CLI
/// driving adapter) calls into, so it never has to know any of those types exist. Named to
/// match this module's existing `Real*` convention for adapters (`RealElectionEnvironment`,
/// `RealBackendSpawning`, ...) even though this sits on the driving side - it's still "the real
/// one" as opposed to whatever a test constructs in its place.
public struct RealBSPMuxApplication: BSPMuxApplication {
  public init() {}

  @discardableResult
  public func install(workspaceRoot: String, multiplexerExecutable: String, force: Bool) throws -> InstallResult {
    try Installer().install(workspaceRoot: workspaceRoot, multiplexerExecutable: multiplexerExecutable, force: force)
  }

  public func run(
    workspaceRoot: String, backendArgv: [String], standardIn: any ByteSource, standardOut: any ByteSink
  ) async throws {
    let key = ProjectKey(workspaceRoot: workspaceRoot, backendArgv: backendArgv)
    let paths = ProjectPaths(key: key)
    try paths.ensureBaseDirectoryExists()

    switch try await Election(paths: paths).run() {
    case .relay(let connection):
      try await RelaySession.run(connection: connection, standardIn: standardIn, standardOut: standardOut)

    case .daemon(let listening, _):
      // The lock's fd is deliberately never closed here (see ElectionEnvironment's doc comment -
      // process exit is the only correct release); same rule for `listening`'s fd (see
      // AcceptLoop's doc comment).
      let winnerChannel = FramedDuplexChannel(source: standardIn, sink: standardOut)
      let daemon = try await DaemonBootstrap.start(
        argv: backendArgv, workspaceRoot: workspaceRoot, listening: listening, winnerChannel: winnerChannel
      )

      // Scoped to exactly the daemon's lifetime - a relay process has no persistent resources of
      // its own (no socket, no held lock), so default OS disposition on SIGTERM/SIGINT already
      // closes its fds via ordinary process death, which the daemon on the other end handles as
      // an ordinary client disconnect. No guard against this firing right as `waitForShutdown()`
      // below also resolves naturally: harmless in production, since whichever `DaemonTeardown`
      // call reaches `exit()` first actually ends the process before the other could matter.
      @Dependency(\.signalHandling) var signalHandling
      signalHandling.onSignal(SIGTERM) {
        Task { await DaemonTeardown.run(reason: .signal(SIGTERM), socketPath: paths.socketPath) }
      }
      signalHandling.onSignal(SIGINT) {
        Task { await DaemonTeardown.run(reason: .signal(SIGINT), socketPath: paths.socketPath) }
      }

      await daemon.waitForShutdown()
      await DaemonTeardown.run(reason: .normal, socketPath: paths.socketPath)
    }
  }
}
