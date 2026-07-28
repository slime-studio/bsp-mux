import Clocks
import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct RealSocketAcceptingTests {
  private static func withTempSocketPath(_ body: (String) async throws -> Void) async throws {
    let path = "/tmp/bsp-mux-accept-test-\(UUID().uuidString).sock"
    defer { unlink(path) }
    try await body(path)
  }

  @Test func acceptReturnsAWorkingConnectionOnceAClientConnects() async throws {
    try await Self.withTempSocketPath { path in
      let environment = RealElectionEnvironment()
      let listening = try environment.listen(at: path)
      defer { close(listening.fileDescriptor) }

      async let accepted = RealSocketAccepting().accept(on: listening)

      // Give the accept() call a moment to actually be blocked in accept() before connecting -
      // not required for correctness (the kernel queues a pending connect either way), just
      // exercises the "client arrives after accept() is already waiting" ordering explicitly.
      try await Task.sleep(for: .milliseconds(20))
      guard let clientConnection = try environment.connect(to: path) else {
        Issue.record("expected connect() to succeed against a live listener")
        return
      }
      defer { close(clientConnection.fileDescriptor) }

      let serverConnection = try await accepted
      defer { close(serverConnection.fileDescriptor) }

      try await withDependencies {
        $0.continuousClock = ImmediateClock()
      } operation: {
        let serverSource = RealByteSource(fileDescriptor: serverConnection.fileDescriptor)
        let clientSink = RealByteSink(fileDescriptor: clientConnection.fileDescriptor)

        try await clientSink.write(Data("hello".utf8))

        var received = Data()
        while received.count < 5, let chunk = try await serverSource.read() {
          received.append(chunk)
        }
        #expect(received == Data("hello".utf8))
      }
    }
  }

  @Test func acceptingOnAClosedListenerThrows() async throws {
    try await Self.withTempSocketPath { path in
      let environment = RealElectionEnvironment()
      let listening = try environment.listen(at: path)
      close(listening.fileDescriptor)

      await #expect(throws: SocketAcceptError.self) {
        _ = try await RealSocketAccepting().accept(on: listening)
      }
    }
  }
}
