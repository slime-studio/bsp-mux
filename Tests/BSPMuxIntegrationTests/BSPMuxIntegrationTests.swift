import BSPMuxCore
import Dependencies
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Real-subprocess integration tests - `BSPMuxCoreTests` already covers all of this logic against
/// fakes; this suite exists specifically for the guarantees that only mean anything across real
/// OS processes (`Election`'s `flock`/`connect` race, a second `bsp-mux run` really becoming a
/// relay, closing one client's real stdin only affecting that one process). Covers all eight of
/// DESIGN.md's integration scenarios - the last two (`originId`-routed and broadcast
/// notifications) drive `raw-bytes-bsp-backend` rather than `fake-bsp-backend`, since they need
/// the backend to spontaneously emit a notification carrying a raw `originId` field (or not),
/// which `fake-bsp-backend`'s typed `BuildServerProtocol` decode/encode has no way to represent.
///
/// `.serialized`: every scenario below counts real backend processes system-wide via
/// `BackendProcesses.pids()`, which would see another concurrently-running scenario's own
/// backend too - Swift Testing parallelizes `@Test`s in a suite by default, so without this the
/// count-based assertions would be flaky despite each scenario being individually correct.
@Suite(.serialized) struct BSPMuxIntegrationTests {
  private static func makeWorkspace() throws -> String {
    let path = FileManager.default.temporaryDirectory.appending(path: "bsp-mux-integration-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  private static func initializeRequest(id: String) -> Data {
    let json =
      #"{"jsonrpc":"2.0","id":"\#(id)","method":"build/initialize","params":{"displayName":"editor","version":"1.0","#
      + #""bspVersion":"2.1.0","rootUri":"file:///workspace","capabilities":{"languageIds":["swift"]}}}"#
    return Data(json.utf8)
  }

  private static func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func twoClientsConvergeOnOneBackendAndOneRealHandshake() async throws {
    let workspace = try Self.makeWorkspace()
    defer { try? FileManager.default.removeItem(atPath: workspace) }

    let clientA = try SimulatedClient.launch(workspaceRoot: workspace, backendArgv: [BinaryLocator.fakeBSPBackend.path])
    let clientB = try SimulatedClient.launch(workspaceRoot: workspace, backendArgv: [BinaryLocator.fakeBSPBackend.path])
    // Not a graceful wait: neither client's own natural shutdown is what this scenario tests,
    // and the winner's is gated behind the real 5s idle-grace period - worth paying exactly once,
    // in the one scenario that specifically tests that path.
    defer {
      clientA.forceKillIfRunning()
      clientB.forceKillIfRunning()
    }

    try await clientA.send(Self.initializeRequest(id: "a"))
    let responseA = try #require(try await clientA.receive())
    let objectA = try Self.jsonObject(responseA)
    #expect((objectA["result"] as? [String: Any])?["displayName"] as? String == "fake-bsp-backend")

    try await clientB.send(Self.initializeRequest(id: "b"))
    let responseB = try #require(try await clientB.receive())
    let objectB = try Self.jsonObject(responseB)
    #expect((objectB["result"] as? [String: Any])?["displayName"] as? String == "fake-bsp-backend")

    #expect(BackendProcesses.pids().count == 1)
  }

  @Test func closingOneClientLeavesTheOtherWorking() async throws {
    let workspace = try Self.makeWorkspace()
    defer { try? FileManager.default.removeItem(atPath: workspace) }

    // Launched first -> wins the election -> becomes the daemon.
    let winner = try SimulatedClient.launch(workspaceRoot: workspace, backendArgv: [BinaryLocator.fakeBSPBackend.path])
    try await winner.send(Self.initializeRequest(id: "1"))
    _ = try #require(try await winner.receive())

    // Launched second -> relays to the winner instead of becoming a second daemon.
    let relay = try SimulatedClient.launch(workspaceRoot: workspace, backendArgv: [BinaryLocator.fakeBSPBackend.path])
    try await relay.send(Self.initializeRequest(id: "2"))
    _ = try #require(try await relay.receive())

    relay.closeStdin()
    #expect(relay.waitForExit() != nil)

    // The daemon (winner) must still be alive and responsive after the relay disconnected.
    let secondRequest = Data(#"{"jsonrpc":"2.0","id":"3","method":"workspace/buildTargets","params":{}}"#.utf8)
    try await winner.send(secondRequest)
    let secondResponse = try #require(try await winner.receive())
    let secondObject = try Self.jsonObject(secondResponse)
    #expect((secondObject["result"] as? [String: Any])?["targets"] is [Any])

    winner.forceKillIfRunning()
  }

  @Test func closingTheLastClientTearsDownDaemonAndBackendThenAFreshClientReElects() async throws {
    let workspace = try Self.makeWorkspace()
    defer { try? FileManager.default.removeItem(atPath: workspace) }

    let client = try SimulatedClient.launch(workspaceRoot: workspace, backendArgv: [BinaryLocator.fakeBSPBackend.path])
    try await client.send(Self.initializeRequest(id: "1"))
    _ = try #require(try await client.receive())
    #expect(BackendProcesses.pids().count == 1)

    // Idle-grace period is a real 5s on the real clock - DaemonBootstrap.start doesn't expose an
    // override, and adding one just for this test isn't worth the production-code surface it'd
    // need. Accepted cost of testing this property for real.
    client.closeStdin()
    #expect(client.waitForExit(timeoutSeconds: 10) != nil)
    #expect(BackendProcesses.pids().isEmpty)

    // A fresh client for the *same* project must be able to become daemon again - proves
    // teardown was actually complete, not just that the client's own process exited.
    let freshClient = try SimulatedClient.launch(workspaceRoot: workspace, backendArgv: [BinaryLocator.fakeBSPBackend.path])
    defer { freshClient.forceKillIfRunning() }
    try await freshClient.send(Self.initializeRequest(id: "2"))
    let response = try #require(try await freshClient.receive())
    let object = try Self.jsonObject(response)
    #expect((object["result"] as? [String: Any])?["displayName"] as? String == "fake-bsp-backend")
  }

  @Test func backendKilledMidSessionFailsInFlightRequestsPromptlyRatherThanHanging() async throws {
    let workspace = try Self.makeWorkspace()
    defer { try? FileManager.default.removeItem(atPath: workspace) }

    let client = try SimulatedClient.launch(workspaceRoot: workspace, backendArgv: [BinaryLocator.fakeBSPBackend.path])
    defer { client.forceKillIfRunning() }
    try await client.send(Self.initializeRequest(id: "1"))
    _ = try #require(try await client.receive())

    let inFlightRequest = Data(#"{"jsonrpc":"2.0","id":"2","method":"workspace/buildTargets","params":{}}"#.utf8)
    try await client.send(inFlightRequest)

    let backendPID = try #require(BackendProcesses.pids().first)
    kill(backendPID, SIGKILL)

    // The specific outcome doesn't matter - `Daemon.handleBackendDisconnected()` sends an error
    // response for every pending request before it tears the process down, so this should
    // usually see that error response, but a race where the process exits first (a clean channel
    // end) is just as much "not hanging". What actually matters, and what this asserts, is
    // *when* it happens: well before the 5s bound, not "eventually gave up at the bound", which
    // would indicate the hang this test exists to catch.
    let start = Date()
    _ = try? await client.receive(timeoutSeconds: 5)
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 3)
  }

  @Test func aStaleSocketFileWithNoListenerIsDetectedAndCleanedUp() async throws {
    let workspace = try Self.makeWorkspace()
    defer { try? FileManager.default.removeItem(atPath: workspace) }
    let backendArgv = [BinaryLocator.fakeBSPBackend.path]

    // `ProjectKey`'s init reads `@Dependency(\.fileSystem)` internally, and swift-dependencies
    // refuses to resolve to a live value from inside any test process (confirmed empirically -
    // this traps without the override, even with no `withDependencies` scope active anywhere
    // else). `RealFileSystem` explicitly, not a fake: this needs to compute the exact same path
    // the separately-spawned `bsp-mux` subprocess will independently compute for itself.
    let paths = withDependencies {
      $0.fileSystem = RealFileSystem()
    } operation: {
      ProjectPaths(key: ProjectKey(workspaceRoot: workspace, backendArgv: backendArgv))
    }
    try paths.ensureBaseDirectoryExists()
    // A genuine bound-and-listening AF_UNIX socket, abandoned without unlinking - what a crashed
    // prior daemon actually leaves behind (confirmed empirically: a plain non-socket file at this
    // path makes the real `connect()` fail with `ENOTSOCK`, which `RealElectionEnvironment`
    // treats as a real error rather than "no listener", unlike `ECONNREFUSED`/`ENOENT` - a
    // narrower gap than this scenario is testing, not fixed here, but worth remembering: this
    // path only recovers from an abandoned *socket*, not literally any leftover file).
    let staleListening = try RealElectionEnvironment().listen(at: paths.socketPath)
    close(staleListening.fileDescriptor)

    let client = try SimulatedClient.launch(workspaceRoot: workspace, backendArgv: backendArgv)
    defer { client.forceKillIfRunning() }
    try await client.send(Self.initializeRequest(id: "1"))
    let response = try #require(try await client.receive())
    let object = try Self.jsonObject(response)
    #expect((object["result"] as? [String: Any])?["displayName"] as? String == "fake-bsp-backend")
  }

  /// Plain `actor`, not a captured `var`: the monitor task and the spawning task group both
  /// touch this concurrently, and `Task`'s closures are `@Sendable` - a captured local `var`
  /// doesn't satisfy the compiler (hit this exact error writing `FakeBSPBackendTests` too).
  private actor MaxCounter {
    private(set) var maxValue = 0
    func observe(_ value: Int) { maxValue = max(maxValue, value) }
  }

  @Test func rapidSpawnCloseChurnNeverProducesMoreThanOneLiveBackend() async throws {
    let workspace = try Self.makeWorkspace()
    defer { try? FileManager.default.removeItem(atPath: workspace) }
    let backendArgv = [BinaryLocator.fakeBSPBackend.path]

    let counter = MaxCounter()
    let monitor = Task {
      while !Task.isCancelled {
        await counter.observe(BackendProcesses.pids().count)
        try? await Task.sleep(for: .milliseconds(50))
      }
    }

    // A task group, not a sequential loop: genuine overlap between clients is the whole point of
    // "rapid churn" - a loop that waits for each client's own round trip before starting the
    // next would never actually create concurrent elections to stress.
    let clients = try await withThrowingTaskGroup(of: SimulatedClient.self) { group in
      for index in 0..<20 {
        group.addTask {
          let client = try SimulatedClient.launch(workspaceRoot: workspace, backendArgv: backendArgv)
          try await client.send(Self.initializeRequest(id: "\(index)"))
          _ = try? await client.receive(timeoutSeconds: 5)
          client.closeStdin()
          return client
        }
      }
      var results: [SimulatedClient] = []
      for try await client in group { results.append(client) }
      return results
    }

    monitor.cancel()
    let maxObservedCount = await counter.maxValue

    // Whichever client won the election is still alive at this point - its own natural exit is
    // gated behind the real 5s idle-grace period, and leaving it running would leak into the
    // *next* test (or the next `swift test` invocation entirely) via `BackendProcesses.pids()`,
    // which sees every `fake-bsp-backend` process system-wide - confirmed empirically as a real,
    // consistent flake source (`pids().count` seeing 2, not 1) when this wasn't force-killed.
    for client in clients { client.forceKillIfRunning() }

    #expect(maxObservedCount <= 1)
  }

  // MARK: - originId-routed / broadcast notifications (raw-bytes-bsp-backend)

  /// Assertions below are deliberately content-based, not position-based:
  /// `Daemon.routeBackendNotification` iterates a `Dictionary` (unspecified order) and a
  /// session's own reply arrives via a fully separate code path from a routed/broadcast
  /// notification, so nothing guarantees which of the two a client observes first.
  @Test func originIdRoutedNotificationReachesOnlyTheRequestingClient() async throws {
    let workspace = try Self.makeWorkspace()
    defer { try? FileManager.default.removeItem(atPath: workspace) }
    let backendArgv = [BinaryLocator.rawBytesBSPBackend.path]

    let clientA = try SimulatedClient.launch(workspaceRoot: workspace, backendArgv: backendArgv)
    let clientB = try SimulatedClient.launch(workspaceRoot: workspace, backendArgv: backendArgv)
    defer {
      clientA.forceKillIfRunning()
      clientB.forceKillIfRunning()
    }
    try await clientA.send(Self.initializeRequest(id: "a"))
    _ = try #require(try await clientA.receive())
    try await clientB.send(Self.initializeRequest(id: "b"))
    _ = try #require(try await clientB.receive())

    let triggerJSON =
      #"{"jsonrpc":"2.0","id":"2","method":"test/emitNotification","params":{"originId":"task-1","#
      + #""notificationMethod":"build/taskStart","notificationParams":{"originId":"task-1"}}}"#
    let trigger = Data(triggerJSON.utf8)
    try await clientA.send(trigger)

    var sawNotification = false
    var sawReply = false
    for _ in 0..<2 {
      let object = try Self.jsonObject(try #require(try await clientA.receive()))
      if object["method"] as? String == "build/taskStart" { sawNotification = true }
      if object["id"] as? String == "2" { sawReply = true }
    }
    #expect(sawNotification)
    #expect(sawReply)

    await #expect(throws: TimeoutError.self) {
      _ = try await clientB.receive(timeoutSeconds: 1)
    }
  }

  @Test func notificationWithoutOriginIdBroadcastsToAllConnectedClients() async throws {
    let workspace = try Self.makeWorkspace()
    defer { try? FileManager.default.removeItem(atPath: workspace) }
    let backendArgv = [BinaryLocator.rawBytesBSPBackend.path]

    let clientA = try SimulatedClient.launch(workspaceRoot: workspace, backendArgv: backendArgv)
    let clientB = try SimulatedClient.launch(workspaceRoot: workspace, backendArgv: backendArgv)
    defer {
      clientA.forceKillIfRunning()
      clientB.forceKillIfRunning()
    }
    try await clientA.send(Self.initializeRequest(id: "a"))
    _ = try #require(try await clientA.receive())
    try await clientB.send(Self.initializeRequest(id: "b"))
    _ = try #require(try await clientB.receive())

    let triggerJSON =
      #"{"jsonrpc":"2.0","id":"2","method":"test/emitNotification","params":{"notificationMethod":"buildTarget/didChange","#
      + #""notificationParams":{}}}"#
    let trigger = Data(triggerJSON.utf8)
    try await clientA.send(trigger)

    var sawNotification = false
    var sawReply = false
    for _ in 0..<2 {
      let object = try Self.jsonObject(try #require(try await clientA.receive()))
      if object["method"] as? String == "buildTarget/didChange" { sawNotification = true }
      if object["id"] as? String == "2" { sawReply = true }
    }
    #expect(sawNotification)
    #expect(sawReply)

    let bMessage = try Self.jsonObject(try #require(try await clientB.receive()))
    #expect(bMessage["method"] as? String == "buildTarget/didChange")
  }
}
