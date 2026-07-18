import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct InstallerTests {
  static let workspaceRoot = "/test-workspace-xyz/project"
  static let multiplexerExecutable = "/test-workspace-xyz/bin/bsp-mux"
  static let buildServerJSONPath = "\(workspaceRoot)/buildServer.json"

  // An identity FakePathResolver rather than the real one: keeps these tests deterministic
  // regardless of what happens to exist on the machine running the tests, and independent
  // of Installer.install(...)'s specific realpath(3) fallback behavior.
  static func makeInstaller(fileSystem: InMemoryFileSystem, pathResolver: PathResolving = FakePathResolver()) -> Installer {
    Installer(fileSystem: fileSystem, pathResolver: pathResolver)
  }

  static func sampleOriginalJSON(argv: [String] = ["/usr/local/bin/sourcekit-xcode-bsp", "serve"]) -> [String: Any] {
    [
      "name": "sourcekit-xcode-bsp",
      "version": "0.1.0",
      "bspVersion": "2.1.0",
      "languages": ["swift"],
      "workspace": "MyApp.xcodeproj",
      "argv": argv,
    ]
  }

  static func writeSample(to fileSystem: InMemoryFileSystem, argv: [String] = ["/usr/local/bin/sourcekit-xcode-bsp", "serve"]) throws {
    let data = try JSONSerialization.data(withJSONObject: sampleOriginalJSON(argv: argv))
    try fileSystem.write(data, toPath: buildServerJSONPath)
  }

  static func readJSON(_ fileSystem: InMemoryFileSystem) throws -> [String: Any] {
    let data = try #require(fileSystem[buildServerJSONPath])
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func installWrapsExistingArgvAndPreservesOtherFields() throws {
    let fs = InMemoryFileSystem()
    try Self.writeSample(to: fs)
    let installer = Self.makeInstaller(fileSystem: fs)

    let result = try installer.install(workspaceRoot: Self.workspaceRoot, multiplexerExecutable: Self.multiplexerExecutable)
    #expect(result.changed)

    let json = try Self.readJSON(fs)
    let argv = try #require(json["argv"] as? [String])

    #expect(argv == [
      Self.multiplexerExecutable, "--workspace-root", Self.workspaceRoot, "--",
      "/usr/local/bin/sourcekit-xcode-bsp", "serve",
    ])
    #expect(result.wrappedArgv == argv)

    // Untouched fields.
    #expect(json["name"] as? String == "sourcekit-xcode-bsp")
    #expect(json["version"] as? String == "0.1.0")
    #expect(json["bspVersion"] as? String == "2.1.0")
    #expect(json["languages"] as? [String] == ["swift"])
    #expect(json["workspace"] as? String == "MyApp.xcodeproj")
  }

  @Test func installIsIdempotentWithoutForce() throws {
    let fs = InMemoryFileSystem()
    try Self.writeSample(to: fs)
    let installer = Self.makeInstaller(fileSystem: fs)

    let first = try installer.install(workspaceRoot: Self.workspaceRoot, multiplexerExecutable: Self.multiplexerExecutable)
    #expect(first.changed)

    let second = try installer.install(workspaceRoot: Self.workspaceRoot, multiplexerExecutable: Self.multiplexerExecutable)
    #expect(!second.changed)
    #expect(second.wrappedArgv == first.wrappedArgv)
  }

  @Test func installWithForceUnwrapsBeforeRewrappingInsteadOfNesting() throws {
    let fs = InMemoryFileSystem()
    try Self.writeSample(to: fs)
    let installer = Self.makeInstaller(fileSystem: fs)

    let first = try installer.install(workspaceRoot: Self.workspaceRoot, multiplexerExecutable: Self.multiplexerExecutable)
    let second = try installer.install(workspaceRoot: Self.workspaceRoot, multiplexerExecutable: Self.multiplexerExecutable, force: true)

    #expect(second.changed)
    #expect(second.wrappedArgv == first.wrappedArgv)
    // Not nested: our own path should appear exactly once.
    let occurrences = second.wrappedArgv.filter { $0 == Self.multiplexerExecutable }.count
    #expect(occurrences == 1)
  }

  @Test func installDetectsAlreadyWrappedThroughSymlinkedMultiplexerPath() throws {
    // argv[0] is a symlink pointing at the real multiplexer path; only a path resolver
    // (not string equality) can tell these name the same binary.
    let symlinkedMultiplexerPath = "/usr/local/bin/bsp-mux-symlink"
    let resolver = FakePathResolver([symlinkedMultiplexerPath: Self.multiplexerExecutable])

    let fs = InMemoryFileSystem()
    try Self.writeSample(
      to: fs,
      argv: [symlinkedMultiplexerPath, "--workspace-root", Self.workspaceRoot, "--", "/usr/local/bin/sourcekit-xcode-bsp", "serve"]
    )
    let installer = Self.makeInstaller(fileSystem: fs, pathResolver: resolver)

    let result = try installer.install(workspaceRoot: Self.workspaceRoot, multiplexerExecutable: Self.multiplexerExecutable)
    #expect(!result.changed)
  }

  @Test func installThrowsWhenBuildServerJSONMissing() {
    let fs = InMemoryFileSystem()
    let installer = Self.makeInstaller(fileSystem: fs)
    #expect(throws: Installer.Error.self) {
      try installer.install(workspaceRoot: Self.workspaceRoot, multiplexerExecutable: Self.multiplexerExecutable)
    }
  }

  @Test func installThrowsWhenArgvMissing() throws {
    let fs = InMemoryFileSystem()
    var json = Self.sampleOriginalJSON()
    json.removeValue(forKey: "argv")
    try fs.write(try JSONSerialization.data(withJSONObject: json), toPath: Self.buildServerJSONPath)
    let installer = Self.makeInstaller(fileSystem: fs)

    #expect(throws: Installer.Error.self) {
      try installer.install(workspaceRoot: Self.workspaceRoot, multiplexerExecutable: Self.multiplexerExecutable)
    }
  }

  @Test func installThrowsWhenArgvEmpty() throws {
    let fs = InMemoryFileSystem()
    try Self.writeSample(to: fs, argv: [])
    let installer = Self.makeInstaller(fileSystem: fs)

    #expect(throws: Installer.Error.self) {
      try installer.install(workspaceRoot: Self.workspaceRoot, multiplexerExecutable: Self.multiplexerExecutable)
    }
  }

  @Test func backendArgvUnwrapsPastSeparator() {
    let wrapped = ["/path/to/bsp-mux", "--workspace-root", "/root", "--", "backend", "serve", "--flag"]
    #expect(Installer.backendArgv(unwrapping: wrapped) == ["backend", "serve", "--flag"])
  }
}
