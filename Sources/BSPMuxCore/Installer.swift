import Foundation

/// Wraps a project's existing `buildServer.json` so `sourcekit-lsp` launches our multiplexer
/// instead of the real backend directly. The real backend's `argv` is preserved byte-for-byte,
/// spliced in after a `--` separator — no separate config file or schema needed, since the
/// whole point is that `argv` already fully describes how to launch any BSP backend.
///
/// This has to be an explicit, one-time step: the first time our binary runs for a project, it
/// can't yet know the real backend's argv, because at that point `buildServer.json` either still
/// names the real backend (we haven't taken over yet) or already names us (the real backend's
/// argv is already gone). Something has to perform the "read old argv, write wrapped argv"
/// transformation exactly once, with the old argv in hand — that's what `install` does.
public struct Installer {
  public struct Error: Swift.Error, CustomStringConvertible {
    public let description: String
  }

  private let fileSystem: FileSystemProviding

  public init(fileSystem: FileSystemProviding = RealFileSystem()) {
    self.fileSystem = fileSystem
  }

  /// - Parameters:
  ///   - workspaceRoot: Absolute path to the directory containing `buildServer.json`.
  ///   - multiplexerExecutable: Path to our own binary, to be spliced in as `argv[0]`.
  ///   - force: If the visible `buildServer.json` already wraps our binary, re-derive the
  ///     original backend argv (by unwrapping past the existing `--`) and rewrap it, rather
  ///     than nesting wrappers. Without `force`, an already-wrapped file is a no-op.
  @discardableResult
  public func install(
    workspaceRoot: String,
    multiplexerExecutable: String,
    force: Bool = false
  ) throws -> InstallResult {
    let buildServerJSONPath = "\(workspaceRoot)/buildServer.json"
    guard fileSystem.fileExists(atPath: buildServerJSONPath) else {
      throw Error(
        description:
          "No buildServer.json found at \(buildServerJSONPath). Set up the real BSP backend's "
          + "buildServer.json first (e.g. `sourcekit-xcode-bsp init`), then re-run install."
      )
    }

    let data = try fileSystem.contents(atPath: buildServerJSONPath)
    guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Error(description: "\(buildServerJSONPath) does not contain a JSON object")
    }
    guard let existingArgv = json["argv"] as? [String], !existingArgv.isEmpty else {
      throw Error(description: "\(buildServerJSONPath) has no non-empty 'argv' array")
    }

    let resolvedMultiplexerPath = fileSystem.resolvePath(multiplexerExecutable)
    let resolvedWorkspaceRoot = fileSystem.resolvePath(workspaceRoot)
    let alreadyWrapped = existingArgv.first.map { fileSystem.resolvePath($0) } == resolvedMultiplexerPath

    if alreadyWrapped {
      guard force else {
        return InstallResult(changed: false, wrappedArgv: existingArgv)
      }
      // Unwrap first so a repeated --force install doesn't nest wrappers.
      let backendArgv = Installer.backendArgv(unwrapping: existingArgv)
      return try writeWrapped(
        backendArgv,
        into: &json,
        at: buildServerJSONPath,
        multiplexerPath: resolvedMultiplexerPath,
        workspaceRoot: resolvedWorkspaceRoot
      )
    }

    return try writeWrapped(
      existingArgv,
      into: &json,
      at: buildServerJSONPath,
      multiplexerPath: resolvedMultiplexerPath,
      workspaceRoot: resolvedWorkspaceRoot
    )
  }

  /// Given an already-wrapped argv (`[self, "--workspace-root", root, "--", ...backend]`),
  /// returns just the backend's original argv.
  static func backendArgv(unwrapping wrappedArgv: [String]) -> [String] {
    guard let separatorIndex = wrappedArgv.firstIndex(of: "--") else {
      // Shouldn't happen for anything we wrapped ourselves, but don't crash on a
      // hand-edited file — treat the whole thing (minus argv[0]) as the backend argv.
      return Array(wrappedArgv.dropFirst())
    }
    return Array(wrappedArgv[(separatorIndex + 1)...])
  }

  private func writeWrapped(
    _ backendArgv: [String],
    into json: inout [String: Any],
    at path: String,
    multiplexerPath: String,
    workspaceRoot: String
  ) throws -> InstallResult {
    let wrappedArgv = [multiplexerPath, "--workspace-root", workspaceRoot, "--"] + backendArgv
    json["argv"] = wrappedArgv
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try fileSystem.write(data, toPath: path)
    return InstallResult(changed: true, wrappedArgv: wrappedArgv)
  }
}

public struct InstallResult: Equatable {
  /// False if `buildServer.json` was already wrapped and `force` wasn't passed.
  public let changed: Bool
  public let wrappedArgv: [String]
}
