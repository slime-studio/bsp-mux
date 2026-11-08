import Dependencies
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

  @Dependency(\.fileSystem) private var fileSystem

  public init() {}

  /// Languages sourcekit-lsp treats as relevant when scanning `.bsp/*.json` for a connection
  /// file to use (`ExternalBuildServerAdapter.getConfigPath` in swiftlang/sourcekit-lsp),
  /// matching the rawValues `swift-tools-protocols`' `Language` type defines for them.
  private static let sourceKitRelevantLanguages: Set<String> = [
    "swift", "c", "cpp", "objective-c", "objective-cpp",
  ]

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
    if let competingPath = competingBSPDirConfigPath(workspaceRoot: workspaceRoot) {
      throw Error(
        description:
          "Found \(competingPath), a standard BSP connection file (see "
          + "build-server-protocol.github.io/docs/overview/server-discovery). sourcekit-lsp "
          + "prefers any matching .bsp/*.json over buildServer.json — the one 'buildServer.json' "
          + "is only a pre-6.1 compatibility fallback — so wrapping buildServer.json here would "
          + "have no effect. Remove or update the .bsp config instead."
      )
    }

    let loaded = try BuildServerJSON.load(
      workspaceRoot: workspaceRoot,
      missingFileGuidance: "set up the real BSP backend's buildServer.json first "
        + "(e.g. `sourcekit-xcode-bsp init`), then re-run install.",
      using: fileSystem
    )
    let buildServerJSONPath = loaded.path
    var json = loaded.json
    let existingArgv = loaded.argv

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
  /// returns just the backend's original argv. `public`, not just `internal`: `DaemonStopSignal`
  /// also needs this exact unwrap to recover a workspace's real backend argv from its already-
  /// wrapped `buildServer.json`, and reuses this rather than duplicating the logic.
  public static func backendArgv(unwrapping wrappedArgv: [String]) -> [String] {
    guard let separatorIndex = wrappedArgv.firstIndex(of: "--") else {
      // Shouldn't happen for anything we wrapped ourselves, but don't crash on a
      // hand-edited file — treat the whole thing (minus argv[0]) as the backend argv.
      return Array(wrappedArgv.dropFirst())
    }
    return Array(wrappedArgv[(separatorIndex + 1)...])
  }

  /// sourcekit-lsp scans `<workspaceRoot>/.bsp/*.json` for a file whose `languages` overlaps
  /// the ones it cares about, sorted lexicographically, first match wins — and prefers whatever
  /// it finds there over `buildServer.json` unconditionally. Returns that file's path if one
  /// exists, so `install` can fail loudly instead of silently wrapping a file sourcekit-lsp will
  /// never read.
  private func competingBSPDirConfigPath(workspaceRoot: String) -> String? {
    let bspDir = "\(workspaceRoot)/.bsp"
    for entry in fileSystem.contentsOfDirectory(atPath: bspDir).sorted() where entry.hasSuffix(".json") {
      let path = "\(bspDir)/\(entry)"
      guard let data = try? fileSystem.contents(atPath: path),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let languages = json["languages"] as? [String]
      else { continue }
      if !Set(languages).isDisjoint(with: Self.sourceKitRelevantLanguages) {
        return path
      }
    }
    return nil
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
