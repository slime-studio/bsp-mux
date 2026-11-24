import Dependencies
import Foundation

/// Owns everything DESIGN.md's "Daemon-side state" describes for one project: the connected
/// sessions, the single backend connection, and the tables that let several sessions share it
/// — including `build/initialize`'s handshake round trip and the `build/initialized`/
/// `shutdown`/`exit` lifecycle, which turned out not to be cleanly separable from that state
/// (see `BSPMessages`'s doc comment for why). An actor so all mutation (a new session
/// registering, a request racing a response) is serialized without hand-rolled locking.
///
/// Still missing, on purpose: real I/O — this operates purely on `DuplexChannel`/message
/// bodies, not actual stdio/socket wiring or backend process spawning.
public actor Daemon {
  private var sessions: [SessionID: ClientSession] = [:]
  private var nextSessionIDValue = 0

  private let backend: any DuplexChannel
  private var nextBackendRequestIDValue = 0

  /// Backend-facing request id (its raw text) -> who asked and what id they originally used.
  /// Minted when a client's request is forwarded to the backend, consulted and removed when
  /// the matching response comes back - a request is only ever answered once.
  private var pendingRequests: [String: (session: SessionID, originalID: JSONRPCRawID)] = [:]

  /// originId (its raw text, as sent by whichever client minted it) -> the session that owns
  /// it, recorded when a request/notification carrying one is forwarded to the backend so a
  /// later backend notification carrying the same originId can be routed back to just them.
  private var originIDOwners: [String: SessionID] = [:]

  /// `build/initialize`'s handshake: the real round trip happens once, against `firstRequest`;
  /// every concurrent or later caller awaits `initializeTask`'s same result (in flight, it's
  /// the real backend round trip; already completed, `Task.value` just replays it) rather than
  /// Daemon coordinating that fan-out by hand.
  private var initializeTask: Task<JSONRPCEnvelope, Error>?
  private var firstInitializeRequest: JSONRPCEnvelope?
  private var pendingInitializeBackendID: JSONRPCRawID?
  private var pendingInitializeContinuation: CheckedContinuation<JSONRPCEnvelope, Error>?
  private var hasForwardedInitialized = false

  private let idleGracePeriod: Duration
  @Dependency(\.continuousClock) private var clock
  @Dependency(\.logging) private var logging
  private var idleGraceTask: Task<Void, Never>?
  private var shutdownContinuations: [CheckedContinuation<Void, Never>] = []

  /// The three ways a daemon's life ends - `performShutdown()` (idle timeout),
  /// `handleBackendDisconnected()` (the backend's own connection ending), and
  /// `requestForcedShutdown()` (an external `bsp-mux stop`) - all fit the same shape: committed
  /// to *once*, doing some async work, then done. A single enum is the actual state (as opposed
  /// to two independently-mutable booleans standing in for it) so "is some path already
  /// committed, even one still mid-flight" and "has a path actually finished" can't drift apart
  /// or be checked against the wrong one by mistake.
  private enum ShutdownPhase {
    /// No path has started yet; still safe for any of the three to begin.
    case running
    /// A path is committed and running (possibly still only partway through its own awaits) -
    /// enough on its own to keep every other path out, finished or not. Without this distinct
    /// from `.shutDown`, two of the three methods could each observe "nothing's shut down yet"
    /// during each other's suspension points and both proceed - concretely, the backend could
    /// receive two `build/shutdown`/`build/exit` pairs from two racing `bspMux/stop` calls, or
    /// from one racing the backend's own disconnect.
    case shuttingDown
    /// The committed path's work is done; `waitForShutdown()`'s continuations are resolved.
    case shutDown
  }
  private var shutdownPhase: ShutdownPhase = .running

  /// Whether an external `bsp-mux stop` request (see `handleClientMessage`'s `.bspMuxStop` case)
  /// is why this daemon is shutting down, and if so whether it asked for a hard kill - read by
  /// `RealBSPMuxApplication.run()` after `waitForShutdown()` resolves to decide between
  /// `DaemonTeardown`'s `.normal` and `.signal` reasons. An ordinary idle-timeout/backend-
  /// disconnect shutdown leaves this `.none`, since those paths already best-effort attempted a
  /// graceful backend shutdown (or the backend is already gone) - only an administrative stop
  /// needs the backend's process group force-signaled.
  public enum ForcedShutdownRequest: Sendable, Equatable {
    case none
    case requested(hardKill: Bool)
  }
  public private(set) var forcedShutdown: ForcedShutdownRequest = .none

  public init(backend: any DuplexChannel, idleGracePeriod: Duration = .seconds(5)) {
    self.backend = backend
    self.idleGracePeriod = idleGracePeriod
  }

  @discardableResult
  public func registerSession(channel: any DuplexChannel) -> SessionID {
    // Safe no-op if nothing was actually pending.
    idleGraceTask?.cancel()
    idleGraceTask = nil
    let id = SessionID(nextSessionIDValue)
    nextSessionIDValue += 1
    sessions[id] = ClientSession(id: id, channel: channel)
    return id
  }

  /// Also how a client's `build/exit` (or an abrupt disconnect, once real I/O detects one) is
  /// handled — both just mean "this session is gone now."
  public func deregisterSession(_ id: SessionID) {
    guard sessions.removeValue(forKey: id) != nil else { return }
    if sessions.isEmpty {
      startIdleGraceTimer()
    }
  }

  /// Suspends until the daemon has sent the backend its real shutdown and decided to exit
  /// (the idle grace period elapsed with no new session registering). Callers awaiting this
  /// should then tear down and exit the process. Returns immediately if that's already happened.
  public func waitForShutdown() async {
    guard shutdownPhase != .shutDown else { return }
    await withCheckedContinuation { continuation in
      shutdownContinuations.append(continuation)
    }
  }

  /// Handles one message received from `sessionID`'s channel. The caller (the not-yet-built
  /// receive loop) owns parsing `DuplexChannel.receive()`'s raw bytes into this and deciding
  /// what to do if that parse fails - a policy decision that belongs there, not baked into
  /// either the channel or this routing logic.
  ///
  /// For `build/initialize` specifically, this suspends until the real backend round trip
  /// resolves (its own, or the one a concurrent first caller already started) - other
  /// sessions' messages are still processed normally in the meantime, since that suspension
  /// only blocks this one call, not the actor.
  public func handleClientMessage(from sessionID: SessionID, envelope: JSONRPCEnvelope) async throws {
    guard let session = sessions[sessionID] else { return }

    switch envelope.method {
    case .buildInitialize:
      guard let originalID = envelope.id else { return }
      try await session.send(try await handleInitialize(envelope, originalID: originalID))
    case .buildInitialized:
      // BSP assumes exactly one real handshake; only the first client's confirmation is real.
      guard !hasForwardedInitialized else { return }
      hasForwardedInitialized = true
      try await backend.send(envelope.rawBytes)
    case .buildShutdown:
      guard let id = envelope.id else { return }
      try await session.send(BSPMessages.successResponse(id: id))
    case .buildExit:
      deregisterSession(sessionID)
    case .bspMuxStop:
      await requestForcedShutdown(hardKill: envelope.paramsField("force") == "true")
    default:
      try await forwardToBackend(envelope, from: sessionID)
    }
  }

  /// An external `bsp-mux stop` request arrived over the wire (the `.bspMuxStop` case above).
  /// Every session with an in-flight request gets told this was an intentional admin stop (not
  /// confused with the backend crashing - see `BSPMessages.daemonStoppedErrorResponse`'s doc
  /// comment). Without `hardKill` (a plain `stop`), this also gives the backend the same real
  /// `build/shutdown`/`build/exit` round trip `performShutdown()` sends on an ordinary idle
  /// timeout, so it gets the chance to exit cooperatively; `RealBSPMuxApplication` correspondingly
  /// uses `.normal` for the teardown reason in that case, same as an idle timeout, so
  /// `DaemonTeardown` doesn't *also* force-signal the process group and race that attempt (see
  /// its own doc comment on why). With `hardKill` (`--force`), the backend may be ignoring
  /// `SIGTERM`/unresponsive, so there's no point asking nicely first - `forcedShutdown` tells
  /// `RealBSPMuxApplication` to reach for `SIGKILL` on the process group instead.
  public func requestForcedShutdown(hardKill: Bool) async {
    // Guarding on `.running` (not just "hasn't finished yet") rules out both: a `bspMux/stop`
    // that loses a race with a shutdown that already finished (e.g. an idle timeout) - which
    // would otherwise overwrite `forcedShutdown` after the fact, since `RealBSPMuxApplication`
    // reads it once, right after `waitForShutdown()` resolves - and a second concurrent
    // `bspMux/stop` (or a race with `performShutdown()`/`handleBackendDisconnected()`) passing
    // this same guard during this call's own await points below and duplicating the backend
    // round trip.
    guard shutdownPhase == .running else { return }
    shutdownPhase = .shuttingDown
    forcedShutdown = .requested(hardKill: hardKill)

    await failPendingWork(responseFor: BSPMessages.daemonStoppedErrorResponse, continuationError: DaemonStoppedError())

    if !hardKill {
      // Best-effort: the daemon is exiting either way, and a send failure here (e.g. the
      // backend already died) doesn't change that.
      try? await backend.send(BSPMessages.shutdownRequestData(id: mintBackendRequestID()))
      try? await backend.send(BSPMessages.exitNotificationData())
    }

    markShutDown()
  }

  private func handleInitialize(_ envelope: JSONRPCEnvelope, originalID: JSONRPCRawID) async throws -> Data {
    let response: JSONRPCEnvelope
    let firstRequest: JSONRPCEnvelope

    if let task = initializeTask, let cachedFirstRequest = firstInitializeRequest {
      response = try await task.value
      firstRequest = cachedFirstRequest
    } else {
      firstRequest = envelope
      firstInitializeRequest = envelope
      let backendID = mintBackendRequestID()
      let task = Task<JSONRPCEnvelope, Error> { [backend] in
        try await backend.send(envelope.withRewrittenID(backendID))
        return try await withCheckedThrowingContinuation { continuation in
          self.pendingInitializeBackendID = backendID
          self.pendingInitializeContinuation = continuation
        }
      }
      initializeTask = task
      response = try await task.value
    }

    if let mismatchedField = BSPMessages.mismatchedInitializeField(firstRequest, envelope) {
      return try BSPMessages.mismatchErrorResponse(id: originalID, field: mismatchedField)
    }
    return response.withRewrittenID(originalID)
  }

  private func forwardToBackend(_ envelope: JSONRPCEnvelope, from sessionID: SessionID) async throws {
    if let originalID = envelope.id {
      let backendID = mintBackendRequestID()
      pendingRequests[backendID.rawText] = (session: sessionID, originalID: originalID)
      if let originId = envelope.paramsField(.originId) {
        originIDOwners[originId] = sessionID
      }
      try await backend.send(envelope.withRewrittenID(backendID))
    } else {
      if let originId = envelope.paramsField(.originId) {
        originIDOwners[originId] = sessionID
      }
      try await backend.send(envelope.rawBytes)
    }
  }

  private func mintBackendRequestID() -> JSONRPCRawID {
    defer { nextBackendRequestIDValue += 1 }
    return JSONRPCRawID(rawText: String(nextBackendRequestIDValue))
  }

  /// Handles one message received from the backend. Same parsing-belongs-to-the-caller
  /// reasoning as `handleClientMessage`.
  public func handleBackendMessage(envelope: JSONRPCEnvelope) async throws {
    if envelope.method != nil {
      try await routeBackendNotification(envelope)
      return
    }

    guard let backendID = envelope.id else { return }

    if let pendingID = pendingInitializeBackendID, pendingID == backendID, let continuation = pendingInitializeContinuation {
      pendingInitializeBackendID = nil
      pendingInitializeContinuation = nil
      continuation.resume(returning: envelope)
      return
    }

    guard let (sessionID, originalID) = pendingRequests.removeValue(forKey: backendID.rawText) else {
      // Unmapped response: no in-flight request minted this id (already answered, or the
      // backend sent an id we never issued). Nothing meaningful to route it to.
      return
    }
    guard let session = sessions[sessionID] else { return }
    try await session.send(envelope.withRewrittenID(originalID))
  }

  private func routeBackendNotification(_ envelope: JSONRPCEnvelope) async throws {
    if envelope.method == .buildLogMessage {
      // Daemon-internal only: unattributable backend logs aren't generally useful fanned out
      // across every client. Falls back to the raw notification if `message` isn't a decodable
      // JSON string, so a malformed backend notification still leaves a trail instead of
      // vanishing silently.
      let text = BSPMessages.logMessageText(envelope) ?? String(bytes: envelope.rawBytes, encoding: .utf8) ?? "<non-UTF8 build/logMessage>"
      logging.log(BSPMessages.logMessageLevel(envelope), text)
      return
    }

    if let originId = envelope.paramsField(.originId), let owner = originIDOwners[originId] {
      try await sessions[owner]?.send(envelope.rawBytes)
      return
    }

    for session in sessions.values {
      try await session.send(envelope.rawBytes)
    }
  }

  private func startIdleGraceTimer() {
    idleGraceTask = Task {
      do {
        try await clock.sleep(for: idleGracePeriod)
      } catch {
        return  // Cancelled: a new session registered before the grace period elapsed.
      }
      await performShutdown()
    }
  }

  private func performShutdown() async {
    guard shutdownPhase == .running else { return }
    shutdownPhase = .shuttingDown
    // Best-effort: the daemon is exiting either way, and a send failure here (e.g. the
    // backend already died) doesn't change that.
    try? await backend.send(BSPMessages.shutdownRequestData(id: mintBackendRequestID()))
    try? await backend.send(BSPMessages.exitNotificationData())
    markShutDown()
  }

  /// The backend connection itself ended (crashed, or its own channel erroring/EOF-ing) -
  /// per DESIGN.md: "fail all in-flight requests across every connected session, close
  /// everything, unlink the socket, and exit." This handles the parts that are this actor's own
  /// state to resolve - failing whatever was waiting on a backend answer that will now never
  /// come, and ending the daemon's life the same way a normal idle-timeout shutdown does, so
  /// `waitForShutdown()` callers aren't left hanging forever. Actually closing sessions' own
  /// channels/fds and unlinking the socket file is the caller's job once this returns (this
  /// actor never owned that fd-level state to begin with) - the process exiting shortly after
  /// reclaims it regardless. The next client action naturally re-elects a fresh daemon rather
  /// than this one trying to respawn the backend in place.
  public func handleBackendDisconnected() async {
    guard shutdownPhase == .running else { return }
    shutdownPhase = .shuttingDown
    await failPendingWork(responseFor: BSPMessages.backendDisconnectedErrorResponse, continuationError: BackendDisconnectedError())
    markShutDown()
  }

  /// Fails every session with an in-flight request (and any suspended `build/initialize`
  /// caller) with a caller-supplied error - shared between `handleBackendDisconnected()` and
  /// `requestForcedShutdown()`, which differ only in *why* nothing more is coming back from the
  /// backend and so need different wording, not different bookkeeping.
  private func failPendingWork(responseFor errorResponse: (JSONRPCRawID) -> Data, continuationError: any Swift.Error) async {
    for (session, originalID) in pendingRequests.values {
      try? await sessions[session]?.send(errorResponse(originalID))
    }
    pendingRequests.removeAll()

    pendingInitializeContinuation?.resume(throwing: continuationError)
    pendingInitializeContinuation = nil
    pendingInitializeBackendID = nil
  }

  private func markShutDown() {
    shutdownPhase = .shutDown
    for continuation in shutdownContinuations {
      continuation.resume()
    }
    shutdownContinuations.removeAll()
  }
}

public struct BackendDisconnectedError: Swift.Error, CustomStringConvertible, Equatable {
  public var description: String { "the build server process disconnected unexpectedly" }

  public init() {}
}

public struct DaemonStoppedError: Swift.Error, CustomStringConvertible, Equatable {
  public var description: String { "the bsp-mux daemon was stopped by an administrative request" }

  public init() {}
}
