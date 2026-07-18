import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Narrow seam so `ProjectKey`/`Installer` can be tested against a fake resolver instead of
/// real `realpath(3)` calls, which depend on what happens to exist on the machine running
/// the tests (symlinks, PATH-relative executables).
public protocol PathResolving: Sendable {
  func resolvePath(_ path: String) -> String
}

public struct RealPathResolver: PathResolving {
  public init() {}

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
