import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct RealBackendSpawningTests {
  @Test func spawnedProcessEchoesFramedMessagesBackThroughCat() async throws {
    // /bin/cat echoes its stdin to stdout verbatim - spawning it and round-tripping a message
    // through the returned channel exercises the real pipes, the Subprocess bridging, AND
    // FramedDuplexChannel's Content-Length framing together, with no fake BSP backend needed.
    try await withDependencies {
      $0.continuousClock = ImmediateClock()
    } operation: {
      let channel = try await RealBackendSpawning().spawn(argv: ["/bin/cat"], workingDirectory: "/tmp")

      let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"foo"}"#.utf8)
      try await channel.send(body)

      let received = try await channel.receive()
      #expect(received == body)
    }
  }

  @Test func spawnThrowsForAnExecutableThatDoesNotExist() async throws {
    await #expect(throws: BackendSpawnError.self) {
      _ = try await RealBackendSpawning().spawn(argv: ["/nonexistent/definitely/not/a/real/backend"], workingDirectory: "/tmp")
    }
  }

  @Test func spawnThrowsForEmptyArgv() async throws {
    await #expect(throws: BackendSpawnError.self) {
      _ = try await RealBackendSpawning().spawn(argv: [], workingDirectory: "/tmp")
    }
  }

  @Test func spawnThrowsWhenWorkingDirectoryDoesNotExist() async throws {
    // Indirectly confirms workingDirectory is actually passed through to the process rather
    // than ignored - if it were ignored, this would succeed instead of failing. Confirmed
    // empirically beforehand that Subprocess's run() does throw in this case.
    await #expect(throws: BackendSpawnError.self) {
      _ = try await RealBackendSpawning().spawn(argv: ["/bin/cat"], workingDirectory: "/nonexistent/definitely/not/a/real/directory")
    }
  }

  @Test func aProcessThatExitsRightAfterLaunchingProducesCleanEOFWithoutCrashing() async throws {
    // /usr/bin/true launches successfully and exits almost immediately - exercises the "the
    // closure ran, but the session then ended on its own" path through RealBackendSpawning's
    // launch-confirmation continuation without a double-resume (which would trap at runtime,
    // not just fail an assertion - confirmed empirically safe before writing this test).
    try await withDependencies {
      $0.continuousClock = ImmediateClock()
    } operation: {
      let channel = try await RealBackendSpawning().spawn(argv: ["/usr/bin/true"], workingDirectory: "/tmp")
      let result = try await channel.receive()
      #expect(result == nil)
    }
  }
}
