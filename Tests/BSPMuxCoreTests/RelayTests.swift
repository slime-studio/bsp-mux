import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct RelayTests {
  private struct FakeError: Swift.Error, Equatable {}

  @Test func bytesFromStandardInAreForwardedToTheSocketVerbatim() async throws {
    let standardIn = FakeByteStream(chunks: [Data("hello".utf8), Data(" world".utf8)])
    let standardOut = FakeByteStream()
    let socket = FakeByteStream()

    try await Relay.run(standardIn: standardIn, standardOut: standardOut, socket: socket)

    #expect(await socket.writtenChunks == [Data("hello".utf8), Data(" world".utf8)])
    #expect(await standardOut.writtenChunks.isEmpty)
  }

  @Test func bytesFromTheSocketAreForwardedToStandardOutVerbatim() async throws {
    let standardIn = FakeByteStream()
    let standardOut = FakeByteStream()
    let socket = FakeByteStream(chunks: [Data("reply".utf8)])

    try await Relay.run(standardIn: standardIn, standardOut: standardOut, socket: socket)

    #expect(await standardOut.writtenChunks == [Data("reply".utf8)])
    #expect(await socket.writtenChunks.isEmpty)
  }

  @Test func standardInEOFEndsTheRelayEvenWhileTheSocketIsStillOpen() async throws {
    let standardIn = FakeByteStream(chunks: [Data("bye".utf8)])
    let standardOut = FakeByteStream()
    let socket = FakeByteStream(remainsOpenWhenExhausted: true)

    // standardIn reaches EOF after one chunk; the socket never does on its own - this only
    // returns promptly if standardIn's EOF actually cancels the still-hanging socket read.
    try await Relay.run(standardIn: standardIn, standardOut: standardOut, socket: socket)

    #expect(await socket.writtenChunks == [Data("bye".utf8)])
  }

  @Test func socketEOFEndsTheRelayEvenWhileStandardInIsStillOpen() async throws {
    let standardIn = FakeByteStream(remainsOpenWhenExhausted: true)
    let standardOut = FakeByteStream()
    let socket = FakeByteStream(chunks: [Data("closing".utf8)])

    try await Relay.run(standardIn: standardIn, standardOut: standardOut, socket: socket)

    #expect(await standardOut.writtenChunks == [Data("closing".utf8)])
  }

  @Test func errorReadingStandardInAbortsTheRelayAndPropagates() async throws {
    let standardIn = FakeByteStream(readError: FakeError())
    let standardOut = FakeByteStream()
    let socket = FakeByteStream(remainsOpenWhenExhausted: true)

    await #expect(throws: FakeError.self) {
      try await Relay.run(standardIn: standardIn, standardOut: standardOut, socket: socket)
    }
  }

  @Test func errorReadingSocketAbortsTheRelayAndPropagates() async throws {
    let standardIn = FakeByteStream(remainsOpenWhenExhausted: true)
    let standardOut = FakeByteStream()
    let socket = FakeByteStream(readError: FakeError())

    await #expect(throws: FakeError.self) {
      try await Relay.run(standardIn: standardIn, standardOut: standardOut, socket: socket)
    }
  }
}
