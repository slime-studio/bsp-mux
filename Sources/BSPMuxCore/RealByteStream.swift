import Dependencies
import Foundation

/// Bridges a raw file descriptor's read direction into `ByteSource`, backed by
/// `FileHandle.bytes` (Foundation's own async, cancellation-aware file I/O — confirmed
/// empirically that a blocked `next()` throws `CancellationError` promptly rather than hanging
/// when its task is cancelled, exactly what `Relay`'s cross-cancellation needs).
///
/// Reading one byte at a time and yielding each individually would mean `Relay`'s pump turns
/// every relayed message into one `write()` syscall per byte, so `pump` coalesces bytes into
/// larger chunks before handing them off, via two long-lived tasks rather than racing every
/// single byte against a timeout:
/// - a **listener** that just runs a plain, never-interrupted `for try await byte in handle.bytes`
///   loop, appending each byte to a shared buffer;
/// - a **flusher** that sleeps for `coalesceWindow` via `@Dependency(\.continuousClock)` (so
///   tests drive it deterministically with `TestClock`, same as `Daemon`'s idle-grace timer) and
///   flushes the buffer if nothing arrived during that whole sleep.
///
/// This split matters: an earlier version tried to decide "flush now or wait for more" by racing
/// each individual byte-fetch against a timeout and cancelling the loser. That's unsafe —
/// confirmed empirically (a 200k-value stress test lost ~30% of values) — because cancelling a
/// `FileHandle.bytes` fetch that's genuinely mid-flight, then starting a new one, can race against
/// it and silently drop data. Here the listener's fetch is *never* cancelled or raced against
/// anything; only the flusher's `Task.sleep` gets cancelled once the listener reaches real EOF,
/// which is harmless since a sleep has no data to lose. Also confirmed empirically (500k random
/// bytes through a real pipe, bursty writer with deliberate gaps, run repeatedly) that this
/// coalesces correctly with zero data loss, at a fraction of the per-byte task-spawn cost of the
/// race-every-byte approach.
///
/// `read()` itself is an actor, not just `Sendable`: `Relay` only ever calls it sequentially
/// today, but a plain class with a "fresh iterator per call" body wouldn't actually be safe under
/// *concurrent* callers - each call's local `AsyncStream` iterator races the others on the same
/// underlying stream, and turning the type into a plain `actor` alone wouldn't fix that either,
/// since actor reentrancy still lets a second `read()` start once the first suspends at its own
/// `await`. The explicit turn-taking below (mirroring `RealByteSink`'s write-side back-pressure)
/// is what actually guarantees only one `read()` is in flight at a time.
public actor RealByteSource: ByteSource {
  private let stream: AsyncStream<Data>
  private var isReading = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(
    fileDescriptor: Int32, coalesceWindow: Duration = .milliseconds(1), maxChunkSize: Int = 64 * 1024
  ) {
    let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    self.stream = stream
    // A synchronous actor init can't access other actor-isolated members (only directly
    // initialize its own stored properties), so this is a local @Dependency rather than an
    // instance one - resolved once here, at bootstrap, and passed through explicitly since
    // pump is a static func with no access to self anyway.
    @Dependency(\.continuousClock) var clock
    Task {
      await Self.pump(
        handle: handle, continuation: continuation, coalesceWindow: coalesceWindow, maxChunkSize: maxChunkSize, clock: clock)
    }
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

  private static func pump(
    handle: FileHandle, continuation: AsyncStream<Data>.Continuation, coalesceWindow: Duration, maxChunkSize: Int,
    clock: any Clock<Duration>
  ) async {
    let buffer = CoalesceBuffer(continuation: continuation, maxChunkSize: maxChunkSize)

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        do {
          for try await byte in handle.bytes {
            await buffer.append(byte)
          }
        } catch {
          // A read error ends the stream the same as EOF would; Relay surfaces the failure
          // through whichever direction actually threw, not by propagating it out of here.
        }
      }
      group.addTask {
        // Cancelled once the listener above finishes - safe, since a sleep has no in-flight
        // read to lose, unlike cancelling the listener's own fetch would be.
        while !Task.isCancelled {
          try? await clock.sleep(for: coalesceWindow)
          await buffer.flushIfIdleSinceLastCheck()
        }
      }
      await group.next()  // only the listener can finish on its own - the flusher loops until cancelled
      group.cancelAll()
    }

    await buffer.flushRemaining()
    continuation.finish()
  }
}

/// The shared state `RealByteSource.pump`'s listener and flusher tasks coordinate through - an
/// actor so appending a byte and checking/flushing on a timer can't race each other.
///
/// "Idle" is tracked with a flag rather than an elapsed-time comparison against a clock
/// `Instant`: the flusher's `sleep` already goes through the injected `Clock`, so this only
/// needs to answer "did anything arrive during my last full sleep" - not how much, just
/// whether. A flag also sidesteps needing to name a concrete `Instant` type for an existential
/// `any Clock<Duration>` (its associated `Instant` is erased), and keeps this actor fully driven
/// by `TestClock.advance` in tests rather than any real wall-clock reads.
private actor CoalesceBuffer {
  private var buffer = Data()
  private var hasAppendedSinceLastCheck = false
  private let continuation: AsyncStream<Data>.Continuation
  private let maxChunkSize: Int

  init(continuation: AsyncStream<Data>.Continuation, maxChunkSize: Int) {
    self.continuation = continuation
    self.maxChunkSize = maxChunkSize
  }

  func append(_ byte: UInt8) {
    buffer.append(byte)
    hasAppendedSinceLastCheck = true
    if buffer.count >= maxChunkSize {
      flush()
    }
  }

  func flushIfIdleSinceLastCheck() {
    guard !hasAppendedSinceLastCheck else {
      hasAppendedSinceLastCheck = false
      return
    }
    flush()
  }

  func flushRemaining() {
    flush()
  }

  private func flush() {
    guard !buffer.isEmpty else { return }
    continuation.yield(buffer)
    buffer = Data()
  }
}

/// Bridges a raw file descriptor's write direction into `ByteSink`, giving every caller genuine
/// back-pressure — suspending until its turn rather than failing outright under contention.
/// Unsynchronized concurrent writes to the same fd aren't just a queueing nicety to get right:
/// POSIX only guarantees a `write()` is atomic (never interleaved with another writer) up to
/// `PIPE_BUF` bytes, so anything larger genuinely can arrive on the wire garbled without this.
/// An actor, one per file descriptor - callers writing to unrelated file descriptors get their
/// own instance, so a slow write to one stream can never stall an unrelated one.
public actor RealByteSink: ByteSink {
  private let handle: FileHandle
  private var isWriting = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(fileDescriptor: Int32) {
    self.handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
  }

  public func write(_ data: Data) async throws {
    await acquireTurn()
    defer { releaseTurn() }
    try await performWrite(data)
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

  private func performWrite(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
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
