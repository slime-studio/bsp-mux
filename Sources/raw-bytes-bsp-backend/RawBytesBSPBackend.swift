import BSPMuxCore
import Foundation

/// A deliberately non-spec-compliant BSP server, existing solely to make `BSPMuxIntegrationTests`'
/// `originId`-routed/broadcast notification scenarios possible over real subprocesses.
/// `fake-bsp-backend` can't serve this purpose: its typed `BuildServerProtocol` decode/encode has
/// no field for `originId` at all, and bolting non-spec trigger machinery onto it would make it a
/// *less* faithful stand-in for a real backend, not more. This type instead talks `JSONRPCEnvelope`
/// directly - the same raw, untyped view `Daemon` itself has of a message - since all it needs is
/// a method name and a couple of `params` fields, never real build data.
struct RawBytesBSPBackend {
  /// Processes one incoming message, returning the message bodies to send back, in order.
  func handle(_ rawBytes: Data) throws -> [Data] {
    let envelope = try JSONRPCEnvelope(rawBytes: rawBytes)
    switch envelope.method {
    case "build/initialize":
      guard let id = envelope.id else { return [] }
      let bspVersion = envelope.paramsField("bspVersion") ?? #""2.1.0""#
      let rawResult =
        #"{"displayName":"raw-bytes-bsp-backend","version":"0.1.0","bspVersion":\#(bspVersion),"capabilities":{}}"#
      return [Self.result(id: id, rawResult: rawResult)]
    case "build/shutdown":
      guard let id = envelope.id else { return [] }
      return [Self.result(id: id, rawResult: "{}")]
    case "build/exit":
      exit(0)
    case "test/emitNotification":
      // The explicit trigger a test uses to make this backend spontaneously emit a notification
      // at a moment it controls. Deliberately its own distinct method name, not inferred from any
      // other request's shape - an implicit trigger (e.g. "any request with no originId
      // broadcasts") would fire during ordinary traffic this backend also has to answer (a second
      // no-originId request, a stray build/shutdown), producing a notification neither scenario
      // asked for and an intermittent flake in whichever test asserts a client received nothing.
      guard let id = envelope.id else { return [] }
      var messages: [Data] = []
      if let notificationMethod = envelope.paramsField("notificationMethod") {
        let notificationParams = envelope.paramsField("notificationParams") ?? "{}"
        messages.append(Self.notification(rawMethod: notificationMethod, rawParams: notificationParams))
      }
      messages.append(Self.result(id: id, rawResult: "{}"))
      return messages
    default:
      // Every other forwarded request gets a harmless empty ack and nothing more - only the
      // explicit trigger above ever emits a notification.
      guard let id = envelope.id else { return [] }
      return [Self.result(id: id, rawResult: "{}")]
    }
  }

  /// `envelope.paramsField(_:)` returns a field's raw JSON source text *including quotes* for
  /// strings, so `rawResult`/`rawMethod`/`rawParams` below are spliced in as-is, never re-quoted.
  private static func result(id: JSONRPCRawID, rawResult: String) -> Data {
    Data(#"{"jsonrpc":"2.0","id":\#(id.rawText),"result":\#(rawResult)}"#.utf8)
  }

  private static func notification(rawMethod: String, rawParams: String) -> Data {
    Data(#"{"jsonrpc":"2.0","method":\#(rawMethod),"params":\#(rawParams)}"#.utf8)
  }
}
