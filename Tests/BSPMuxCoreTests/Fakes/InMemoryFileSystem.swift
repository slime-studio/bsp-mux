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

  subscript(path: String) -> Data? {
    files[path]
  }
}
