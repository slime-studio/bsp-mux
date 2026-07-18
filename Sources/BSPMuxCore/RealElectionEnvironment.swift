import Foundation

#if canImport(Darwin)
import Darwin

// `connect`/`bind`/`listen` share a name with `ElectionEnvironment`'s own methods; qualify
// the libc calls explicitly rather than relying on overload resolution to sort it out.
private func cConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { Darwin.connect(fd, addr, len) }
private func cBind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { Darwin.bind(fd, addr, len) }
private func cListen(_ fd: Int32, _ backlog: Int32) -> Int32 { Darwin.listen(fd, backlog) }
#elseif canImport(Glibc)
import Glibc

private func cConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { Glibc.connect(fd, addr, len) }
private func cBind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { Glibc.bind(fd, addr, len) }
private func cListen(_ fd: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(fd, backlog) }
#endif

public struct RealElectionEnvironment: ElectionEnvironment {
  public init() {}

  public func connect(to socketPath: String) throws -> ConnectionHandle? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ElectionError.errno("socket", errno) }

    var addr = try RealElectionEnvironment.makeSockaddrUn(path: socketPath)
    let result = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        cConnect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if result == 0 {
      return ConnectionHandle(fileDescriptor: fd)
    }

    let connectErrno = errno
    close(fd)
    switch connectErrno {
    case ECONNREFUSED, ENOENT:
      // Nothing listening: either no socket file exists yet, or a stale one does. Both are a
      // legitimate "no daemon" answer, not an error.
      return nil
    default:
      throw ElectionError.errno("connect", connectErrno)
    }
  }

  public func acquireLockNonBlocking(atPath lockPath: String) throws -> LockHandle? {
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw ElectionError.errno("open", errno) }

    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
      return LockHandle(fileDescriptor: fd)
    }

    let flockErrno = errno
    close(fd)
    guard flockErrno == EWOULDBLOCK else {
      throw ElectionError.errno("flock", flockErrno)
    }
    return nil
  }

  public func listen(at socketPath: String) throws -> ListeningHandle {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ElectionError.errno("socket", errno) }

    var addr = try RealElectionEnvironment.makeSockaddrUn(path: socketPath)
    let bindResult = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        cBind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      let bindErrno = errno
      close(fd)
      throw ElectionError.errno("bind", bindErrno)
    }

    guard cListen(fd, SOMAXCONN) == 0 else {
      let listenErrno = errno
      close(fd)
      throw ElectionError.errno("listen", listenErrno)
    }

    return ListeningHandle(fileDescriptor: fd)
  }

  public func ignoreSIGPIPE() {
    signal(SIGPIPE, SIG_IGN)
  }

  public func detachSession() throws {
    guard setsid() == -1 else { return }
    // EPERM means this process is already a process-group leader (e.g. launched directly by
    // the shell rather than forked) — already effectively detached, not a real failure.
    guard errno != EPERM else { return }
    throw ElectionError.errno("setsid", errno)
  }

  private static func makeSockaddrUn(path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)

    let pathBytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count < capacity else {
      throw ElectionError(description: "socket path exceeds sockaddr_un budget (\(capacity) bytes): \(path)")
    }

    withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
      let buffer = rawBuffer.bindMemory(to: Int8.self)
      for (index, byte) in pathBytes.enumerated() {
        buffer[index] = Int8(bitPattern: byte)
      }
      buffer[pathBytes.count] = 0
    }

    #if canImport(Darwin)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif

    return addr
  }
}

extension ElectionError {
  static func errno(_ syscall: String, _ code: Int32) -> ElectionError {
    ElectionError(description: "\(syscall) failed: \(String(cString: strerror(code))) (errno \(code))")
  }
}
