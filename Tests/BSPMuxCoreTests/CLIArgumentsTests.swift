import Testing

@testable import BSPMuxCore

@Suite struct CLIArgumentsTests {
  // MARK: - install

  @Test func installParsesWorkspaceRootWithoutForce() throws {
    let command = try CLIArguments.parse(["install", "--workspace-root", "/tmp/project"])
    #expect(command == .install(workspaceRoot: "/tmp/project", force: false))
  }

  @Test func installParsesForceRegardlessOfFlagOrder() throws {
    let beforeRoot = try CLIArguments.parse(["install", "--force", "--workspace-root", "/tmp/project"])
    let afterRoot = try CLIArguments.parse(["install", "--workspace-root", "/tmp/project", "--force"])
    #expect(beforeRoot == .install(workspaceRoot: "/tmp/project", force: true))
    #expect(afterRoot == .install(workspaceRoot: "/tmp/project", force: true))
  }

  @Test func installThrowsWhenWorkspaceRootIsMissingEntirely() {
    #expect(throws: (any Error).self) {
      _ = try CLIArguments.parse(["install"])
    }
  }

  @Test func installThrowsWhenWorkspaceRootHasNoValue() {
    #expect(throws: (any Error).self) {
      _ = try CLIArguments.parse(["install", "--workspace-root"])
    }
  }

  @Test func installThrowsOnAnUnrecognizedArgument() {
    #expect(throws: (any Error).self) {
      _ = try CLIArguments.parse(["install", "--workspace-root", "/tmp/project", "--nonsense"])
    }
  }

  @Test func installHelpRequestThrows() {
    // Confirmed empirically this is ArgumentParser's own internal ParserError.helpRequested
    // case under the hood, but that type isn't public - it can't be pattern-matched by name
    // outside the module, so this can only assert that *something* throws, not which case.
    // See CLIArguments.parse's doc comment for what this means for the eventual CLI entry point.
    #expect(throws: (any Error).self) {
      _ = try CLIArguments.parse(["install", "--help"])
    }
  }

  // MARK: - run

  @Test func runParsesWorkspaceRootAndBackendArgv() throws {
    let command = try CLIArguments.parse(["--workspace-root", "/tmp/project", "--", "sourcekit-xcode-bsp", "serve"])
    #expect(command == .run(workspaceRoot: "/tmp/project", backendArgv: ["sourcekit-xcode-bsp", "serve"]))
  }

  @Test func runParsesASingleElementBackendArgv() throws {
    let command = try CLIArguments.parse(["--workspace-root", "/tmp/project", "--", "backend"])
    #expect(command == .run(workspaceRoot: "/tmp/project", backendArgv: ["backend"]))
  }

  @Test func runPreservesFlagLikeTokensInBackendArgvVerbatim() throws {
    // Confirmed empirically that .postTerminator treats everything after -- as opaque strings,
    // never attempting to interpret them as this command's own flags.
    let command = try CLIArguments.parse(["--workspace-root", "/tmp/project", "--", "--not-a-real-flag", "serve"])
    #expect(command == .run(workspaceRoot: "/tmp/project", backendArgv: ["--not-a-real-flag", "serve"]))
  }

  @Test func runThrowsWhenWorkspaceRootHasNoValue() {
    #expect(throws: (any Error).self) {
      _ = try CLIArguments.parse(["--workspace-root"])
    }
  }

  @Test func runThrowsWhenSeparatorIsMissing() {
    #expect(throws: (any Error).self) {
      _ = try CLIArguments.parse(["--workspace-root", "/tmp/project", "backend"])
    }
  }

  @Test func runThrowsWhenBackendArgvAfterSeparatorIsEmpty() {
    #expect(throws: (any Error).self) {
      _ = try CLIArguments.parse(["--workspace-root", "/tmp/project", "--"])
    }
  }

  @Test func runThrowsForCompletelyEmptyArgv() {
    #expect(throws: (any Error).self) {
      _ = try CLIArguments.parse([])
    }
  }

  @Test func runHelpRequestThrows() {
    #expect(throws: (any Error).self) {
      _ = try CLIArguments.parse(["--help"])
    }
  }
}
