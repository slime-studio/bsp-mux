import ArgumentParser

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

/// Parses `bsp-mux`'s own argv into a `CLICommand`, via `ArgumentParser`.
///
/// `RunArguments` is `defaultSubcommand` on the root rather than declaring its own arguments
/// directly on the root command alongside `subcommands:` (an earlier version of this file tried
/// that) - confirmed empirically that combining a root command's own arguments with a declared
/// subcommand causes real parsing bugs: the subcommand failed to dispatch at all once the root
/// also declared a `.postTerminator` argument, and even without that, a shared option name
/// between root and subcommand bound its value incorrectly. `defaultSubcommand` is
/// `ArgumentParser`'s own documented mechanism for exactly this "no keyword, fall through to
/// this command's own arguments" shape, and confirmed empirically it dispatches correctly even
/// with zero subcommand keyword present in argv at all - it's the version actually used here.
public enum CLIArguments {
  public static func parse(_ argv: [String]) throws -> CLICommand {
    let parsed = try RootArguments.parseAsRoot(argv)
    switch parsed {
    case let install as InstallArguments:
      return .install(workspaceRoot: install.workspaceRoot, force: install.force)
    case let run as RunArguments:
      return .run(workspaceRoot: run.workspaceRoot, backendArgv: run.backendArgv)
    default:
      // Neither of ours - some other built-in ArgumentParser behavior took over instead (a
      // --help/-h request, most likely, but not provably only that - ArgumentParser also
      // auto-adds e.g. shell-completion-script generation). Confirmed empirically that
      // CleanExit.helpRequest(_:) is a genuinely public, nameable type constructible from just
      // the parsed value, unlike the internal error types ArgumentParser itself throws for this
      // case - giving whoever wires up the real CLI entry point something concrete to catch and
      // exit(0) on, rather than a completely opaque failure. Rendering the actual help text
      // nicely is a separate concern, left for that entry point to solve.
      throw CleanExit.helpRequest(parsed)
    }
  }
}

struct RootArguments: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bsp-mux",
    subcommands: [InstallArguments.self, RunArguments.self],
    defaultSubcommand: RunArguments.self
  )
}

struct InstallArguments: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "install")

  @Option(name: .customLong("workspace-root"), help: "Absolute path to the directory containing buildServer.json.")
  var workspaceRoot: String

  @Flag(name: .customLong("force"), help: "Re-wrap an already-wrapped buildServer.json instead of leaving it untouched.")
  var force = false
}

struct RunArguments: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "run")

  @Option(name: .customLong("workspace-root"), help: "Absolute path to the project's workspace root.")
  var workspaceRoot: String

  @Argument(parsing: .postTerminator, help: "The real backend's own argv, after --.")
  var backendArgv: [String] = []

  func validate() throws {
    guard !backendArgv.isEmpty else {
      throw ValidationError("backend argv (after --) must not be empty")
    }
  }
}
