import Foundation

/// Pure, stateless BSP message construction and comparison — no session/request state, no I/O.
///
/// Everything that actually needs state (the `build/initialize` round trip, forwarding
/// decisions) lives directly on `Daemon` instead: a daemon's session lifecycle is one small,
/// tightly-coupled consistency domain, not something that splits cleanly along a
/// "BSP-specific vs. generic multiplexing" line — three of BSP's four lifecycle methods need
/// the exact same state `Daemon` already owns for id-rewriting and the session registry, so
/// pulling them into a separate stateful type just recreated a second consistency boundary
/// that had to be kept in sync with the first one by convention instead of by anything the
/// compiler checks.
enum BSPMessages {
  /// Fields legitimate to compare between two clients' `build/initialize` params before
  /// replaying a cached response to the second one. Deliberately excludes `displayName`/
  /// `version` (pure client identity, expected to differ between editors/versions). The rest
  /// can make a cached response actually unsafe to replay: `bspVersion` (negotiated for a
  /// specific protocol version), `rootUri` (should already be identical by construction - one
  /// daemon per resolved workspace root - so a mismatch here would flag a real bug), and
  /// `capabilities`/`dataKind`/`data` (`BuildClientCapabilities`' own doc comment: "the server
  /// must never respond with build targets for other languages than those in this list" - a
  /// client that declared more than the first one would be under-served by its cached response).
  private static let comparedInitializeFields = ["bspVersion", "rootUri", "capabilities", "dataKind", "data"]

  /// Raw-text equality, not a normalized JSON compare - a false mismatch from incidental
  /// whitespace differences is possible in principle, but real clients encode compactly and
  /// consistently, so this isn't worth a normalized comparator yet.
  static func mismatchedInitializeField(_ a: JSONRPCEnvelope, _ b: JSONRPCEnvelope) -> String? {
    comparedInitializeFields.first { a.paramsField($0) != b.paramsField($0) }
  }

  private static let mismatchErrorCode = -32000
  private static let backendDisconnectedErrorCode = -32001
  private static let daemonStoppedErrorCode = -32002

  static func mismatchErrorResponse(id: JSONRPCRawID, field: String) throws -> Data {
    let message = "initialize params (\(field)) do not match the daemon's existing session; a separate bsp-mux daemon is required"
    let encodedMessage = try JSONEncoder().encode(message)
    guard let messageText = String(bytes: encodedMessage, encoding: .utf8) else {
      throw JSONRPCEnvelopeError(description: "encoded error message is not valid UTF-8")
    }
    let json = #"{"jsonrpc":"2.0","id":\#(id.rawText),"error":{"code":\#(mismatchErrorCode),"message":\#(messageText)}}"#
    return Data(json.utf8)
  }

  static func successResponse(id: JSONRPCRawID) -> Data {
    Data(#"{"jsonrpc":"2.0","id":\#(id.rawText),"result":null}"#.utf8)
  }

  /// Sent to every session with an in-flight request once the backend connection itself ends
  /// (crash, or its channel erroring/EOF-ing) - see `Daemon.handleBackendDisconnected()`. A
  /// fixed message needs no dynamic escaping the way `mismatchErrorResponse`'s does.
  static func backendDisconnectedErrorResponse(id: JSONRPCRawID) -> Data {
    Data(#"{"jsonrpc":"2.0","id":\#(id.rawText),"error":{"code":\#(backendDisconnectedErrorCode),"message":"the build server process disconnected unexpectedly"}}"#.utf8)
  }

  /// Sent to every session with an in-flight request when an external `bsp-mux stop` ends the
  /// daemon (`Daemon.requestForcedShutdown`) - distinct from `backendDisconnectedErrorResponse`
  /// because this is an intentional admin action, not the backend dying unexpectedly.
  static func daemonStoppedErrorResponse(id: JSONRPCRawID) -> Data {
    Data(#"{"jsonrpc":"2.0","id":\#(id.rawText),"error":{"code":\#(daemonStoppedErrorCode),"message":"the bsp-mux daemon was stopped by an administrative request"}}"#.utf8)
  }

  static func shutdownRequestData(id: JSONRPCRawID) -> Data {
    Data(#"{"jsonrpc":"2.0","id":\#(id.rawText),"method":"\#(String.buildShutdown)"}"#.utf8)
  }

  static func exitNotificationData() -> Data {
    Data(#"{"jsonrpc":"2.0","method":"\#(String.buildExit)"}"#.utf8)
  }

  /// `build/logMessage`'s `message` field, properly JSON-decoded - `paramsField` itself only
  /// peeks at a byte range (still quoted/escaped exactly as it appeared on the wire), since it's
  /// not a full parse. `nil` if the field is missing or isn't a valid JSON string literal.
  static func logMessageText(_ envelope: JSONRPCEnvelope) -> String? {
    guard let raw = envelope.paramsField("message"), let data = raw.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
  }

  /// Maps BSP's `MessageType` (1=Error, 2=Warning, 3=Info, 4=Log) onto this project's own
  /// `LogLevel` - deliberately lossy (both Info and Log collapse to `.info`, and anything
  /// unrecognized defaults there too), matching `LogLevel`'s own doc comment on why it isn't a
  /// one-for-one mirror of BSP's wire type.
  static func logMessageLevel(_ envelope: JSONRPCEnvelope) -> LogLevel {
    switch envelope.paramsField("type") {
    case "1": return .error
    case "2": return .warning
    default: return .info
    }
  }
}
