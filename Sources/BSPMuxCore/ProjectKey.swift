import Crypto
import Dependencies
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Identifies a single (workspace, backend, toolchain) combination that should share one
/// daemon + backend process. Two processes that compute the same `ProjectKey` are safe to
/// share a backend; two that compute different keys must not.
public struct ProjectKey: Sendable, Equatable {
  /// Full SHA256 digest, hex-encoded (64 chars). Stored in the sidecar meta file so a
  /// connecting client can detect a truncated-hash collision instead of silently trusting it.
  public let fullHash: String

  /// First 16 hex chars of `fullHash`, used to build filesystem paths short enough to fit
  /// in a `sockaddr_un` (~104 bytes total on Darwin).
  public let shortHash: String

  /// Environment variables that actually affect which toolchain/compiler builds the
  /// project. Intentionally NOT the full environment — hashing everything would cause
  /// spurious extra daemons from irrelevant env noise (defeating the point of deduping).
  public static let environmentAllowlist: [String] = ["DEVELOPER_DIR", "TOOLCHAINS"]

  /// - Parameters:
  ///   - workspaceRoot: Absolute path to the project root (baked into `buildServer.json` by
  ///     `Installer`, not derived from cwd — see `Installer` for why).
  ///   - backendArgv: The wrapped backend's argv (the portion after `--`), unresolved.
  ///   - environment: Injectable for testing; defaults to the real process environment.
  ///
  /// `realpath(3)` resolution comes from `@Dependency(\.fileSystem)`; override it in tests via
  /// `withDependencies`.
  public init(
    workspaceRoot: String,
    backendArgv: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    @Dependency(\.fileSystem) var fileSystem
    var hasher = SHA256()

    func feed(_ string: String) {
      hasher.update(data: Data((string + "\u{0}").utf8))
    }

    feed(fileSystem.resolvePath(workspaceRoot))
    for arg in ProjectKey.resolveArgv(backendArgv, using: fileSystem) {
      feed(arg)
    }
    for key in ProjectKey.environmentAllowlist.sorted() {
      feed("\(key)=\(environment[key] ?? "")")
    }

    let digest = hasher.finalize()
    self.fullHash = digest.map { String(format: "%02x", $0) }.joined()
    self.shortHash = String(fullHash.prefix(16))
  }

  /// Resolves argv[0] (the backend executable) to a real path so e.g. a symlinked or
  /// PATH-relative backend doesn't produce a different key than an equivalent absolute one.
  /// Remaining args are passed through unresolved — they may not be paths at all.
  static func resolveArgv(_ argv: [String], using fileSystem: FileSystemProviding) -> [String] {
    guard let executable = argv.first else { return argv }
    var resolved = argv
    resolved[0] = fileSystem.resolvePath(executable)
    return resolved
  }
}

/// Filesystem locations derived from a `ProjectKey`: where the daemon listens, where
/// election is arbitrated, and where the full key is recorded for collision detection.
public struct ProjectPaths: Sendable {
  public let baseDirectory: String
  public let socketPath: String
  public let lockPath: String
  public let metaPath: String

  /// - Parameter baseDirectory: Overridable for testing; defaults to a short, fixed,
  ///   per-user path directly under `/tmp`. Deliberately not under `$TMPDIR` — on Darwin
  ///   that's a long per-session path (`/var/folders/.../T/`) that would consume most of
  ///   the `sockaddr_un` budget on its own. The per-uid segment avoids path/permission
  ///   collisions between users on a shared multi-user machine.
  public init(key: ProjectKey, baseDirectory: String = "/tmp/bsp-mux-\(getuid())") {
    self.baseDirectory = baseDirectory
    self.socketPath = "\(baseDirectory)/\(key.shortHash).sock"
    self.lockPath = "\(baseDirectory)/\(key.shortHash).lock"
    self.metaPath = "\(baseDirectory)/\(key.shortHash).meta.json"
  }

  /// Creates `baseDirectory` with `0700` permissions if it doesn't already exist.
  /// Idempotent; safe to call from every racing process.
  public func ensureBaseDirectoryExists() throws {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    if fm.fileExists(atPath: baseDirectory, isDirectory: &isDirectory) {
      if !isDirectory.boolValue {
        throw ProjectPathsError.baseDirectoryIsNotADirectory(baseDirectory)
      }
      return
    }
    try fm.createDirectory(
      atPath: baseDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }
}

public enum ProjectPathsError: Error, CustomStringConvertible {
  case baseDirectoryIsNotADirectory(String)

  public var description: String {
    switch self {
    case .baseDirectoryIsNotADirectory(let path):
      return "\(path) exists but is not a directory"
    }
  }
}

/// Recorded alongside the socket so a connecting client can verify it's talking to the
/// daemon for *its* project key, not one that happens to collide on the truncated
/// `shortHash` (astronomically unlikely at 64 bits, but cheap to check).
public struct ProjectKeyMeta: Codable, Sendable, Equatable {
  public let fullHash: String
  public let workspaceRoot: String
  public let backendArgv: [String]

  public init(key: ProjectKey, workspaceRoot: String, backendArgv: [String]) {
    self.fullHash = key.fullHash
    self.workspaceRoot = workspaceRoot
    self.backendArgv = backendArgv
  }

  public func write(to path: String) throws {
    let data = try JSONEncoder().encode(self)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }

  public static func read(from path: String) throws -> ProjectKeyMeta {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(ProjectKeyMeta.self, from: data)
  }
}
