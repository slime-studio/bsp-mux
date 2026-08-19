import Foundation
import Subprocess
import System

/// Real `BackendSpawning` via `swift-subprocess`, chosen over `Foundation.Process` for CI-verified
/// Linux parity (matching DESIGN.md's portable-POSIX commitment) and a stderr-discarded-by-default
/// posture — exactly the safe default this seam needs, since inheriting the daemon's own stderr
/// risks the backend hitting `SIGPIPE`/`EPIPE` once the launching editor exits and nothing reads
/// it anymore, the same risk DESIGN.md's Logging section already flags for the daemon's own stderr.
///
/// `run(...)`'s interactive body closure is only entered once the process has actually launched
/// (confirmed empirically: it never runs on a launch failure), and it represents the process's
/// entire session — so it's driven by a detached `Task` that outlives this `spawn` call, bridged
/// through two `AsyncStream`s: `outbound` feeds `run`'s own `input: .sequence(_:)` directly (no
/// separate write-forwarding loop needed - `Subprocess` drains it into the child's stdin itself),
/// and `inbound` is fed by looping over `execution.standardOutput` inside the closure. A
/// `CheckedContinuation` bridges "the process launched" back to this `async` function so launch
/// failures surface as a thrown error from `spawn` itself, exactly as if it were synchronous;
/// `hasSignaledLaunch` guards against resuming it twice, which would trap - the closure entering
/// at all is proof of a successful launch, so it's the only place that gets to resume it
/// successfully, and the outer `catch` only resumes (with the failure) when the closure never ran.
public struct RealBackendSpawning: BackendSpawning {
  public init() {}

  public func spawn(argv: [String], workingDirectory: String) async throws -> any DuplexChannel {
    guard let executablePath = argv.first else {
      throw BackendSpawnError(description: "backend argv is empty")
    }
    let arguments = Array(argv.dropFirst())

    let (outbound, outboundContinuation) = AsyncStream<Data>.makeStream()
    let (inbound, inboundContinuation) = AsyncStream<Data>.makeStream()

    try await withCheckedThrowingContinuation { (launchContinuation: CheckedContinuation<Void, Error>) in
      Task {
        nonisolated(unsafe) var hasSignaledLaunch = false
        do {
          _ = try await run(
            .path(FilePath(executablePath)),
            arguments: Arguments(arguments),
            workingDirectory: FilePath(workingDirectory),
            input: .sequence(outbound),
            output: .sequence,
            error: .discarded
          ) { execution in
            hasSignaledLaunch = true
            launchContinuation.resume()
            for try await buffer in execution.standardOutput {
              var chunk = Data()
              buffer.withUnsafeBytes { chunk.append(contentsOf: $0) }
              inboundContinuation.yield(chunk)
            }
          }
        } catch {
          if !hasSignaledLaunch {
            launchContinuation.resume(throwing: BackendSpawnError(description: "failed to launch backend \(executablePath): \(error)"))
          }
          // Otherwise: the process launched fine and this is just how its session ended
          // (crashed, exited, a standardOutput read failed) - nothing left to report through
          // launchContinuation, which spawn() has already consumed.
        }
        inboundContinuation.finish()
      }
    }

    let byteStream = SubprocessByteStream(inbound: inbound, outboundContinuation: outboundContinuation)
    return FramedDuplexChannel(source: byteStream, sink: byteStream)
  }
}

/// Bridges the `AsyncStream` pair `RealBackendSpawning.spawn`'s detached task maintains into
/// `ByteSource`/`ByteSink` - deliberately the raw, framing-free level, not `DuplexChannel`
/// itself: framing is each `DuplexChannel` conformance's own concern, so `spawn` composes this
/// with `FramedDuplexChannel` (which already owns `Content-Length` framing) rather than this
/// type applying framing itself. `write` just yields into `outboundContinuation` - `Subprocess`'s
/// own `input: .sequence(_:)` is what actually drains it into the backend's stdin, not this type.
private final class SubprocessByteStream: ByteSource, ByteSink {
  private let inbound: AsyncStream<Data>
  private let outboundContinuation: AsyncStream<Data>.Continuation

  init(inbound: AsyncStream<Data>, outboundContinuation: AsyncStream<Data>.Continuation) {
    self.inbound = inbound
    self.outboundContinuation = outboundContinuation
  }

  func write(_ data: Data) async throws {
    outboundContinuation.yield(data)
  }

  func read() async throws -> Data? {
    var iterator = inbound.makeAsyncIterator()
    return await iterator.next()
  }
}
