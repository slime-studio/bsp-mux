import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct JSONRPCEnvelopeTests {
  static func envelope(_ json: String) throws -> JSONRPCEnvelope {
    try JSONRPCEnvelope(rawBytes: Data(json.utf8))
  }

  @Test func extractsIntegerIdAndMethodFromRequest() throws {
    let e = try Self.envelope(#"{"jsonrpc":"2.0","id":1,"method":"build/initialize","params":{}}"#)
    #expect(e.id == JSONRPCRawID(rawText: "1"))
    #expect(e.method == "build/initialize")
  }

  @Test func notificationHasNoId() throws {
    let e = try Self.envelope(#"{"jsonrpc":"2.0","method":"build/initialized","params":{}}"#)
    #expect(e.id == nil)
    #expect(e.method == "build/initialized")
  }

  @Test func explicitNullIdIsDistinctFromAbsentId() throws {
    let e = try Self.envelope(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32602,"message":"oops"}}"#)
    #expect(e.id == JSONRPCRawID(rawText: "null"))
  }

  @Test func stringIdPreservesSurroundingQuotesInRawText() throws {
    let e = try Self.envelope(#"{"jsonrpc":"2.0","id":"abc-123","method":"foo","params":{}}"#)
    #expect(e.id == JSONRPCRawID(rawText: #""abc-123""#))
  }

  @Test func responseHasNoMethod() throws {
    let e = try Self.envelope(#"{"jsonrpc":"2.0","id":5,"result":{"ok":true}}"#)
    #expect(e.method == nil)
    #expect(e.id == JSONRPCRawID(rawText: "5"))
  }

  @Test func largeIntegerIdPreservedExactlyNotMangledByDoubleConversion() throws {
    // 17 significant digits: well beyond Double's ~15-17 digit precision, and exactly the
    // shape of a millisecond-since-epoch timestamp this protocol already uses elsewhere.
    let e = try Self.envelope(#"{"jsonrpc":"2.0","id":17371488000001237,"method":"foo","params":{}}"#)
    #expect(e.id == JSONRPCRawID(rawText: "17371488000001237"))
  }

  @Test func fieldOrderDoesNotAffectExtraction() throws {
    let paramsFirst = try Self.envelope(#"{"params":{},"method":"foo","jsonrpc":"2.0","id":3}"#)
    #expect(paramsFirst.id == JSONRPCRawID(rawText: "3"))
    #expect(paramsFirst.method == "foo")

    let idLast = try Self.envelope(#"{"jsonrpc":"2.0","method":"foo","params":{},"id":3}"#)
    #expect(idLast.id == JSONRPCRawID(rawText: "3"))
    #expect(idLast.method == "foo")
  }

  @Test func escapedQuotesAndBackslashesInParamsDoNotConfuseParsing() throws {
    let json = #"{"jsonrpc":"2.0","id":9,"method":"build/log","params":{"message":"a \"quoted\" and \\backslashed\\ value"}}"#
    let e = try Self.envelope(json)
    #expect(e.id == JSONRPCRawID(rawText: "9"))
    #expect(e.method == "build/log")
  }

  @Test func bracesAndBracketsInsideStringValuesDoNotConfuseBalancing() throws {
    let json = #"{"jsonrpc":"2.0","id":9,"method":"foo","params":{"weird":"{[}] not real json structure"},"trailing":1}"#
    let e = try Self.envelope(json)
    #expect(e.id == JSONRPCRawID(rawText: "9"))
    #expect(e.method == "foo")
  }

  @Test func deeplyNestedParamsAreSkippedCorrectly() throws {
    let json = #"""
      {"jsonrpc":"2.0","id":9,"method":"foo",
       "params":{"a":[1,2,{"b":{"c":[["d","e"],{"f":null}]}}]}}
      """#
    let e = try Self.envelope(json)
    #expect(e.id == JSONRPCRawID(rawText: "9"))
  }

  @Test func unicodeEscapesInStringsDoNotConfuseParsing() throws {
    let json = #"{"jsonrpc":"2.0","id":9,"method":"foo","params":{"name":"café \"quote\" A"}}"#
    let e = try Self.envelope(json)
    #expect(e.id == JSONRPCRawID(rawText: "9"))
  }

  @Test func prettyPrintedWhitespaceIsHandled() throws {
    let json = """
      {
        "jsonrpc" : "2.0" ,
        "id" : 7 ,
        "method" : "foo" ,
        "params" : { }
      }
      """
    let e = try Self.envelope(json)
    #expect(e.id == JSONRPCRawID(rawText: "7"))
    #expect(e.method == "foo")
  }

  @Test func nonObjectTopLevelThrows() {
    #expect(throws: JSONRPCEnvelopeError.self) {
      _ = try Self.envelope("[1,2,3]")
    }
  }

  // MARK: - withRewrittenID

  @Test func withRewrittenIDSplicesOnlyTheIdField() throws {
    let json = #"{"jsonrpc":"2.0","id":1,"method":"foo","params":{"n":17371488000001237}}"#
    let e = try Self.envelope(json)
    let rewritten = e.withRewrittenID(JSONRPCRawID(rawText: "999"))
    let expected = #"{"jsonrpc":"2.0","id":999,"method":"foo","params":{"n":17371488000001237}}"#
    #expect(String(bytes: rewritten, encoding: .utf8)! == expected)
  }

  @Test func withRewrittenIDPreservesLargeNumberInParamsExactly() throws {
    // The real risk: rewriting id must not touch params, even when params contains a number
    // that would lose precision if the message were decoded/re-encoded as a whole.
    let json = #"{"jsonrpc":"2.0","id":1,"method":"foo","params":{"timestamp":17371488000001237}}"#
    let e = try Self.envelope(json)
    let rewritten = try JSONRPCEnvelope(rawBytes: e.withRewrittenID(JSONRPCRawID(rawText: "2")))
    #expect(rewritten.paramsField("timestamp") == "17371488000001237")
  }

  @Test func withRewrittenIDOnNotificationIsANoOp() throws {
    let json = #"{"jsonrpc":"2.0","method":"build/initialized","params":{}}"#
    let e = try Self.envelope(json)
    let rewritten = e.withRewrittenID(JSONRPCRawID(rawText: "999"))
    #expect(rewritten == Data(json.utf8))
  }

  @Test func withRewrittenIDHandlesStringIdReplacedByIntegerId() throws {
    let json = #"{"jsonrpc":"2.0","id":"client-chosen","method":"foo","params":{}}"#
    let e = try Self.envelope(json)
    let rewritten = e.withRewrittenID(JSONRPCRawID(rawText: "42"))
    let expected = #"{"jsonrpc":"2.0","id":42,"method":"foo","params":{}}"#
    #expect(String(bytes: rewritten, encoding: .utf8)! == expected)
  }

  // MARK: - paramsField

  @Test func paramsFieldFindsTopLevelOriginId() throws {
    let json = #"{"jsonrpc":"2.0","id":1,"method":"buildTarget/compile","params":{"originId":"abc-123","targets":[]}}"#
    let e = try Self.envelope(json)
    #expect(e.paramsField("originId") == #""abc-123""#)
  }

  @Test func paramsFieldReturnsNilWhenKeyAbsent() throws {
    let json = #"{"jsonrpc":"2.0","id":1,"method":"buildTarget/compile","params":{"targets":[]}}"#
    let e = try Self.envelope(json)
    #expect(e.paramsField("originId") == nil)
  }

  @Test func paramsFieldReturnsNilWhenParamsAbsent() throws {
    let json = #"{"jsonrpc":"2.0","id":1,"method":"foo"}"#
    let e = try Self.envelope(json)
    #expect(e.paramsField("originId") == nil)
  }

  @Test func paramsFieldReturnsNilWhenParamsIsNotAnObject() throws {
    let json = #"{"jsonrpc":"2.0","id":1,"method":"foo","params":[1,2,3]}"#
    let e = try Self.envelope(json)
    #expect(e.paramsField("originId") == nil)
  }

  @Test func paramsFieldDoesNotDescendPastOneLevel() throws {
    // originId nested inside a sub-object of params should NOT be found - it's only ever a
    // direct top-level field of params per the BSP originId convention.
    let json = #"{"jsonrpc":"2.0","id":1,"method":"foo","params":{"nested":{"originId":"abc"}}}"#
    let e = try Self.envelope(json)
    #expect(e.paramsField("originId") == nil)
  }
}
