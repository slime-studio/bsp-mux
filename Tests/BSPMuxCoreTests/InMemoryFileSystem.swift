import Foundation

@testable import BSPMuxCore

final class InMemoryFileSystem: FileSystemProviding, @unchecked Sendable {
  private var files: [String: Data] = [:]

  init(_ initialFiles: [String: Data] = [:]) {
    self.files = initialFiles
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

  subscript(path: String) -> Data? {
    files[path]
  }
}
