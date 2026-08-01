import Foundation

#if canImport(Darwin)
import Darwin

private func cAccept(_ fd: Int32) -> Int32 { Darwin.accept(fd, nil, nil) }
#elseif canImport(Glibc)
import Glibc

private func cAccept(_ fd: Int32) -> Int32 { Glibc.accept(fd, nil, nil) }
#endif

/// Real POSIX `accept(2)`. Each call is dispatched to a background queue and bridged back via a
/// continuation, since `accept` blocks until a client connects and has no async variant.
/// Deliberately doesn't support cancelling an in-flight accept: the daemon's accept loop runs
/// for the process's entire life, and at shutdown the process simply exits - there's no mid-life
/// scenario where an abandoned blocking `accept()` needs to be cleanly interrupted, unlike
/// `RealByteSource`'s reads (which `Relay` genuinely needs to cross-cancel mid-connection).
public struct RealSocketAccepting: SocketAccepting {
  public init() {}

  public func accept(on listening: ListeningHandle) async throws -> ConnectionHandle {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let fd = cAccept(listening.fileDescriptor)
        guard fd >= 0 else {
          continuation.resume(throwing: SocketAcceptError.errno("accept", errno))
          return
        }
        continuation.resume(returning: ConnectionHandle(fileDescriptor: fd))
      }
    }
  }
}

extension SocketAcceptError {
  static func errno(_ syscall: String, _ code: Int32) -> SocketAcceptError {
    SocketAcceptError(description: "\(syscall) failed: \(String(cString: strerror(code))) (errno \(code))")
  }
}
