import Dependencies
import Testing

@testable import BSPMuxCore

@Suite struct LoggingTests {
  @Test func fakeRecordsMessagesInOrderWithTheirLevel() {
    let logger = FakeLogging()

    logger.log(.info, "session registered")
    logger.log(.error, "backend connection lost")

    #expect(
      logger.messages == [
        LoggedMessage(level: .info, message: "session registered"),
        LoggedMessage(level: .error, message: "backend connection lost"),
      ])
  }

  @Test func dependencyOverrideRoutesThroughTheProvidedLogger() {
    let logger = FakeLogging()

    withDependencies {
      $0.logging = logger
    } operation: {
      @Dependency(\.logging) var logging
      logging.log(.warning, "resolved via @Dependency")
    }

    #expect(logger.messages == [LoggedMessage(level: .warning, message: "resolved via @Dependency")])
  }

  @Test func liveValueDiscardsWithoutThrowingOrCrashing() {
    // Exercises the non-Darwin liveValue/testValue placeholder directly, confirming it's safe
    // to call even though it drops everything.
    let discarding: any Logging = DiscardingLogging()
    discarding.log(.error, "should be silently discarded")
  }

  #if canImport(os)
  @Test func osLoggingAcceptsEveryLevelWithoutThrowingOrCrashing() {
    // Doesn't assert on unified logging's own store (not something this codebase's fake-based
    // test style can reach, and not necessary - `Daemon` only ever talks to the `Logging`
    // protocol, never to `OSLogging` concretely). Just confirms the level mapping covers every
    // case without a runtime trap.
    let osLogging: any Logging = OSLogging()
    osLogging.log(.info, "info level")
    osLogging.log(.warning, "warning level")
    osLogging.log(.error, "error level")
  }
  #endif
}
