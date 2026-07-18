import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct ProjectKeyTests {
  @Test func sameInputsProduceSameKey() {
    let a = ProjectKey(workspaceRoot: "/tmp/some/project", backendArgv: ["/usr/bin/backend", "serve"], environment: ["DEVELOPER_DIR": "/Applications/Xcode.app"])
    let b = ProjectKey(workspaceRoot: "/tmp/some/project", backendArgv: ["/usr/bin/backend", "serve"], environment: ["DEVELOPER_DIR": "/Applications/Xcode.app"])
    #expect(a == b)
    #expect(a.fullHash == b.fullHash)
  }

  @Test func differentWorkspaceRootProducesDifferentKey() {
    let a = ProjectKey(workspaceRoot: "/tmp/project-a", backendArgv: ["/usr/bin/backend"], environment: [:])
    let b = ProjectKey(workspaceRoot: "/tmp/project-b", backendArgv: ["/usr/bin/backend"], environment: [:])
    #expect(a != b)
  }

  @Test func differentBackendArgvProducesDifferentKey() {
    let a = ProjectKey(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend", "serve"], environment: [:])
    let b = ProjectKey(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend", "--flag"], environment: [:])
    #expect(a != b)
  }

  @Test func differentDeveloperDirProducesDifferentKey() {
    let a = ProjectKey(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: ["DEVELOPER_DIR": "/Applications/Xcode.app"])
    let b = ProjectKey(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: ["DEVELOPER_DIR": "/Applications/Xcode-beta.app"])
    #expect(a != b)
  }

  @Test func unrelatedEnvironmentVariablesDoNotAffectKey() {
    let a = ProjectKey(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: ["RANDOM_NOISE": "1"])
    let b = ProjectKey(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: ["RANDOM_NOISE": "2"])
    #expect(a == b)
  }

  @Test func symlinkedBackendExecutableProducesSameKeyAsItsRealPath() {
    let fs = InMemoryFileSystem(resolvedPaths: ["/usr/bin/backend-symlink": "/opt/toolchain/backend"])
    let a = ProjectKey(
      workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend-symlink", "serve"],
      environment: [:], fileSystem: fs
    )
    let b = ProjectKey(
      workspaceRoot: "/tmp/project", backendArgv: ["/opt/toolchain/backend", "serve"],
      environment: [:], fileSystem: fs
    )
    #expect(a == b)
  }

  @Test func symlinkedWorkspaceRootProducesSameKeyAsItsRealPath() {
    let fs = InMemoryFileSystem(resolvedPaths: ["/tmp/symlinked-project": "/tmp/real-project"])
    let a = ProjectKey(
      workspaceRoot: "/tmp/symlinked-project", backendArgv: ["/usr/bin/backend"],
      environment: [:], fileSystem: fs
    )
    let b = ProjectKey(
      workspaceRoot: "/tmp/real-project", backendArgv: ["/usr/bin/backend"],
      environment: [:], fileSystem: fs
    )
    #expect(a == b)
  }

  @Test func onlyArgvZeroIsResolvedRemainingArgsPassThroughVerbatim() {
    // If a non-executable arg were (incorrectly) run through the resolver, this would
    // produce a different key than the same argv against the real resolver.
    let fs = InMemoryFileSystem(resolvedPaths: ["--config": "/should/never/be/consulted"])
    let a = ProjectKey(
      workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend", "--config"],
      environment: [:], fileSystem: fs
    )
    let b = ProjectKey(
      workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend", "--config"],
      environment: [:], fileSystem: InMemoryFileSystem()
    )
    #expect(a == b)
  }

  @Test func shortHashIsPrefixOfFullHash() {
    let key = ProjectKey(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: [:])
    #expect(key.fullHash.count == 64)
    #expect(key.shortHash.count == 16)
    #expect(key.fullHash.hasPrefix(key.shortHash))
  }

  @Test func socketPathStaysWithinSockaddrUnBudgetForLongInputs() {
    let longRoot = "/tmp/" + String(repeating: "a-very-long-directory-name-segment/", count: 20) + "project"
    let longArgv = ["/usr/local/some/deeply/nested/toolchain/path/" + String(repeating: "b", count: 200) + "/backend", "serve", "--config", String(repeating: "c", count: 500)]
    let key = ProjectKey(workspaceRoot: longRoot, backendArgv: longArgv, environment: [:])
    let paths = ProjectPaths(key: key, baseDirectory: "/tmp/bsp-mux-501")

    // macOS sockaddr_un.sun_path is 104 bytes total, including the null terminator.
    #expect(paths.socketPath.utf8.count < 104)
    #expect(paths.lockPath.utf8.count < 104)
  }

  @Test func projectPathsDeriveExpectedFilenames() {
    let key = ProjectKey(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: [:])
    let paths = ProjectPaths(key: key, baseDirectory: "/tmp/bsp-mux-501")
    #expect(paths.socketPath == "/tmp/bsp-mux-501/\(key.shortHash).sock")
    #expect(paths.lockPath == "/tmp/bsp-mux-501/\(key.shortHash).lock")
    #expect(paths.metaPath == "/tmp/bsp-mux-501/\(key.shortHash).meta.json")
  }

  @Test func ensureBaseDirectoryExistsCreatesA0700Directory() throws {
    let base = "/tmp/bsp-mux-test-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: base) }

    let key = ProjectKey(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend"], environment: [:])
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

  @Test func metaRoundTripsThroughDisk() throws {
    let path = "/tmp/bsp-mux-test-meta-\(UUID().uuidString).json"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let key = ProjectKey(workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend", "serve"], environment: [:])
    let meta = ProjectKeyMeta(key: key, workspaceRoot: "/tmp/project", backendArgv: ["/usr/bin/backend", "serve"])
    try meta.write(to: path)

    let readBack = try ProjectKeyMeta.read(from: path)
    #expect(readBack == meta)
    #expect(readBack.fullHash == key.fullHash)
  }
}
