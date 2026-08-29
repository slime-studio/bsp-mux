import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct RelaySessionTests {
  private struct FakeError: Swift.Error, Equatable {}

  /// Mirrors `RealDuplexByteStreamTests`' own helper: a real, connected `AF_UNIX` socket pair,
  /// standing in for `Election.run()`'s `.relay(ConnectionHandle)` case (`clientConnection`) and
  /// the live daemon on the other end (`serverConnection`).
  private static func withConnectedSocketPair(
    _ body: (ConnectionHandle, ConnectionHandle) async throws -> Void
  ) async throws {
    let path = "/tmp/bsp-mux-relay-session-test-\(UUID().uuidString).sock"
    defer { unlink(path) }

    let environment = RealElectionEnvironment()
    let listening = try environment.listen(at: path)
    defer { close(listening.fileDescriptor) }

    async let accepted = RealSocketAccepting().accept(on: listening)
    guard let clientConnection = try environment.connect(to: path) else {
      Issue.record("expected connect() to succeed against a live listener")
      return
    }

    let serverConnection = try await accepted
    try await body(clientConnection, serverConnection)
  }

  /// Real OS pipes standing in for a process's own stdin/stdout, each retained via its owning
  /// `Pipe` (a `FileHandle` closes its fd on dealloc, so the `Pipe` itself must outlive the fds
  /// derived from it, not just the `RealByteSource`/`RealByteSink` wrapping them).
  private struct PipeStandardIO {
    let inPipe = Pipe()
    let outPipe = Pipe()

    var standardIn: RealByteSource { RealByteSource(fileDescriptor: inPipe.fileHandleForReading.fileDescriptor) }
    var writeToStandardIn: RealByteSink { RealByteSink(fileDescriptor: inPipe.fileHandleForWriting.fileDescriptor) }
    var standardOut: RealByteSink { RealByteSink(fileDescriptor: outPipe.fileHandleForWriting.fileDescriptor) }
    var readFromStandardOut: RealByteSource { RealByteSource(fileDescriptor: outPipe.fileHandleForReading.fileDescriptor) }

    func closeTestEnds() {
      try? inPipe.fileHandleForWriting.close()
      try? outPipe.fileHandleForReading.close()
    }
  }

  /// Confirms `RelaySession` actually closed `connection`'s fd, without touching the fd number
  /// directly - `swift test` runs many suites concurrently, all opening/closing real fds, so a
  /// closed number can be reissued to unrelated code before a direct `fcntl`/`close` recheck
  /// even runs (confirmed empirically: an earlier version of this file asserted
  /// `fcntl(fd, F_GETFD) == -1` right after `RelaySession.run()` and saw it intermittently
  /// observe a *different*, concurrently-opened fd that reused the same number instead - the
  /// exact class of flakiness `RealSocketAcceptingTests` already documented for the same
  /// reason). Reading from the *peer* socket instead is race-free: an EOF there is tied to this
  /// specific connection's state, not to a globally-shared integer namespace.
  private static func expectServerObservesEOF(_ serverConnection: ConnectionHandle) async throws {
    let serverSource = RealByteSource(fileDescriptor: serverConnection.fileDescriptor)
    let result = try await serverSource.read()
    #expect(result == nil)
  }

  @Test func bytesFlowBothWaysAndEndOnCleanSocketEOF() async throws {
    try await Self.withConnectedSocketPair { clientConnection, serverConnection in
      let io = PipeStandardIO()
      let writeToStandardIn = io.writeToStandardIn
      let readFromStandardOut = io.readFromStandardOut

      async let session: Void = RelaySession.run(
        connection: clientConnection, standardIn: io.standardIn, standardOut: io.standardOut
      )

      let serverSource = RealByteSource(fileDescriptor: serverConnection.fileDescriptor)
      let serverSink = RealByteSink(fileDescriptor: serverConnection.fileDescriptor)

      try await writeToStandardIn.write(Data("ping".utf8))
      var receivedByServer = Data()
      while receivedByServer.count < 4, let chunk = try await serverSource.read() {
        receivedByServer.append(chunk)
      }
      #expect(receivedByServer == Data("ping".utf8))

      try await serverSink.write(Data("pong".utf8))
      var receivedByStandardOut = Data()
      while receivedByStandardOut.count < 4, let chunk = try await readFromStandardOut.read() {
        receivedByStandardOut.append(chunk)
      }
      #expect(receivedByStandardOut == Data("pong".utf8))

      // The server closing first is what ends the relay here - a clean socket EOF, not stdin
      // EOF or an error, so this exercises the ordinary "daemon says goodbye" path. serverSource
      // already consumed the EOF from its own close() below, so there's nothing left to
      // separately assert about the connection closing - `session` returning without hanging or
      // throwing is itself the signal.
      close(serverConnection.fileDescriptor)
      try await session

      io.closeTestEnds()
    }
  }

  @Test func stdinEOFEndsTheSessionWhileTheSocketIsStillOpen() async throws {
    try await Self.withConnectedSocketPair { clientConnection, serverConnection in
      let io = PipeStandardIO()

      // No writer ever attaches to standardIn's read end, and it's closed immediately - standardIn
      // sees EOF right away while the socket (serverConnection, still open) has nothing queued.
      // This is the case that puts a still-live `RealByteSource` on the socket side through
      // `group.cancelAll()` rather than its own natural EOF - the one `RelaySession`'s doc
      // comment flags as needing to actually close the connection fd afterward, not just leave
      // Swift-level cancellation to sort it out.
      try io.inPipe.fileHandleForWriting.close()

      try await RelaySession.run(connection: clientConnection, standardIn: io.standardIn, standardOut: io.standardOut)

      try await Self.expectServerObservesEOF(serverConnection)
      close(serverConnection.fileDescriptor)
      io.closeTestEnds()
    }
  }

  @Test func errorReadingStandardInEndsTheSessionAndPropagates() async throws {
    // A real fd-level read error isn't reliably producible via a plain pipe (mirroring why
    // RealByteStreamTests doesn't attempt one either) - FakeByteStream's deterministic error
    // injection exercises the same "does the defer's close still run, and does the original
    // error still propagate rather than get swallowed" question just as well, while the
    // connection itself stays real so the EOF check below means something.
    try await Self.withConnectedSocketPair { clientConnection, serverConnection in
      let standardIn = FakeByteStream(readError: FakeError())
      let standardOut = FakeByteStream()

      await #expect(throws: FakeError.self) {
        try await RelaySession.run(connection: clientConnection, standardIn: standardIn, standardOut: standardOut)
      }

      try await Self.expectServerObservesEOF(serverConnection)
      close(serverConnection.fileDescriptor)
    }
  }

  @Test func writingToAClosedStandardOutPropagatesAnErrorRatherThanCrashingGivenSIGPIPEIsIgnored() async throws {
    // `RelaySession` itself is only ever reached downstream of `Election.run()` returning
    // `.relay`, which ignores SIGPIPE before doing so precisely so this doesn't crash the
    // process (see `Election`'s doc comment and `ElectionTests`) - mirror that here rather than
    // relying on some other test happening to have already flipped the (process-global)
    // disposition, matching `RealByteStreamTests.writeToAClosedReadEndPropagatesAnError`'s own
    // convention for the same reason.
    signal(SIGPIPE, SIG_IGN)

    try await Self.withConnectedSocketPair { clientConnection, serverConnection in
      defer { close(serverConnection.fileDescriptor) }
      let io = PipeStandardIO()

      // Break ONLY standardOut (the editor's reader is gone) - stdin stays open and idle (no
      // EOF) and the socket stays open (no EOF either), so a broken-pipe write is the only way
      // this relay can possibly end. Closing the socket instead (as an earlier version of this
      // test did) doesn't isolate the write path: close() tears down both of the socket's
      // directions at once, so the read side reliably observes EOF and ends the relay cleanly
      // before the write side ever gets a chance to fail.
      try io.outPipe.fileHandleForReading.close()

      async let session: Void = RelaySession.run(
        connection: clientConnection, standardIn: io.standardIn, standardOut: io.standardOut
      )

      // Flood from the "daemon" side so the socket→standardOut pump has bytes to push into the
      // dead standardOut fd - a single small write may be absorbed by the pipe buffer before the
      // broken-pipe error actually surfaces (mirroring RealByteStreamTests' own note), and this
      // loop races against `session` throwing and unwinding the connection out from under it, so
      // tolerate that rather than treating it as a second failure.
      let serverSink = RealByteSink(fileDescriptor: serverConnection.fileDescriptor)
      for _ in 0..<64 {
        try? await serverSink.write(Data(repeating: 0, count: 4096))
      }

      // #expect(throws:)'s closure can't capture an `async let` variable directly, so await it
      // manually instead.
      do {
        try await session
        Issue.record("expected the broken standardOut write to end the relay with an error")
      } catch {
        // Any error is acceptable - what matters is that one was thrown rather than the process
        // crashing on SIGPIPE.
      }
    }
  }
}
