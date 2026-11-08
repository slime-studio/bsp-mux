import Dependencies
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Finds the running daemon for a workspace (if any) and asks it to shut down - the logic
/// behind `bsp-mux stop`. Connects to the daemon's own socket exactly like a relay would
/// (`ElectionEnvironment.connect`, already the correct "is anyone listening" check - `nil`
/// already means "no daemon" whether the socket path is absent or stale) and sends it one
/// framed `bspMux/stop` notification, rather than tracking a PID anywhere - see this feature's
/// own design notes for why (a PID file was considered and rejected: it would add a new
/// per-daemon file and the usual PID-reuse caveat, for no benefit over the socket this project
/// already has for everything else).
public struct DaemonStopSignal {
  public struct Error: Swift.Error, CustomStringConvertible {
    public let description: String
  }

  @Dependency(\.fileSystem) private var fileSystem
  @Dependency(\.electionEnvironment) private var environment
  @Dependency(\.continuousClock) private var clock

  public init() {}

  /// - Parameters:
  ///   - multiplexerExecutable: This binary's own path, to confirm `buildServer.json` was
  ///     actually wrapped by *us* before trusting its `argv` to recover the real backend's -
  ///     the same check `Installer.install`'s own `alreadyWrapped` already makes.
  ///   - force: Use `SIGKILL` rather than `SIGTERM` for the backend's process-group signal, in
  ///     case it's ignoring `SIGTERM`. Both are fully cooperative paths - the daemon must still
  ///     be alive and processing messages to honor either (see this type's own design notes for
  ///     why a genuinely deadlocked daemon is a known, accepted gap here).
  public func stop(workspaceRoot: String, multiplexerExecutable: String, force: Bool) async throws -> StopResult {
    let buildServerJSONPath = "\(workspaceRoot)/buildServer.json"
    guard fileSystem.fileExists(atPath: buildServerJSONPath) else {
      throw Error(description: "No buildServer.json found at \(buildServerJSONPath) - nothing to stop.")
    }

    let data = try fileSystem.contents(atPath: buildServerJSONPath)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Error(description: "\(buildServerJSONPath) does not contain a JSON object")
    }
    guard let wrappedArgv = json["argv"] as? [String], !wrappedArgv.isEmpty else {
      throw Error(description: "\(buildServerJSONPath) has no non-empty 'argv' array")
    }
    let resolvedMultiplexerPath = fileSystem.resolvePath(multiplexerExecutable)
    guard wrappedArgv.first.map({ fileSystem.resolvePath($0) }) == resolvedMultiplexerPath else {
      throw Error(
        description: "\(buildServerJSONPath) isn't wrapped by bsp-mux - run `bsp-mux install` first."
      )
    }

    let backendArgv = Installer.backendArgv(unwrapping: wrappedArgv)
    let key = findRunningProjectKey(workspaceRoot: workspaceRoot, backendArgv: backendArgv)
    let paths = ProjectPaths(key: key)

    guard let connection = try environment.connect(to: paths.socketPath) else {
      return StopResult(outcome: .notRunning)
    }
    let stream = RealDuplexByteStream(fileDescriptor: connection.fileDescriptor)
    let channel = FramedDuplexChannel(source: stream, sink: stream)
    let message = #"{"jsonrpc":"2.0","method":"bspMux/stop","params":{"force":\#(force)}}"#
    defer { close(connection.fileDescriptor) }
    try await channel.send(Data(message.utf8))

    // Confirm the daemon actually exited, rather than just hoping the message got through or
    // trusting the socket's disappearance alone - DaemonTeardown unlinks the socket *before*
    // signaling/exiting the backend, so a gone socket doesn't yet mean the backend is actually
    // down. The flock (held for the daemon's entire lifetime, released only by the kernel on
    // exit - see Election's own reasoning) is the authoritative "is a daemon still alive"
    // signal, so poll that instead. Bounded so a daemon that never responds (the accepted
    // "genuinely deadlocked" gap) fails loudly instead of this hanging forever.
    for _ in 0..<60 {
      if let lock = try environment.acquireLockNonBlocking(atPath: paths.lockPath) {
        close(lock.fileDescriptor)
        return StopResult(outcome: .stopped)
      }
      try await clock.sleep(for: .milliseconds(50))
    }
    throw Error(
      description:
        "Sent the stop request, but the daemon at \(paths.socketPath) didn't respond within 3s - "
        + "it may be stuck. You may need to find and stop its process manually."
    )
  }

  /// Finds the `ProjectKey` for the daemon actually running for this (workspaceRoot,
  /// backendArgv) pair, without needing to reproduce whatever environment originally elected
  /// it - this runs from an arbitrary shell invoking `bsp-mux stop`, not necessarily the same
  /// process tree (e.g. an editor) that launched the daemon, so `DEVELOPER_DIR`/`TOOLCHAINS`
  /// here may legitimately differ from what the daemon's own `ProjectKey` hashed. `Election`
  /// persists a `ProjectKeyMeta` sidecar alongside the socket precisely so a lookup like this
  /// can match on `workspaceRoot`/`backendArgv` alone and reuse the daemon's real `fullHash`
  /// directly, rather than guessing at a hash. Falls back to recomputing from this process's
  /// own environment (the only option before that sidecar existed) if no sidecar matches - a
  /// daemon that hasn't reached that point in its own startup yet, or one from before this
  /// wiring existed.
  /// Not `private`: tested directly (`@testable import`) so its selection logic can be verified
  /// without fighting `FakeElectionEnvironment`'s canned results, which don't vary by the path
  /// they're asked to connect to - same reasoning as `ProjectKey.resolveArgv`'s own visibility.
  ///
  /// Known accepted gap: if two *genuinely different* daemons are both alive for the same
  /// (workspaceRoot, backendArgv) at once - a deliberately rare setup, e.g. the same project
  /// opened under two different `DEVELOPER_DIR`s on purpose - their sidecars are indistinguishable
  /// by this lookup, and the lexicographically-first one wins arbitrarily. Resolving that would
  /// mean surfacing the ambiguity to the caller instead of silently picking one; not attempted
  /// here since the common case (exactly one daemon) is what this fixes.
  func findRunningProjectKey(workspaceRoot: String, backendArgv: [String]) -> ProjectKey {
    let baseDirectory = ProjectPaths.defaultBaseDirectory()
    let resolvedWorkspaceRoot = fileSystem.resolvePath(workspaceRoot)
    let resolvedBackendArgv = ProjectKey.resolveArgv(backendArgv, using: fileSystem)
    let metaRepository = ProjectKeyMetaRepository()

    for entry in fileSystem.contentsOfDirectory(atPath: baseDirectory).sorted() where entry.hasSuffix(".meta.json") {
      guard let meta = try? metaRepository.load(from: "\(baseDirectory)/\(entry)"),
        meta.workspaceRoot == resolvedWorkspaceRoot, meta.backendArgv == resolvedBackendArgv
      else { continue }
      return ProjectKey(fullHash: meta.fullHash)
    }
    return ProjectKey(workspaceRoot: workspaceRoot, backendArgv: backendArgv)
  }
}

public struct StopResult: Equatable {
  public enum Outcome: Equatable {
    case stopped
    case notRunning
  }
  public let outcome: Outcome
}
