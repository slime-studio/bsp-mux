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

  static func shutdownRequestData(id: JSONRPCRawID) -> Data {
    Data(#"{"jsonrpc":"2.0","id":\#(id.rawText),"method":"\#(String.buildShutdown)"}"#.utf8)
  }

  static func exitNotificationData() -> Data {
    Data(#"{"jsonrpc":"2.0","method":"\#(String.buildExit)"}"#.utf8)
  }
}
