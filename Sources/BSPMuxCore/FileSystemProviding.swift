import Foundation

/// Narrow filesystem seam so `Installer` can be tested against an in-memory fake instead of
/// real disk I/O.
public protocol FileSystemProviding: Sendable {
  func fileExists(atPath path: String) -> Bool
  func contents(atPath path: String) throws -> Data
  func write(_ data: Data, toPath path: String) throws
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
}
