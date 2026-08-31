import Clocks
import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct ClientSessionLoopTests {
  @Test func processesEveryQueuedMessageThenDeregistersOnCleanEOF() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let clock = TestClock()

    await withDependencies {
      $0.continuousClock = clock
    } operation: {
      let daemon = Daemon(backend: backend, idleGracePeriod: .seconds(5))

      // DuplexChannel.receive() already vends complete message bodies (framing is
      // FramedDuplexChannel's own concern, one layer below this) - FakeDuplexChannel matches
      // that contract directly, no MessageFraming.frame(_:) needed here.
      let requestData = Data(#"{"jsonrpc":"2.0","id":"1","method":"buildTarget/sources","params":{}}"#.utf8)
      await clientChannel.enqueueIncoming(requestData)
      // FakeDuplexChannel.receive() returns nil once its queue drains - a clean EOF, ending the
      // loop, with nothing further to enqueue.

      await ClientSessionLoop.run(daemon: daemon, channel: clientChannel)

      #expect(await backend.sentMessages.count == 1)  // the session's message actually reached the daemon

      // Also confirm the loop ending actually deregistered the session - see the sibling test
      // below for why the idle-timer-fires check is the unambiguous way to prove that.
      await clock.advance(by: .seconds(5))
      await daemon.waitForShutdown()
      #expect(await backend.sentMessages.count == 3)  // the original message, then shutdown, then exit
    }
  }

  @Test func deregistersEvenWhenReceiveThrows() async throws {
    struct FakeError: Swift.Error, Equatable {}
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel(readError: FakeError())
    let clock = TestClock()

    try await withDependencies {
      $0.continuousClock = clock
    } operation: {
      let daemon = Daemon(backend: backend, idleGracePeriod: .seconds(5))

      await ClientSessionLoop.run(daemon: daemon, channel: clientChannel)

      // deregisterSession only starts the idle grace timer once the session count actually
      // reaches zero - the real backend shutdown/exit firing once that timer elapses is
      // unambiguous proof deregistration actually happened (not just that the loop returned),
      // mirroring DaemonLifecycleTests.idleTimerFiresAfterGracePeriodAndSendsRealShutdown.
      await clock.advance(by: .seconds(5))
      await daemon.waitForShutdown()

      let sent = await backend.sentMessages
      #expect(sent.count == 2)
      let shutdownEnvelope = try JSONRPCEnvelope(rawBytes: sent[0])
      let exitEnvelope = try JSONRPCEnvelope(rawBytes: sent[1])
      #expect(shutdownEnvelope.method == "build/shutdown")
      #expect(exitEnvelope.method == "build/exit")
    }
  }
}
