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
    #expect(throws: CLIArgumentsError.self) {
      _ = try CLIArguments.parse(["install"])
    }
  }

  @Test func installThrowsWhenWorkspaceRootHasNoValue() {
    #expect(throws: CLIArgumentsError.self) {
      _ = try CLIArguments.parse(["install", "--workspace-root"])
    }
  }

  @Test func installThrowsOnAnUnrecognizedArgument() {
    #expect(throws: CLIArgumentsError.self) {
      _ = try CLIArguments.parse(["install", "--workspace-root", "/tmp/project", "--nonsense"])
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

  @Test func runThrowsWhenNotStartingWithWorkspaceRoot() {
    #expect(throws: CLIArgumentsError.self) {
      _ = try CLIArguments.parse(["--", "backend"])
    }
  }

  @Test func runThrowsWhenWorkspaceRootHasNoValue() {
    #expect(throws: CLIArgumentsError.self) {
      _ = try CLIArguments.parse(["--workspace-root"])
    }
  }

  @Test func runThrowsWhenSeparatorIsMissing() {
    #expect(throws: CLIArgumentsError.self) {
      _ = try CLIArguments.parse(["--workspace-root", "/tmp/project", "backend"])
    }
  }

  @Test func runThrowsWhenSomethingSitsBetweenWorkspaceRootAndSeparator() {
    // Deliberately strict, not a lenient "find -- anywhere" search - Installer.wrapArgv only
    // ever constructs the exact shape (--workspace-root, value, --, ...), so anything else
    // should fail loudly rather than silently drop the extra token.
    #expect(throws: CLIArgumentsError.self) {
      _ = try CLIArguments.parse(["--workspace-root", "/tmp/project", "--extra", "--", "backend"])
    }
  }

  @Test func runThrowsWhenBackendArgvAfterSeparatorIsEmpty() {
    #expect(throws: CLIArgumentsError.self) {
      _ = try CLIArguments.parse(["--workspace-root", "/tmp/project", "--"])
    }
  }

  @Test func runThrowsForCompletelyEmptyArgv() {
    #expect(throws: CLIArgumentsError.self) {
      _ = try CLIArguments.parse([])
    }
  }
}
