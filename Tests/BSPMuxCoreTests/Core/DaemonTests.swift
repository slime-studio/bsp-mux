import Clocks
import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct DaemonTests {
  static func request(id: String, method: String, originId: String? = nil) throws -> JSONRPCEnvelope {
    let params = originId.map { #"{"originId":"\#($0)"}"# } ?? "{}"
    let raw = Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#.utf8)
    return try JSONRPCEnvelope(rawBytes: raw)
  }

  static func notification(method: String, originId: String? = nil) throws -> JSONRPCEnvelope {
    let params = originId.map { #"{"originId":"\#($0)"}"# } ?? "{}"
    let raw = Data(#"{"jsonrpc":"2.0","method":"\#(method)","params":\#(params)}"#.utf8)
    return try JSONRPCEnvelope(rawBytes: raw)
  }

  static func response(id: String, result: String = "{}") throws -> JSONRPCEnvelope {
    let raw = Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8)
    return try JSONRPCEnvelope(rawBytes: raw)
  }

  @Test func requestGetsRewrittenIdAndResponseComesBackWithOriginalId() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)

    try await daemon.handleClientMessage(
      from: session, envelope: Self.request(id: #""abc""#, method: "buildTarget/sources"))

    let forwarded = await backend.sentMessages
    #expect(forwarded.count == 1)
    let forwardedEnvelope = try JSONRPCEnvelope(rawBytes: forwarded[0])
    #expect(forwardedEnvelope.id?.rawText != #""abc""#)  // rewritten to a daemon-minted id

    try await daemon.handleBackendMessage(envelope: Self.response(id: forwardedEnvelope.id!.rawText))

    let toClient = await clientChannel.sentMessages
    #expect(toClient.count == 1)
    let replyEnvelope = try JSONRPCEnvelope(rawBytes: toClient[0])
    #expect(replyEnvelope.id == JSONRPCRawID(rawText: #""abc""#))
  }

  @Test func twoSessionsWithCollidingClientIdsRouteToTheRightSessionIndependently() async throws {
    let backend = FakeDuplexChannel()
    let channelA = FakeDuplexChannel()
    let channelB = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let sessionA = await daemon.registerSession(channel: channelA)
    let sessionB = await daemon.registerSession(channel: channelB)

    // Both clients independently chose id 1 - exactly the collision id-rewriting exists for.
    try await daemon.handleClientMessage(from: sessionA, envelope: Self.request(id: "1", method: "foo"))
    try await daemon.handleClientMessage(from: sessionB, envelope: Self.request(id: "1", method: "foo"))

    let forwarded = await backend.sentMessages
    #expect(forwarded.count == 2)
    let backendIDs = try forwarded.map { try JSONRPCEnvelope(rawBytes: $0).id!.rawText }
    #expect(Set(backendIDs).count == 2)  // daemon minted distinct ids despite the collision

    // Respond to B's request first, then A's, to make sure routing isn't order-dependent.
    try await daemon.handleBackendMessage(envelope: Self.response(id: backendIDs[1]))
    try await daemon.handleBackendMessage(envelope: Self.response(id: backendIDs[0]))

    let toA = await channelA.sentMessages
    let toB = await channelB.sentMessages
    #expect(toA.count == 1)
    #expect(toB.count == 1)
    #expect(try JSONRPCEnvelope(rawBytes: toA[0]).id == JSONRPCRawID(rawText: "1"))
    #expect(try JSONRPCEnvelope(rawBytes: toB[0]).id == JSONRPCRawID(rawText: "1"))
  }

  @Test func unmappedBackendResponseIsDroppedNotDelivered() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    _ = await daemon.registerSession(channel: clientChannel)

    try await daemon.handleBackendMessage(envelope: Self.response(id: "999"))

    let toClient = await clientChannel.sentMessages
    #expect(toClient.isEmpty)
  }

  @Test func responseIsPrunedAfterDeliveryAndNotDeliveredTwice() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)

    try await daemon.handleClientMessage(from: session, envelope: Self.request(id: "1", method: "foo"))
    let backendID = try JSONRPCEnvelope(rawBytes: await backend.sentMessages[0]).id!.rawText

    try await daemon.handleBackendMessage(envelope: Self.response(id: backendID))
    try await daemon.handleBackendMessage(envelope: Self.response(id: backendID))  // duplicate/replayed

    let toClient = await clientChannel.sentMessages
    #expect(toClient.count == 1)
  }

  @Test func notificationCarryingKnownOriginIdRoutesOnlyToOwningSession() async throws {
    let backend = FakeDuplexChannel()
    let channelA = FakeDuplexChannel()
    let channelB = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let sessionA = await daemon.registerSession(channel: channelA)
    _ = await daemon.registerSession(channel: channelB)

    // A's request establishes ownership of originId "task-1".
    try await daemon.handleClientMessage(
      from: sessionA, envelope: Self.request(id: "1", method: "buildTarget/compile", originId: "task-1"))

    try await daemon.handleBackendMessage(envelope: Self.notification(method: "build/taskStart", originId: "task-1"))

    let toA = await channelA.sentMessages
    let toB = await channelB.sentMessages
    #expect(toA.count == 1)
    #expect(toB.isEmpty)
  }

  @Test func notificationWithoutOriginIdBroadcastsToAllSessions() async throws {
    let backend = FakeDuplexChannel()
    let channelA = FakeDuplexChannel()
    let channelB = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    _ = await daemon.registerSession(channel: channelA)
    _ = await daemon.registerSession(channel: channelB)

    try await daemon.handleBackendMessage(envelope: Self.notification(method: "buildTarget/didChange"))

    #expect(await channelA.sentMessages.count == 1)
    #expect(await channelB.sentMessages.count == 1)
  }

  @Test func notificationWithUnknownOriginIdFallsBackToBroadcast() async throws {
    // originId present but never registered by any forwarded request/notification - the
    // "default to broadcast if unmapped" case DESIGN.md calls for.
    let backend = FakeDuplexChannel()
    let channelA = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    _ = await daemon.registerSession(channel: channelA)

    try await daemon.handleBackendMessage(envelope: Self.notification(method: "build/taskStart", originId: "never-seen"))

    #expect(await channelA.sentMessages.count == 1)
  }

  @Test func buildLogMessageIsNeverForwardedToAnyClient() async throws {
    let backend = FakeDuplexChannel()
    let channelA = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    _ = await daemon.registerSession(channel: channelA)

    try await daemon.handleBackendMessage(envelope: Self.notification(method: "build/logMessage"))

    #expect(await channelA.sentMessages.isEmpty)
  }

  @Test func customVendorMethodRequestFlowsThroughEndToEnd() async throws {
    // The whole point of the raw-envelope transport: a method neither BuildServerProtocol nor
    // this daemon has ever heard of still gets id-rewritten, forwarded, and demuxed correctly.
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)

    try await daemon.handleClientMessage(
      from: session, envelope: Self.request(id: #""x""#, method: "sourcekit-xcode-bsp/customVendorMethod"))

    let forwardedEnvelope = try JSONRPCEnvelope(rawBytes: await backend.sentMessages[0])
    #expect(forwardedEnvelope.method == "sourcekit-xcode-bsp/customVendorMethod")

    try await daemon.handleBackendMessage(
      envelope: Self.response(id: forwardedEnvelope.id!.rawText, result: #"{"custom":"payload"}"#))

    let reply = try JSONRPCEnvelope(rawBytes: await clientChannel.sentMessages[0])
    #expect(reply.id == JSONRPCRawID(rawText: #""x""#))
  }

  @Test func customVendorNotificationWithOriginIdRoutesCorrectly() async throws {
    let backend = FakeDuplexChannel()
    let channelA = FakeDuplexChannel()
    let channelB = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let sessionA = await daemon.registerSession(channel: channelA)
    _ = await daemon.registerSession(channel: channelB)

    try await daemon.handleClientMessage(
      from: sessionA,
      envelope: Self.request(id: "1", method: "sourcekit-xcode-bsp/vendorRequest", originId: "vendor-task"))
    try await daemon.handleBackendMessage(
      envelope: Self.notification(method: "sourcekit-xcode-bsp/vendorProgress", originId: "vendor-task"))

    #expect(await channelA.sentMessages.count == 1)
    #expect(await channelB.sentMessages.isEmpty)
  }

  @Test func messageFromDeregisteredSessionIsDroppedWithoutThrowing() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()

    // deregisterSession now starts the idle grace timer, which reads @Dependency(\.continuousClock) -
    // a TestClock that's never advanced keeps that timer from ever firing during this test.
    try await withDependencies {
      $0.continuousClock = TestClock()
    } operation: {
      let daemon = Daemon(backend: backend)
      let session = await daemon.registerSession(channel: clientChannel)
      await daemon.deregisterSession(session)

      try await daemon.handleClientMessage(from: session, envelope: Self.request(id: "1", method: "foo"))
    }

    #expect(await backend.sentMessages.isEmpty)
  }

  @Test func backendDisconnectedFailsInFlightRequestsAcrossEverySessionAndResolvesShutdown() async throws {
    let backend = FakeDuplexChannel()
    let channelA = FakeDuplexChannel()
    let channelB = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let sessionA = await daemon.registerSession(channel: channelA)
    let sessionB = await daemon.registerSession(channel: channelB)

    try await daemon.handleClientMessage(from: sessionA, envelope: Self.request(id: #""abc""#, method: "buildTarget/sources"))
    try await daemon.handleClientMessage(from: sessionB, envelope: Self.request(id: #""xyz""#, method: "buildTarget/compile"))
    #expect(await backend.sentMessages.count == 2)  // both in flight, backend never answers either

    async let shutdown: Void = daemon.waitForShutdown()
    await daemon.handleBackendDisconnected()
    await shutdown

    let toA = await channelA.sentMessages
    let toB = await channelB.sentMessages
    #expect(toA.count == 1)
    #expect(toB.count == 1)
    let replyA = try JSONRPCEnvelope(rawBytes: toA[0])
    let replyB = try JSONRPCEnvelope(rawBytes: toB[0])
    #expect(replyA.id == JSONRPCRawID(rawText: #""abc""#))
    #expect(replyB.id == JSONRPCRawID(rawText: #""xyz""#))
    let replyAString = String(bytes: replyA.rawBytes, encoding: .utf8)
    let replyBString = String(bytes: replyB.rawBytes, encoding: .utf8)
    #expect(replyAString?.contains(#""error""#) == true)
    #expect(replyBString?.contains(#""error""#) == true)
  }

  @Test func requestForcedShutdownFailsInFlightRequestsAndRecordsWhetherHardKillWasWanted() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)

    try await daemon.handleClientMessage(from: session, envelope: Self.request(id: #""abc""#, method: "buildTarget/sources"))
    #expect(await backend.sentMessages.count == 1)

    #expect(await daemon.forcedShutdown == .none)
    async let shutdown: Void = daemon.waitForShutdown()
    await daemon.requestForcedShutdown(hardKill: true)
    await shutdown

    #expect(await daemon.forcedShutdown == .requested(hardKill: true))
    let toClient = await clientChannel.sentMessages
    #expect(toClient.count == 1)
    let replyString = try String(bytes: JSONRPCEnvelope(rawBytes: toClient[0]).rawBytes, encoding: .utf8)
    #expect(replyString?.contains(#""error""#) == true)
  }

  @Test func bspMuxStopMessageDispatchesToRequestForcedShutdownWithTheRequestedForceFlag() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)

    let stopMessage = try JSONRPCEnvelope(
      rawBytes: Data(#"{"jsonrpc":"2.0","method":"bspMux/stop","params":{"force":true}}"#.utf8))
    async let shutdown: Void = daemon.waitForShutdown()
    try await daemon.handleClientMessage(from: session, envelope: stopMessage)
    await shutdown

    #expect(await daemon.forcedShutdown == .requested(hardKill: true))
  }

  @Test func bspMuxStopMessageWithoutForceRequestsAGracefulSignal() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)

    let stopMessage = try JSONRPCEnvelope(
      rawBytes: Data(#"{"jsonrpc":"2.0","method":"bspMux/stop","params":{"force":false}}"#.utf8))
    async let shutdown: Void = daemon.waitForShutdown()
    try await daemon.handleClientMessage(from: session, envelope: stopMessage)
    await shutdown

    #expect(await daemon.forcedShutdown == .requested(hardKill: false))
  }

  @Test func backendDisconnectedFailsAnInFlightInitializeRoundTrip() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)

    // handleClientMessage suspends inside handleInitialize awaiting the backend's answer, so
    // drive it from a concurrent task and let handleBackendDisconnected resolve it instead of
    // ever getting a real response. Mirrors DaemonLifecycleTests' own
    // singleClientInitializeForwardsOnceAndCachesTheResponse, which relies on the same
    // sentMessages-non-empty checkpoint to know the pending continuation is actually in place.
    async let initializeCall: Void = {
      do {
        try await daemon.handleClientMessage(from: session, envelope: Self.request(id: "1", method: "build/initialize"))
      } catch {
        // Expected: the backend disconnecting fails this in-flight round trip.
      }
    }()

    _ = await backend.waitForNextSentMessage()
    await daemon.handleBackendDisconnected()
    await initializeCall

    // No response was ever sent to the client for this request - it's the pending Task's own
    // continuation that fails, not something surfaced through the normal reply path (the client
    // finds out because the whole daemon is exiting right after, per handleBackendDisconnected's
    // doc comment).
    #expect(await clientChannel.sentMessages.isEmpty)
  }

  @Test func backendDisconnectedIsIdempotent() async throws {
    let backend = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)

    await daemon.handleBackendDisconnected()
    await daemon.handleBackendDisconnected()  // must not double-resume waitForShutdown's continuations

    await daemon.waitForShutdown()
  }
}
