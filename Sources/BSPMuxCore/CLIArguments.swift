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
/// Deliberately two fully independent `ParsableCommand`s with a manual "is it `install`?" check
/// up front, rather than `ArgumentParser`'s own `subcommands:` mechanism - confirmed empirically
/// that combining a root command's own arguments (needed for the bare, keyword-less "run" mode)
/// with a declared subcommand causes real parsing bugs: the subcommand failed to dispatch at all
/// once the root also declared a `.postTerminator` argument, and even without that, a shared
/// option name between root and subcommand bound its value incorrectly. Two independent
/// `ParsableCommand`s, each parsed directly via their own `.parse(_:)`, sidesteps both.
///
/// Errors propagate directly from `ArgumentParser` rather than being wrapped in a project-owned
/// error type, to avoid discarding whatever information is actually there. Worth noting for
/// whoever wires up the real CLI entry point later: a `--help`/`-h` request throws too (there's
/// no successful, distinguishable "help was requested" return value from `.parse(_:)` the way
/// there is from `.main()`), and confirmed empirically it's ArgumentParser's own internal
/// `ParserError.helpRequested` case doing the throwing - not `public`, so it can't be pattern-
/// matched by name outside the module. Presenting `--help` nicely (rather than as a generic
/// parse failure) will need either catching this some other way or using a different entry
/// point than `.parse(_:)` for that specific concern - left to the CLI entry point itself,
/// since it doesn't affect `CLICommand`'s success path at all.
public enum CLIArguments {
  public static func parse(_ argv: [String]) throws -> CLICommand {
    if argv.first == "install" {
      let install = try InstallArguments.parse(Array(argv.dropFirst()))
      return .install(workspaceRoot: install.workspaceRoot, force: install.force)
    }
    let run = try RunArguments.parse(argv)
    return .run(workspaceRoot: run.workspaceRoot, backendArgv: run.backendArgv)
  }
}

struct InstallArguments: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "install")

  @Option(name: .customLong("workspace-root"), help: "Absolute path to the directory containing buildServer.json.")
  var workspaceRoot: String

  @Flag(name: .customLong("force"), help: "Re-wrap an already-wrapped buildServer.json instead of leaving it untouched.")
  var force = false
}

struct RunArguments: ParsableCommand {
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
