import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Bridges a raw file descriptor's read direction into `ByteSource`, backed by a non-blocking fd
/// and a `DispatchSourceRead` rather than `FileHandle.bytes`.
///
/// `FileHandle.bytes` was the original implementation, and it turned out to be a real hazard,
/// not just a style preference: confirmed both empirically (a stack sample of a hung real
/// process, caught while investigating an unrelated test's flakiness) and independently
/// documented (Andy Finnell, "Reading and writing files in Swift async/await",
/// https://losingfight.com/blog/2024/04/22/reading-and-writing-files-in-swift-asyncawait/ -
/// "I do not recommend using the `bytes` property to iterate one byte at a time") that its
/// iterator performs a genuinely *blocking* kernel `read()` syscall on whatever thread drives
/// it. Since that thread is one of Swift's small, fixed-size cooperative executor threads, not a
/// dedicated one, enough simultaneously-blocked `RealByteSource` instances (e.g. several
/// concurrent client sessions each waiting on their own peer) can exhaust the entire pool and
/// starve unrelated work process-wide - a real deadlock, not just a busy loop.
///
/// A `DispatchSourceRead` only invokes its handler once the fd is actually readable, and the
/// non-blocking `read()` inside that handler can't block even if the readiness signal turns out
/// to be stale (POSIX readiness is a hint, not a guarantee - `EAGAIN`/`EWOULDBLOCK` just means
/// wait for the next event). This also naturally coalesces: each event reads whatever's actually
/// available (up to `maxChunkSize`) in one call, so unlike the old byte-at-a-time design, there's
/// no separate fake-clock-driven flush heuristic needed here at all.
///
/// `read()` itself is an actor, not just `Sendable`: only one caller is expected to drive a
/// source's receive loop at a time, but a plain class with a "fresh iterator per call" body
/// wouldn't actually be safe under *concurrent* callers - each call's local `AsyncStream`
/// iterator races the others on the same underlying stream, and turning the type into a plain
/// `actor` alone wouldn't fix that either, since actor reentrancy still lets a second `read()`
/// start once the first suspends at its own `await`. The explicit turn-taking below (mirroring
/// `RealByteSink`'s write-side back-pressure) is what actually guarantees only one `read()` is in
/// flight at a time.
public actor RealByteSource: ByteSource {
  private let stream: AsyncStream<Data>
  private var isReading = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(fileDescriptor: Int32, maxChunkSize: Int = 64 * 1024) {
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    self.stream = stream
    Self.startReading(fileDescriptor: fileDescriptor, maxChunkSize: maxChunkSize, continuation: continuation)
  }

  public func read() async throws -> Data? {
    await acquireTurn()
    defer { releaseTurn() }
    for await data in stream {
      return data
    }
    return nil
  }

  private func acquireTurn() async {
    guard isReading else {
      isReading = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func releaseTurn() {
    guard !waiters.isEmpty else {
      isReading = false
      return
    }
    waiters.removeFirst().resume()
  }

  private static func startReading(fileDescriptor: Int32, maxChunkSize: Int, continuation: AsyncStream<Data>.Continuation) {
    setNonBlocking(fileDescriptor)

    let queue = DispatchQueue(label: "bsp-mux.byte-source")
    let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)

    source.setEventHandler {
      var chunk = [UInt8](repeating: 0, count: maxChunkSize)
      let bytesRead = chunk.withUnsafeMutableBytes { raw in
        cRead(fileDescriptor, raw.baseAddress, raw.count)
      }
      if bytesRead > 0 {
        continuation.yield(Data(chunk[0..<bytesRead]))
      } else if bytesRead == 0 {
        source.cancel()  // EOF
      } else if errno != EAGAIN && errno != EWOULDBLOCK {
        source.cancel()  // A real read error - end the stream the same as EOF would.
      }
      // EAGAIN/EWOULDBLOCK: the readiness signal was stale - just wait for the next event.
    }
    source.setCancelHandler {
      continuation.finish()
    }
    source.resume()
  }
}

/// Bridges a raw file descriptor's write direction into `ByteSink`, backed by a non-blocking fd
/// and a `DispatchSourceWrite`, giving every caller genuine back-pressure — suspending until its
/// turn rather than failing outright under contention. Unsynchronized concurrent writes to the
/// same fd aren't just a queueing nicety to get right: POSIX only guarantees a `write()` is
/// atomic (never interleaved with another writer) up to `PIPE_BUF` bytes, so anything larger
/// genuinely can arrive on the wire garbled without this.
///
/// Non-blocking for the same reason `RealByteSource`'s read side is (see its doc comment) - and
/// necessarily so, not just for symmetry: `RealDuplexByteStream` composes a `RealByteSource` and
/// a `RealByteSink` over the *same* file descriptor, and `O_NONBLOCK` is a property of the
/// underlying open file description, not scoped to one direction - confirmed empirically that
/// setting it via one of them makes writes on that same fd non-blocking too. A write handler that
/// still assumed blocking semantics would start seeing `EAGAIN`/partial writes under real
/// backpressure instead of correctly waiting, so this loops on write-readiness events, retrying
/// and tracking how much of the buffer has actually been sent, rather than a single blocking
/// `write()` call.
///
/// An actor, one per file descriptor - callers writing to unrelated file descriptors get their
/// own instance, so a slow write to one stream can never stall an unrelated one.
public actor RealByteSink: ByteSink {
  private let fileDescriptor: Int32
  private var isWriting = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(fileDescriptor: Int32) {
    self.fileDescriptor = fileDescriptor
    setNonBlocking(fileDescriptor)
  }

  public func write(_ data: Data) async throws {
    await acquireTurn()
    defer { releaseTurn() }
    try await Self.performWrite(data, to: fileDescriptor)
  }

  private func acquireTurn() async {
    guard isWriting else {
      isWriting = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func releaseTurn() {
    guard !waiters.isEmpty else {
      isWriting = false
      return
    }
    waiters.removeFirst().resume()
  }

  private static func performWrite(_ data: Data, to fileDescriptor: Int32) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let queue = DispatchQueue(label: "bsp-mux.byte-sink")
      let source = DispatchSource.makeWriteSource(fileDescriptor: fileDescriptor, queue: queue)
      var remaining = data

      // Only ever touched from source's own serial queue (setEventHandler/setCancelHandler are
      // both invoked there, never concurrently), so this needs no separate synchronization.
      nonisolated(unsafe) var writeError: Error?

      source.setEventHandler {
        let bytesWritten = remaining.withUnsafeBytes { raw in
          cWrite(fileDescriptor, raw.baseAddress, raw.count)
        }
        if bytesWritten > 0 {
          remaining.removeFirst(bytesWritten)
          if remaining.isEmpty {
            source.cancel()
          }
          // else: partial write - stay registered for the next writability event.
        } else if bytesWritten < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
          writeError = ByteStreamError.errno("write", errno)
          source.cancel()
        }
        // EAGAIN/EWOULDBLOCK: the readiness signal was stale - just wait for the next event.
      }
      source.setCancelHandler {
        if let error = writeError {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
      source.resume()
    }
  }
}

private func setNonBlocking(_ fileDescriptor: Int32) {
  let currentFlags = fcntl(fileDescriptor, F_GETFL, 0)
  _ = fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK)
}

// `read`/`write` share a name with this file's own APIs; qualify the libc calls explicitly
// rather than relying on overload resolution to sort it out (matching RealElectionEnvironment's
// existing convention for the same problem with connect/bind/listen).
#if canImport(Darwin)
private func cRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { Darwin.read(fd, buffer, count) }
private func cWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { Darwin.write(fd, buffer, count) }
#elseif canImport(Glibc)
private func cRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { Glibc.read(fd, buffer, count) }
private func cWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { Glibc.write(fd, buffer, count) }
#endif

struct ByteStreamError: Swift.Error, CustomStringConvertible, Equatable {
  let description: String
}

extension ByteStreamError {
  static func errno(_ syscall: String, _ code: Int32) -> ByteStreamError {
    ByteStreamError(description: "\(syscall) failed: \(String(cString: strerror(code))) (errno \(code))")
  }
}
