import Foundation

@testable import BSPMuxCore

final class InMemoryFileSystem: FileSystemProviding, @unchecked Sendable {
  private var files: [String: Data] = [:]
  private let resolvedPaths: [String: String]
  private(set) var removedPaths: [String] = []

  init(_ initialFiles: [String: Data] = [:], resolvedPaths: [String: String] = [:]) {
    self.files = initialFiles
    self.resolvedPaths = resolvedPaths
  }

  func fileExists(atPath path: String) -> Bool {
    files[path] != nil
  }

  func contents(atPath path: String) throws -> Data {
    guard let data = files[path] else {
      throw CocoaError(.fileNoSuchFile)
    }
    return data
  }

  func write(_ data: Data, toPath path: String) throws {
    files[path] = data
  }

  func remove(atPath path: String) {
    files.removeValue(forKey: path)
    removedPaths.append(path)
  }

  /// Maps specific paths to their "resolved" form; anything not explicitly registered
  /// resolves to itself. Lets tests exercise symlink-style resolution deterministically.
  func resolvePath(_ path: String) -> String {
    resolvedPaths[path] ?? path
  }

  /// Derives directory listings from `files`' keys rather than tracking directories
  /// separately — fine since tests only ever write full file paths, never empty dirs.
  func contentsOfDirectory(atPath path: String) -> [String] {
    let prefix = path.hasSuffix("/") ? path : path + "/"
    return files.keys.compactMap { key in
      guard key.hasPrefix(prefix) else { return nil }
      let remainder = key.dropFirst(prefix.count)
      guard !remainder.isEmpty, !remainder.contains("/") else { return nil }
      return String(remainder)
    }
  }

  subscript(path: String) -> Data? {
    files[path]
  }
}
