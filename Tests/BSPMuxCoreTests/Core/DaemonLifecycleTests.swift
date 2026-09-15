import Clocks
import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct DaemonLifecycleTests {
  static func initializeRequest(
    id: String, displayName: String = "editor", version: String = "1.0",
    bspVersion: String = "2.1.0", rootUri: String = "file:///workspace",
    capabilities: String = #"{"languageIds":["swift"]}"#
  ) throws -> JSONRPCEnvelope {
    let json = """
      {"jsonrpc":"2.0","id":\(id),"method":"build/initialize","params":{"displayName":"\(displayName)",\
      "version":"\(version)","bspVersion":"\(bspVersion)","rootUri":"\(rootUri)","capabilities":\(capabilities)}}
      """
    return try JSONRPCEnvelope(rawBytes: Data(json.utf8))
  }

  static func initializeResponse(id: String) throws -> JSONRPCEnvelope {
    let json = #"{"jsonrpc":"2.0","id":\#(id),"result":{"displayName":"backend","version":"1.0","bspVersion":"2.1.0","capabilities":{}}}"#
    return try JSONRPCEnvelope(rawBytes: Data(json.utf8))
  }

  static func initializedNotification() throws -> JSONRPCEnvelope {
    try JSONRPCEnvelope(rawBytes: Data(#"{"jsonrpc":"2.0","method":"build/initialized","params":{}}"#.utf8))
  }

  static func shutdownRequest(id: String) throws -> JSONRPCEnvelope {
    try JSONRPCEnvelope(rawBytes: Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"build/shutdown"}"#.utf8))
  }

  static func exitNotification() throws -> JSONRPCEnvelope {
    try JSONRPCEnvelope(rawBytes: Data(#"{"jsonrpc":"2.0","method":"build/exit"}"#.utf8))
  }

  // MARK: - build/initialize

  @Test func singleClientInitializeForwardsOnceAndCachesTheResponse() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)

    // handleClientMessage doesn't return for build/initialize until the backend responds, so
    // it has to run concurrently with observing/answering it - unlike a generic forwarded
    // request, which is fire-and-forget from handleClientMessage's point of view.
    async let call: Void = daemon.handleClientMessage(from: session, envelope: try Self.initializeRequest(id: #""abc""#))
    let forwardedBytes = await backend.waitForNextSentMessage()

    #expect(await backend.sentMessages.count == 1)
    let forwardedEnvelope = try JSONRPCEnvelope(rawBytes: forwardedBytes)
    #expect(forwardedEnvelope.id?.rawText != #""abc""#)  // rewritten to a daemon-minted id

    try await daemon.handleBackendMessage(envelope: Self.initializeResponse(id: forwardedEnvelope.id!.rawText))
    _ = try await call

    let toClient = await clientChannel.sentMessages
    #expect(toClient.count == 1)
    #expect(try JSONRPCEnvelope(rawBytes: toClient[0]).id == JSONRPCRawID(rawText: #""abc""#))
  }

  @Test func twoConcurrentInitializesOnlyOneReachesBackendBothGetReplies() async throws {
    let backend = FakeDuplexChannel()
    let channelA = FakeDuplexChannel()
    let channelB = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let sessionA = await daemon.registerSession(channel: channelA)
    let sessionB = await daemon.registerSession(channel: channelB)

    // Both calls are made concurrently and don't return until the backend responds - the
    // whole point of this test is that A's call is still suspended when B's arrives.
    async let callA: Void = daemon.handleClientMessage(from: sessionA, envelope: try Self.initializeRequest(id: #""a""#))
    let forwardedBytes = await backend.waitForNextSentMessage()
    async let callB: Void = daemon.handleClientMessage(from: sessionB, envelope: try Self.initializeRequest(id: #""b""#))

    #expect(await backend.sentMessages.count == 1)  // B never triggered a second real request
    let backendID = try JSONRPCEnvelope(rawBytes: forwardedBytes).id!.rawText

    try await daemon.handleBackendMessage(envelope: Self.initializeResponse(id: backendID))
    _ = try await callA
    _ = try await callB

    let toA = await channelA.sentMessages
    let toB = await channelB.sentMessages
    #expect(toA.count == 1)
    #expect(toB.count == 1)
    #expect(try JSONRPCEnvelope(rawBytes: toA[0]).id == JSONRPCRawID(rawText: #""a""#))
    #expect(try JSONRPCEnvelope(rawBytes: toB[0]).id == JSONRPCRawID(rawText: #""b""#))
  }

  @Test func mismatchedCapabilitiesGetsErrorNotCachedResponse() async throws {
    let backend = FakeDuplexChannel()
    let channelA = FakeDuplexChannel()
    let channelB = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let sessionA = await daemon.registerSession(channel: channelA)
    let sessionB = await daemon.registerSession(channel: channelB)

    async let callA: Void = daemon.handleClientMessage(
      from: sessionA, envelope: try Self.initializeRequest(id: "1", capabilities: #"{"languageIds":["swift"]}"#))
    let forwardedBytes = await backend.waitForNextSentMessage()
    async let callB: Void = daemon.handleClientMessage(
      from: sessionB, envelope: try Self.initializeRequest(id: "2", capabilities: #"{"languageIds":["swift","c"]}"#))

    let backendID = try JSONRPCEnvelope(rawBytes: forwardedBytes).id!.rawText
    try await daemon.handleBackendMessage(envelope: Self.initializeResponse(id: backendID))
    _ = try await callA
    _ = try await callB

    let toA = try JSONRPCEnvelope(rawBytes: await channelA.sentMessages[0])
    let bBytes = await channelB.sentMessages[0]
    #expect(toA.id == JSONRPCRawID(rawText: "1"))

    let bText = String(bytes: bBytes, encoding: .utf8)!
    #expect(bText.contains(#""error""#))
    #expect(bText.contains("-32000"))
    #expect(try JSONRPCEnvelope(rawBytes: bBytes).id == JSONRPCRawID(rawText: "2"))
  }

  @Test func differingDisplayNameAndVersionDoNotCauseMismatch() async throws {
    let backend = FakeDuplexChannel()
    let channelA = FakeDuplexChannel()
    let channelB = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let sessionA = await daemon.registerSession(channel: channelA)
    let sessionB = await daemon.registerSession(channel: channelB)

    async let callA: Void = daemon.handleClientMessage(
      from: sessionA, envelope: try Self.initializeRequest(id: "1", displayName: "EditorA", version: "1.0"))
    let forwardedBytes = await backend.waitForNextSentMessage()
    async let callB: Void = daemon.handleClientMessage(
      from: sessionB, envelope: try Self.initializeRequest(id: "2", displayName: "EditorB", version: "9.9"))

    let backendID = try JSONRPCEnvelope(rawBytes: forwardedBytes).id!.rawText
    try await daemon.handleBackendMessage(envelope: Self.initializeResponse(id: backendID))
    _ = try await callA
    _ = try await callB

    let bText = String(bytes: await channelB.sentMessages[0], encoding: .utf8)!
    #expect(!bText.contains(#""error""#))
  }

  @Test func lateClientAfterCompletionGetsImmediateReplyNoNewBackendRequest() async throws {
    let backend = FakeDuplexChannel()
    let channelA = FakeDuplexChannel()
    let channelLate = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let sessionA = await daemon.registerSession(channel: channelA)
    let sessionLate = await daemon.registerSession(channel: channelLate)

    async let callA: Void = daemon.handleClientMessage(from: sessionA, envelope: try Self.initializeRequest(id: "1"))
    let backendID = try JSONRPCEnvelope(rawBytes: await backend.waitForNextSentMessage()).id!.rawText
    try await daemon.handleBackendMessage(envelope: Self.initializeResponse(id: backendID))
    _ = try await callA

    try await daemon.handleClientMessage(from: sessionLate, envelope: Self.initializeRequest(id: #""late""#))

    #expect(await backend.sentMessages.count == 1)  // no second real request
    let toLate = try JSONRPCEnvelope(rawBytes: await channelLate.sentMessages[0])
    #expect(toLate.id == JSONRPCRawID(rawText: #""late""#))
  }

  // MARK: - build/initialized

  @Test func initializedForwardedOnceThenSwallowed() async throws {
    let backend = FakeDuplexChannel()
    let channelA = FakeDuplexChannel()
    let channelB = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let sessionA = await daemon.registerSession(channel: channelA)
    let sessionB = await daemon.registerSession(channel: channelB)

    try await daemon.handleClientMessage(from: sessionA, envelope: Self.initializedNotification())
    try await daemon.handleClientMessage(from: sessionB, envelope: Self.initializedNotification())

    #expect(await backend.sentMessages.count == 1)
  }

  // MARK: - build/shutdown / build/exit

  @Test func shutdownGetsImmediateSynthesizedResponseNeverTouchesBackend() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let daemon = Daemon(backend: backend)
    let session = await daemon.registerSession(channel: clientChannel)

    try await daemon.handleClientMessage(from: session, envelope: Self.shutdownRequest(id: "1"))

    #expect(await backend.sentMessages.isEmpty)
    let reply = try JSONRPCEnvelope(rawBytes: await clientChannel.sentMessages[0])
    #expect(reply.id == JSONRPCRawID(rawText: "1"))
  }

  // MARK: - Refcount / idle grace period

  @Test func idleTimerFiresAfterGracePeriodAndSendsRealShutdown() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let clock = TestClock()

    try await withDependencies {
      $0.continuousClock = clock
    } operation: {
      let daemon = Daemon(backend: backend, idleGracePeriod: .seconds(5))
      let session = await daemon.registerSession(channel: clientChannel)
      try? await daemon.handleClientMessage(from: session, envelope: Self.exitNotification())

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

  @Test func newSessionCancelsThePendingIdleTimer() async throws {
    let backend = FakeDuplexChannel()
    let channelA = FakeDuplexChannel()
    let channelB = FakeDuplexChannel()
    let clock = TestClock()

    await withDependencies {
      $0.continuousClock = clock
    } operation: {
      let daemon = Daemon(backend: backend, idleGracePeriod: .seconds(5))
      let sessionA = await daemon.registerSession(channel: channelA)
      try? await daemon.handleClientMessage(from: sessionA, envelope: Self.exitNotification())

      // A new session registers before the grace period elapses.
      _ = await daemon.registerSession(channel: channelB)

      await clock.advance(by: .seconds(5))
      #expect(await backend.sentMessages.isEmpty)
    }
  }

  @Test func waitForShutdownReturnsImmediatelyIfAlreadyShutDown() async throws {
    let backend = FakeDuplexChannel()
    let clientChannel = FakeDuplexChannel()
    let clock = TestClock()

    await withDependencies {
      $0.continuousClock = clock
    } operation: {
      let daemon = Daemon(backend: backend, idleGracePeriod: .seconds(1))
      let session = await daemon.registerSession(channel: clientChannel)
      try? await daemon.handleClientMessage(from: session, envelope: Self.exitNotification())

      await clock.advance(by: .seconds(1))
      await daemon.waitForShutdown()

      // Already shut down - this should resolve immediately, not hang.
      await daemon.waitForShutdown()
    }
  }
}
