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
    // Not overridden - exercises the placeholder liveValue directly, confirming it's safe to
    // call even though nothing production-facing depends on it yet.
    let liveLogging: any Logging = DiscardingLogging()
    liveLogging.log(.error, "should be silently discarded")
  }
}
