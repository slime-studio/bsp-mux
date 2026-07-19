import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct ProjectKeyTests {
  /// `ProjectKey.init` reads `@Dependency(\.fileSystem)` unconditionally now, and swift-
  /// dependencies fails loudly (by design) if that's accessed in a test without an explicit
  /// override rather than silently falling back to the live value - so every construction
  /// needs a scope, even tests that don't care about symlink-resolution behavior specifically.
  static func key(
    workspaceRoot: String, backendArgv: [String], environment: [String: String] = [:],
    fileSystem: FileSystemProviding = InMemoryFileSystem()
  ) -> ProjectKey {
    withDependencies {
      $0.fileSystem = fileSystem
    } operation: {
      ProjectKey(workspaceRoot: workspaceRoot, backendArgv: backendArgv, environment: environment)
    }
  }

  @Test func sameInputsProduceSameKey() {
    let a = Self.key(workspaceRoot: "/tmp/some/project", backendArgv: ["/usr/bin/backend", "serve"], environment: ["DEVELOPER_DIR": "/Applications/Xcode.app"])
    let b = Self.key(workspaceRoot: "/tmp/some/project", backendArgv: ["/usr/bin/backend", "serve"], environment: ["DEVELOPER_DIR": "/Applications/Xcode.app"])
    #expect(a == b)
    #expect(a.fullHash == b.fullHash)
  }

  @Test func differentWorkspaceRootProducesDifferentKey() {
    let a = Self.key(workspaceRoot: "/tmp/project-a", backendArgv: ["/usr/bin/backend"])
    let b = Self.key(workspaceRoot: "/tmp/project-b", backendArgv: ["/usr/bin/backend"])
    #expect(a != b)
  }

  @Test func differentBackendArgvProducesDifferentKey() {
    let a = Self.key(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend", "serve"])
    let b = Self.key(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend", "--flag"])
    #expect(a != b)
  }

  @Test func differentDeveloperDirProducesDifferentKey() {
    let a = Self.key(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: ["DEVELOPER_DIR": "/Applications/Xcode.app"])
    let b = Self.key(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: ["DEVELOPER_DIR": "/Applications/Xcode-beta.app"])
    #expect(a != b)
  }

  @Test func unrelatedEnvironmentVariablesDoNotAffectKey() {
    let a = Self.key(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: ["RANDOM_NOISE": "1"])
    let b = Self.key(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: ["RANDOM_NOISE": "2"])
    #expect(a == b)
  }

  @Test func symlinkedBackendExecutableProducesSameKeyAsItsRealPath() {
    let fs = InMemoryFileSystem(resolvedPaths: ["/usr/bin/backend-symlink": "/opt/toolchain/backend"])
    let a = Self.key(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend-symlink", "serve"], fileSystem: fs)
    let b = Self.key(workspaceRoot: "/tmp/project", backendArgv: ["/opt/toolchain/backend", "serve"], fileSystem: fs)
    #expect(a == b)
  }

  @Test func symlinkedWorkspaceRootProducesSameKeyAsItsRealPath() {
    let fs = InMemoryFileSystem(resolvedPaths: ["/tmp/symlinked-project": "/tmp/real-project"])
    let a = Self.key(workspaceRoot: "/tmp/symlinked-project", backendArgv: ["/usr/bin/backend"], fileSystem: fs)
    let b = Self.key(workspaceRoot: "/tmp/real-project", backendArgv: ["/usr/bin/backend"], fileSystem: fs)
    #expect(a == b)
  }

  @Test func onlyArgvZeroIsResolvedRemainingArgsPassThroughVerbatim() {
    // If a non-executable arg were (incorrectly) run through the resolver, this would
    // produce a different key than the same argv against the real resolver.
    let a = Self.key(
      workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend", "--config"],
      fileSystem: InMemoryFileSystem(resolvedPaths: ["--config": "/should/never/be/consulted"])
    )
    let b = Self.key(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend", "--config"])
    #expect(a == b)
  }

  @Test func shortHashIsPrefixOfFullHash() {
    let key = Self.key(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"])
    #expect(key.fullHash.count == 64)
    #expect(key.shortHash.count == 16)
    #expect(key.fullHash.hasPrefix(key.shortHash))
  }

  @Test func socketPathStaysWithinSockaddrUnBudgetForLongInputs() {
    let longRoot = "/tmp/" + String(repeating: "a-very-long-directory-name-segment/", count: 20) + "project"
    let longArgv = ["/usr/local/some/deeply/nested/toolchain/path/" + String(repeating: "b", count: 200) + "/backend", "serve", "--config", String(repeating: "c", count: 500)]
    let key = Self.key(workspaceRoot: longRoot, backendArgv: longArgv)
    let paths = ProjectPaths(key: key, baseDirectory: "/tmp/bsp-mux-501")

    // macOS sockaddr_un.sun_path is 104 bytes total, including the null terminator.
    #expect(paths.socketPath.utf8.count < 104)
    #expect(paths.lockPath.utf8.count < 104)
  }

  @Test func projectPathsDeriveExpectedFilenames() {
    let key = Self.key(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"])
    let paths = ProjectPaths(key: key, baseDirectory: "/tmp/bsp-mux-501")
    #expect(paths.socketPath == "/tmp/bsp-mux-501/\(key.shortHash).sock")
    #expect(paths.lockPath == "/tmp/bsp-mux-501/\(key.shortHash).lock")
    #expect(paths.metaPath == "/tmp/bsp-mux-501/\(key.shortHash).meta.json")
  }

  @Test func ensureBaseDirectoryExistsCreatesA0700Directory() throws {
    let base = "/tmp/bsp-mux-test-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: base) }

    let key = Self.key(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"])
    let paths = ProjectPaths(key: key, baseDirectory: base)
    try paths.ensureBaseDirectoryExists()

    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: base, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)

    let attributes = try FileManager.default.attributesOfItem(atPath: base)
    let permissions = attributes[.posixPermissions] as? Int
    #expect(permissions == 0o700)

    // Idempotent: calling again on an already-correct directory shouldn't throw.
    try paths.ensureBaseDirectoryExists()
  }

  @Test func metaRoundTripsThroughRepository() throws {
    let key = Self.key(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend", "serve"])
    let meta = ProjectKeyMeta(key: key, workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend", "serve"])
    let path = "/tmp/bsp-mux-test/meta.json"

    try withDependencies {
      $0.fileSystem = InMemoryFileSystem()
    } operation: {
      let repository = ProjectKeyMetaRepository()
      try repository.save(meta, to: path)

      let readBack = try repository.load(from: path)
      #expect(readBack == meta)
      #expect(readBack.fullHash == key.fullHash)
    }
  }
}
