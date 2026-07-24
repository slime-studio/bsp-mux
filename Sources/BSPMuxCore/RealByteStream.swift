import Foundation

/// Bridges a raw file descriptor's read direction into `ByteSource`, backed by
/// `FileHandle.bytes` (Foundation's own async, cancellation-aware file I/O — confirmed
/// empirically that a blocked `next()` throws `CancellationError` promptly rather than hanging
/// when its task is cancelled, exactly what `Relay`'s cross-cancellation needs). A background
/// task continuously drains it into an `AsyncStream`; `read()` reuses the same "fresh iterator
/// per call over a shared stream" pattern already proven in `FakeByteStream`, so it never has to
/// hold mutating async iterator state across a suspension point.
public final class RealByteSource: ByteSource, Sendable {
  private let stream: AsyncStream<Data>

  public init(fileDescriptor: Int32) {
    let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    self.stream = stream
    Task {
      do {
        for try await byte in handle.bytes {
          continuation.yield(Data([byte]))
        }
      } catch {
        // A read error ends the stream the same as EOF would; Relay surfaces the failure
        // through whichever direction actually threw, not by propagating it out of here.
      }
      continuation.finish()
    }
  }

  public func read() async throws -> Data? {
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
  }
}

/// Bridges a raw file descriptor's write direction into `ByteSink`. `FileHandle.write` has no
/// async variant, so each write is dispatched to a background queue and bridged back via a
/// continuation rather than blocking the calling task's cooperative thread for however long the
/// write takes.
public final class RealByteSink: ByteSink, Sendable {
  private let handle: FileHandle
  private let queue = DispatchQueue(label: "bsp-mux.byte-sink")

  public init(fileDescriptor: Int32) {
    self.handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
  }

  public func write(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          try self.handle.write(contentsOf: data)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
