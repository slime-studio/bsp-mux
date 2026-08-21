import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct RealDuplexByteStreamTests {
  private static func withConnectedSocketPair(_ body: (ConnectionHandle, ConnectionHandle) async throws -> Void) async throws {
    let path = "/tmp/bsp-mux-duplex-test-\(UUID().uuidString).sock"
    defer { unlink(path) }

    let environment = RealElectionEnvironment()
    let listening = try environment.listen(at: path)
    defer { close(listening.fileDescriptor) }

    async let accepted = RealSocketAccepting().accept(on: listening)
    guard let clientConnection = try environment.connect(to: path) else {
      Issue.record("expected connect() to succeed against a live listener")
      return
    }
    defer { close(clientConnection.fileDescriptor) }

    let serverConnection = try await accepted
    defer { close(serverConnection.fileDescriptor) }

    try await body(clientConnection, serverConnection)
  }

  @Test func writesFromOneEndAreReadableFromTheOtherThroughTheWrappedFileDescriptor() async throws {
    try await Self.withConnectedSocketPair { clientConnection, serverConnection in
      // Wrap the SERVER end with RealDuplexByteStream (both directions, one fd, the type under
      // test); drive the CLIENT end with the already-proven RealByteSource/RealByteSink
      // directly, as an independent counterpart.
      let duplex = RealDuplexByteStream(fileDescriptor: serverConnection.fileDescriptor)
      let clientSource = RealByteSource(fileDescriptor: clientConnection.fileDescriptor)
      let clientSink = RealByteSink(fileDescriptor: clientConnection.fileDescriptor)

      try await clientSink.write(Data("ping".utf8))
      var receivedByDuplex = Data()
      while receivedByDuplex.count < 4, let chunk = try await duplex.read() {
        receivedByDuplex.append(chunk)
      }
      #expect(receivedByDuplex == Data("ping".utf8))

      try await duplex.write(Data("pong".utf8))
      var receivedByClient = Data()
      while receivedByClient.count < 4, let chunk = try await clientSource.read() {
        receivedByClient.append(chunk)
      }
      #expect(receivedByClient == Data("pong".utf8))
    }
  }
}
