import Foundation

@testable import BSPMuxCore

/// Maps specific paths to their "resolved" form; anything not explicitly registered resolves
/// to itself. Lets tests exercise symlink-style resolution deterministically, without
/// depending on what happens to exist on the machine running the tests.
struct FakePathResolver: PathResolving {
  private let resolved: [String: String]

  init(_ resolved: [String: String] = [:]) {
    self.resolved = resolved
  }

  func resolvePath(_ path: String) -> String {
    resolved[path] ?? path
  }
}
