/// What `bsp-mux` was invoked to do, parsed from its own argv (excluding `argv[0]`, the
/// executable path itself - callers already have that separately and it isn't meaningful to
/// parsing logic).
public enum CLICommand: Sendable, Equatable {
  /// `bsp-mux install --workspace-root <path> [--force]` - the one-time `Installer` step.
  case install(workspaceRoot: String, force: Bool)
  /// `bsp-mux --workspace-root <path> -- <backend argv...>` - the wrapped invocation
  /// `Installer` itself writes into `buildServer.json`, and what `sourcekit-lsp` actually
  /// launches from then on: either become the daemon or relay to one, for this workspace root
  /// and backend.
  case run(workspaceRoot: String, backendArgv: [String])
}

public struct CLIArgumentsError: Swift.Error, CustomStringConvertible, Equatable {
  public let description: String

  public init(description: String) {
    self.description = description
  }
}

/// Parses `bsp-mux`'s own argv into a `CLICommand`. Deliberately pure string processing, no
/// filesystem access - `--workspace-root`'s value is handed back as-is, with resolution (e.g.
/// `realpath(3)`) staying where it already happens deeper in the stack (`ProjectKey`, via the
/// injectable `fileSystem` seam), not duplicated here.
public enum CLIArguments {
  public static func parse(_ argv: [String]) throws -> CLICommand {
    if argv.first == "install" {
      return try parseInstall(Array(argv.dropFirst()))
    }
    return try parseRun(argv)
  }

  private static func parseInstall(_ argv: [String]) throws -> CLICommand {
    var workspaceRoot: String?
    var force = false
    var index = argv.startIndex

    while index < argv.endIndex {
      switch argv[index] {
      case "--workspace-root":
        index = argv.index(after: index)
        guard index < argv.endIndex else {
          throw CLIArgumentsError(description: "--workspace-root requires a value")
        }
        workspaceRoot = argv[index]
      case "--force":
        force = true
      case let unexpected:
        throw CLIArgumentsError(description: "unrecognized argument to install: \(unexpected)")
      }
      index = argv.index(after: index)
    }

    guard let workspaceRoot else {
      throw CLIArgumentsError(description: "install requires --workspace-root <path>")
    }
    return .install(workspaceRoot: workspaceRoot, force: force)
  }

  private static func parseRun(_ argv: [String]) throws -> CLICommand {
    // Deliberately strict about the exact shape (--workspace-root, value, --, backend argv...)
    // rather than searching for -- anywhere in argv: this is the one shape Installer.wrapArgv
    // ever constructs, so anything else is a malformed invocation worth failing loudly on
    // rather than silently tolerating.
    guard argv.first == "--workspace-root" else {
      throw CLIArgumentsError(description: "expected --workspace-root <path> -- <backend argv...>")
    }
    guard argv.count > 1 else {
      throw CLIArgumentsError(description: "--workspace-root requires a value")
    }
    let workspaceRoot = argv[1]

    guard argv.count > 2, argv[2] == "--" else {
      throw CLIArgumentsError(description: "expected a -- separator after --workspace-root <path>")
    }
    let backendArgv = Array(argv[3...])
    guard !backendArgv.isEmpty else {
      throw CLIArgumentsError(description: "backend argv (after --) must not be empty")
    }

    return .run(workspaceRoot: workspaceRoot, backendArgv: backendArgv)
  }
}
