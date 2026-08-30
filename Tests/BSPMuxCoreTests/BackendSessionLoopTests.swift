import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct BackendSessionLoopTests {
  @Test func routesEveryQueuedBackendMessageThenTreatsCleanEOFAsDisconnection() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)

    try await daemon.handleClientMessage(
      from: session,
      envelope: try JSONRPCEnvelope(rawBytes: Data(#"{"jsonrpc":"2.0","id":"1","method":"foo","params":{}}"#.utf8))
    )
    let backendRequestID = try JSONRPCEnvelope(rawBytes: await backend.sentMessages[0]).id!.rawText
    let responseData = Data(#"{"jsonrpc":"2.0","id":"\#(backendRequestID)","result":{}}"#.utf8)
    await backend.enqueueIncoming(responseData)
    // FakeDuplexChannel.receive() returns nil once its queue drains - a clean EOF, ending the
    // loop, exactly like the backend process exiting cleanly.

    await BackendSessionLoop.run(daemon: daemon, backend: backend)

    #expect(await clientChannel.sentMessages.count == 1)  // the routed response actually reached the client

    // A clean EOF still means the backend connection is gone - confirm it's treated as a real
    // disconnect (handleBackendDisconnected was called), via the same unambiguous signal
    // DaemonTests.backendDisconnectedFailsInFlightRequestsAndResolvesShutdown relies on:
    // waitForShutdown() resolving.
    await daemon.waitForShutdown()
  }

  @Test func transportErrorEndingTheLoopStillTriggersDisconnection() async throws {
    struct FakeError: Swift.Error, Equatable {}
    let backend = FakeDuplexChannel(readError: FakeError())
    let daemon = Daemon(backend: backend)

    await BackendSessionLoop.run(daemon: daemon, backend: backend)

    await daemon.waitForShutdown()
  }
}
