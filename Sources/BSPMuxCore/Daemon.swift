import Foundation

/// Owns everything DESIGN.md's "Daemon-side state" describes for one project: the connected
/// sessions, the single backend connection, and the tables that let several sessions share it.
/// An actor so all mutation (a new session registering, a request racing a response) is
/// serialized without hand-rolled locking.
///
/// This is the core multiplexing logic — request/response id-rewriting and notification
/// routing — and it's deliberately all this type does so far. Still missing, on purpose:
/// - The `build/initialize`/`build/initialized`/`build/shutdown`/`build/exit` lifecycle
///   methods aren't special-cased yet (they fall through the generic forwarding path below),
///   so multi-client correctness for the handshake cache/replay and refcounted teardown isn't
///   here yet. `build/initialize` specifically needs a decision about which response fields
///   are safe to compare across clients before it can be built correctly.
/// - No refcount or idle-grace-period teardown.
/// - No real I/O — this operates purely on `DuplexChannel`/message bodies, not actual
///   stdio/socket wiring or backend process spawning.
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

  public init(backend: any DuplexChannel) {
    self.backend = backend
  }

  @discardableResult
  public func registerSession(channel: any DuplexChannel) -> SessionID {
    let id = SessionID(nextSessionIDValue)
    nextSessionIDValue += 1
    sessions[id] = ClientSession(id: id, channel: channel)
    return id
  }

  public func deregisterSession(_ id: SessionID) {
    sessions.removeValue(forKey: id)
  }

  /// Handles one message received from `sessionID`'s channel.
  public func handleClientMessage(from sessionID: SessionID, raw: Data) async throws {
    guard sessions[sessionID] != nil else { return }
    let envelope = try JSONRPCEnvelope(rawBytes: raw)

    if let originalID = envelope.id {
      let backendID = JSONRPCRawID(rawText: String(nextBackendRequestIDValue))
      nextBackendRequestIDValue += 1
      pendingRequests[backendID.rawText] = (session: sessionID, originalID: originalID)
      if let originId = envelope.paramsField("originId") {
        originIDOwners[originId] = sessionID
      }
      try await backend.send(envelope.withRewrittenID(backendID))
    } else {
      if let originId = envelope.paramsField("originId") {
        originIDOwners[originId] = sessionID
      }
      try await backend.send(raw)
    }
  }

  /// Handles one message received from the backend.
  public func handleBackendMessage(raw: Data) async throws {
    let envelope = try JSONRPCEnvelope(rawBytes: raw)

    if envelope.method != nil {
      try await routeBackendNotification(raw: raw, envelope: envelope)
      return
    }

    guard let backendID = envelope.id else { return }
    guard let (sessionID, originalID) = pendingRequests.removeValue(forKey: backendID.rawText) else {
      // Unmapped response: no in-flight request minted this id (already answered, or the
      // backend sent an id we never issued). Nothing meaningful to route it to.
      return
    }
    guard let session = sessions[sessionID] else { return }
    try await session.send(envelope.withRewrittenID(originalID))
  }

  private func routeBackendNotification(raw: Data, envelope: JSONRPCEnvelope) async throws {
    if envelope.method == "build/logMessage" {
      // Daemon-internal only: unattributable backend logs aren't generally useful fanned out
      // across every client. (Not yet wired to an actual log file - see the type doc.)
      return
    }

    if let originId = envelope.paramsField("originId"), let owner = originIDOwners[originId] {
      try await sessions[owner]?.send(raw)
      return
    }

    for session in sessions.values {
      try await session.send(raw)
    }
  }
}
