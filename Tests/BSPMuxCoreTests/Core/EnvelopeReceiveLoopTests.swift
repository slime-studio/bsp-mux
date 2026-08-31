import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct EnvelopeReceiveLoopTests {
  private struct FakeError: Swift.Error, Equatable {}

  private static func validMessage(id: String) -> Data {
    Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"foo"}"#.utf8)
  }

  @Test func dispatchesEachMessageToOnEnvelopeInOrder() async throws {
    let channel = FakeDuplexChannel()
    await channel.enqueueIncoming(Self.validMessage(id: "1"))
    await channel.enqueueIncoming(Self.validMessage(id: "2"))

    var receivedIDs: [String] = []
    try await EnvelopeReceiveLoop.run(
      channel: channel,
      onEnvelope: { envelope in receivedIDs.append(envelope.id!.rawText) },
      onParseFailure: { _ in Issue.record("unexpected parse failure") }
    )

    #expect(receivedIDs == ["1", "2"])
  }

  @Test func returnsNormallyOnCleanEOF() async throws {
    let channel = FakeDuplexChannel()  // nothing queued - receive() returns nil immediately

    try await EnvelopeReceiveLoop.run(
      channel: channel,
      onEnvelope: { _ in Issue.record("no messages should have been dispatched") },
      onParseFailure: { _ in Issue.record("unexpected parse failure") }
    )
  }

  @Test func malformedMessageReportsFailureButLoopContinues() async throws {
    let channel = FakeDuplexChannel()
    await channel.enqueueIncoming(Data("not json".utf8))
    await channel.enqueueIncoming(Self.validMessage(id: "1"))

    var failures: [Error] = []
    var receivedIDs: [String] = []
    try await EnvelopeReceiveLoop.run(
      channel: channel,
      onEnvelope: { envelope in receivedIDs.append(envelope.id!.rawText) },
      onParseFailure: { error in failures.append(error) }
    )

    #expect(failures.count == 1)
    #expect(failures[0] is JSONRPCEnvelopeError)
    #expect(receivedIDs == ["1"])
  }

  @Test func receiveThrowingEndsTheLoopAndPropagates() async throws {
    let channel = FakeDuplexChannel(readError: FakeError())

    await #expect(throws: FakeError.self) {
      try await EnvelopeReceiveLoop.run(
        channel: channel,
        onEnvelope: { _ in },
        onParseFailure: { _ in }
      )
    }
  }

  @Test func onEnvelopeThrowingEndsTheLoopAndPropagatesEvenIfItsAJSONRPCEnvelopeError() async throws {
    let channel = FakeDuplexChannel()
    await channel.enqueueIncoming(Self.validMessage(id: "1"))
    await channel.enqueueIncoming(Self.validMessage(id: "2"))  // must never be reached

    var dispatchCount = 0
    await #expect(throws: JSONRPCEnvelopeError.self) {
      try await EnvelopeReceiveLoop.run(
        channel: channel,
        onEnvelope: { _ in
          dispatchCount += 1
          // Deliberately throws the SAME error type onParseFailure handles, to prove the loop
          // doesn't mistake this for a parse failure and swallow it.
          throw JSONRPCEnvelopeError(description: "downstream failure, not a parse failure")
        },
        onParseFailure: { _ in Issue.record("should not be treated as a parse failure") }
      )
    }

    #expect(dispatchCount == 1)
  }
}
