import Dependencies
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Narrow filesystem seam so `Installer`/`ProjectKey`/`Election` can be tested against an
/// in-memory fake instead of real disk I/O.
public protocol FileSystemProviding: Sendable {
  func fileExists(atPath path: String) -> Bool
  func contents(atPath path: String) throws -> Data
  func write(_ data: Data, toPath path: String) throws
  func remove(atPath path: String)
  func resolvePath(_ path: String) -> String
}

public struct RealFileSystem: FileSystemProviding {
  public init() {}

  public func fileExists(atPath path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  public func contents(atPath path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
  }

  public func write(_ data: Data, toPath path: String) throws {
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }

  public func remove(atPath path: String) {
    _ = unlink(path)
  }

  public func resolvePath(_ path: String) -> String {
    if let cResolved = realpath(path, nil) {
      defer { free(cResolved) }
      return String(cString: cResolved)
    }
    // realpath(3) fails if the path doesn't exist yet (e.g. a backend found via PATH
    // lookup rather than an absolute path). Fall back to lexical standardization rather
    // than failing key derivation outright.
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }
}

extension DependencyValues {
  public var fileSystem: any FileSystemProviding {
    get { self[FileSystemProvidingKey.self] }
    set { self[FileSystemProvidingKey.self] = newValue }
  }

  private enum FileSystemProvidingKey: DependencyKey {
    static let liveValue: any FileSystemProviding = RealFileSystem()
  }
}
