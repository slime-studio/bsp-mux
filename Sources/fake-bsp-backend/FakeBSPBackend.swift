import BuildServerProtocol
public import LanguageServerProtocol
import Foundation

/// A minimal, spec-compliant BSP server - the dispatch logic only, kept separate from
/// `main.swift`'s real-stdio wiring so it's directly testable with zero real I/O. Handles the
/// lifecycle (`initialize`/`initialized`/`shutdown`/`exit`) plus two always-empty responses
/// (`workspace/buildTargets`, `buildTarget/sources`); everything else `MessageRegistry.bspProtocol`
/// defines gets an honest rejection rather than fabricated build data - `bsp-mux` itself treats
/// all of this as opaque already (see `BSPMethod`'s own doc comment in `BSPMuxCore`), so there's
/// no multiplexing behavior that needs more than this to exercise.
public final class FakeBSPBackend: MessageHandler, @unchecked Sendable {
  // Mutated only from JSONRPCConnection's own serial `queue` in production (guaranteed by
  // `dispatchPrecondition(condition: .onQueue(queue))` in its own implementation) - matches
  // `WeakMessageHandler`'s own `nonisolated(unsafe)` precedent in the same library for the same
  // reason. Tests call `handle` directly and single-threaded, so this is safe there too.
  private var hasInitialized = false
  private var hasReceivedShutdown = false

  // Not `-> Never`: a real `exit()` call here would take down the test runner along with
  // whatever it's testing, so the real action is injected and a test can substitute a recording
  // no-op instead - same reasoning as `BSPMuxCore`'s `ProcessExiting` port.
  private let exit: @Sendable (Int32) -> Void

  public init(exit: @escaping @Sendable (Int32) -> Void = { Foundation.exit($0) }) {
    self.exit = exit
  }

  public func handle(_ notification: some NotificationType) {
    guard hasInitialized || notification is OnBuildExitNotification else {
      // Per BSP's own spec (see InitializeBuildRequest's doc comment): drop pre-initialize
      // notifications except exit, so a server can still exit cleanly without ever having been
      // initialized.
      return
    }
    switch notification {
    case is OnBuildExitNotification:
      exit(hasReceivedShutdown ? 0 : 1)  // Exact spec wording, see OnBuildExitNotification.
    default:
      break  // Not needed yet - extend as integration tests need more.
    }
  }

  public func handle<Request: RequestType>(
    _ request: Request, id: RequestID, reply: @escaping @Sendable (LSPResult<Request.Response>) -> Void
  ) {
    guard hasInitialized || request is InitializeBuildRequest else {
      reply(.failure(ResponseError(code: .serverNotInitialized, message: "not initialized")))
      return
    }
    if let params = request as? InitializeBuildRequest {
      hasInitialized = true
      let response = InitializeBuildResponse(
        displayName: "fake-bsp-backend", version: "0.1.0", bspVersion: params.bspVersion,
        capabilities: BuildServerCapabilities()
      )
      Self.send(response, as: Request.self, reply: reply)
    } else if request is BuildShutdownRequest {
      hasReceivedShutdown = true
      Self.send(VoidResponse(), as: Request.self, reply: reply)
    } else if request is WorkspaceBuildTargetsRequest {
      Self.send(WorkspaceBuildTargetsResponse(targets: []), as: Request.self, reply: reply)
    } else if request is BuildTargetSourcesRequest {
      Self.send(BuildTargetSourcesResponse(items: []), as: Request.self, reply: reply)
    } else {
      reply(.failure(.methodNotFound(Request.method)))
    }
  }

  /// `handle<Request>` only knows `Request.Response` generically, but each branch above
  /// constructs a specific, concrete response type - `Request == ConcreteRequest` is guaranteed
  /// by the `as?`/`is` check that got us into that branch, but the compiler can't see that fact
  /// through the generic `Request` parameter. A conditional cast (never a force cast) is the
  /// bridge back, with a defensive, logically-unreachable failure path instead of a force cast.
  private static func send<Request: RequestType, ActualResponse>(
    _ response: ActualResponse, as requestType: Request.Type, reply: (LSPResult<Request.Response>) -> Void
  ) {
    guard let typedResponse = response as? Request.Response else {
      reply(.failure(ResponseError(code: .internalError, message: "fake-bsp-backend: response type mismatch")))
      return
    }
    reply(.success(typedResponse))
  }
}
