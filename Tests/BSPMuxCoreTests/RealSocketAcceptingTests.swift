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

      // No synchronization needed before connecting: the kernel queues a pending connection in
      // the listen backlog regardless of whether accept() has been called yet, so this doesn't
      // depend on winning a race against the async let above.
      guard let clientConnection = try environment.connect(to: path) else {
        Issue.record("expected connect() to succeed against a live listener")
        return
      }
      defer { close(clientConnection.fileDescriptor) }

      let serverConnection = try await accepted
      defer { close(serverConnection.fileDescriptor) }

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

  @Test func acceptingOnAnInvalidFileDescriptorThrows() async throws {
    // A fd number that was never opened, rather than a real fd we close and then immediately
    // reuse the same handle for - confirmed empirically (two hangs captured in a 100-run stress
    // batch, both with an identical stack trace) that closing a real fd and reusing that same
    // handle races against fd-number reuse by unrelated, concurrently-running test code: Swift
    // Testing runs many tests at once, and if something else opens a new fd at that exact
    // moment, the OS can reissue the same number to it - accept() then operates on THEIR valid,
    // live socket instead of a closed one, doesn't throw, and hangs waiting for a connection
    // that will never come. A fd number nothing ever opened has no such race window - it's
    // simply never valid, unconditionally, regardless of what else is running concurrently.
    let neverOpened = ListeningHandle(fileDescriptor: 999_999)

    await #expect(throws: SocketAcceptError.self) {
      _ = try await RealSocketAccepting().accept(on: neverOpened)
    }
  }
}
