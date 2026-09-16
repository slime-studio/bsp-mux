import Foundation

/// Locates the sibling `bsp-mux`/`fake-bsp-backend` binaries this suite spawns as real
/// subprocesses. `CommandLine.arguments`/`Bundle.main`/`ProcessInfo` all resolve to the
/// toolchain's own `swiftpm-testing-helper` wrapper under `swift test`, not anything in
/// `.build/` - confirmed empirically before writing this, so this shells out to
/// `swift build --show-bin-path` instead, which reliably returns the real products directory.
enum BinaryLocator {
  static let bspMux = productsDirectory.appending(path: "bsp-mux")
  static let fakeBSPBackend = productsDirectory.appending(path: "fake-bsp-backend")
  static let rawBytesBSPBackend = productsDirectory.appending(path: "raw-bytes-bsp-backend")

  /// `#filePath` is this source file's own absolute path at compile time - walking up from
  /// `Tests/BSPMuxIntegrationTests/Support/BinaryLocator.swift` to the repo root is a fixed,
  /// known number of levels, reliable regardless of build configuration (unlike guessing the
  /// products path directly, which varies by architecture/debug-vs-release).
  private static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// Computed once per test run (a `static let` is lazily initialized exactly once), not once
  /// per test - confirmed this takes ~0.3s and doesn't deadlock when called from inside an
  /// already-running `swift test` invocation, but that's still not free to repeat per test.
  private static let productsDirectory: URL = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "build", "--show-bin-path"]
    process.currentDirectoryURL = repoRoot
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
      try process.run()
    } catch {
      fatalError("BinaryLocator: failed to run 'swift build --show-bin-path': \(error)")
    }
    process.waitUntilExit()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(data: output, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(fileURLWithPath: path)
  }()
}
