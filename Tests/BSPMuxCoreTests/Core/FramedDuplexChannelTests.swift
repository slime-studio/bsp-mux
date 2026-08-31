import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct FramedDuplexChannelTests {
  @Test func sendFramesTheBodyWithAContentLengthHeader() async throws {
    let sink = FakeByteStream()
    let channel = FramedDuplexChannel(source: FakeByteStream(), sink: sink)

    try await channel.send(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))

    let written = await sink.writtenChunks
    #expect(written.count == 1)
    let expected = MessageFraming.frame(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
    #expect(written[0] == expected)
  }

  @Test func receiveReassemblesAMessageSplitAcrossManyChunks() async throws {
    let framed = MessageFraming.frame(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
    let chunks = framed.map { byte in Data([byte]) }  // one byte per chunk - worst case
    let source = FakeByteStream(chunks: chunks)
    let channel = FramedDuplexChannel(source: source, sink: FakeByteStream())

    let received = try await channel.receive()
    #expect(received == Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
  }

  @Test func receiveYieldsEachMessageOneAtATimeWhenMultipleArriveInOneChunk() async throws {
    let messageA = Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)
    let messageB = Data(#"{"jsonrpc":"2.0","id":2}"#.utf8)
    var coalesced = MessageFraming.frame(messageA)
    coalesced.append(MessageFraming.frame(messageB))
    let source = FakeByteStream(chunks: [coalesced])
    let channel = FramedDuplexChannel(source: source, sink: FakeByteStream())

    let first = try await channel.receive()
    let second = try await channel.receive()
    #expect(first == messageA)
    #expect(second == messageB)
  }

  @Test func receiveReturnsNilOnCleanEOFBetweenMessages() async throws {
    let source = FakeByteStream()  // no chunks, finishes immediately - a clean EOF
    let channel = FramedDuplexChannel(source: source, sink: FakeByteStream())

    let result = try await channel.receive()
    #expect(result == nil)
  }

  @Test func receiveThrowsWhenEOFCutsOffAPartialMessage() async throws {
    let framed = MessageFraming.frame(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
    let truncated = framed.prefix(framed.count - 5)  // cut off the tail of the body
    let source = FakeByteStream(chunks: [Data(truncated)])
    let channel = FramedDuplexChannel(source: source, sink: FakeByteStream())

    await #expect(throws: MessageFrameError.self) {
      _ = try await channel.receive()
    }
  }

  @Test func sourceReadErrorPropagatesFromReceive() async throws {
    struct FakeError: Swift.Error {}
    let source = FakeByteStream(readError: FakeError())
    let channel = FramedDuplexChannel(source: source, sink: FakeByteStream())

    await #expect(throws: FakeError.self) {
      _ = try await channel.receive()
    }
  }
}
