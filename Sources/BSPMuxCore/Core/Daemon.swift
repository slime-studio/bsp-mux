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
  private var idleGraceTask: Task<Void, Never>?
  private var hasShutDown = false
  private var shutdownContinuations: [CheckedContinuation<Void, Never>] = []

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
  private var forcedShutdownRequest: ForcedShutdownRequest = .none
  public var forcedShutdown: ForcedShutdownRequest { forcedShutdownRequest }

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
    guard !hasShutDown else { return }
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

  /// An external `bsp-mux stop` request arrived over the wire (the `.bspMuxStop` case above) -
  /// same effect on every connected session as the backend itself disconnecting (their in-flight
  /// requests fail, the daemon winds down), reusing `handleBackendDisconnected()`'s already-
  /// tested logic for exactly that reason. The one thing that reuse doesn't capture on its own:
  /// the caller needs to know this shutdown, unlike an ordinary idle-timeout/backend-disconnect,
  /// should force-kill the backend process rather than trusting it already exited or was already
  /// asked nicely - `forcedShutdown` is that signal.
  public func requestForcedShutdown(hardKill: Bool) async {
    forcedShutdownRequest = .requested(hardKill: hardKill)
    await handleBackendDisconnected()
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
      // across every client. (Not yet wired to an actual log file - see the type doc.)
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
    guard !hasShutDown else { return }
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
    guard !hasShutDown else { return }

    for (session, originalID) in pendingRequests.values {
      try? await sessions[session]?.send(BSPMessages.backendDisconnectedErrorResponse(id: originalID))
    }
    pendingRequests.removeAll()

    pendingInitializeContinuation?.resume(throwing: BackendDisconnectedError())
    pendingInitializeContinuation = nil
    pendingInitializeBackendID = nil

    markShutDown()
  }

  private func markShutDown() {
    hasShutDown = true
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
