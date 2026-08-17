import Foundation

@testable import BSPMuxCore

struct LoggedMessage: Equatable {
  let level: LogLevel
  let message: String
}

final class FakeLogging: Logging, @unchecked Sendable {
  private(set) var messages: [LoggedMessage] = []

  func log(_ level: LogLevel, _ message: String) {
    messages.append(LoggedMessage(level: level, message: message))
  }
}
