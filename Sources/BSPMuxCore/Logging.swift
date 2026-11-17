import Dependencies

#if canImport(os)
import os
#endif

/// Severity of a logged message. Kept small and generic rather than mirroring BSP's own
/// `MessageType` (`Error`/`Warning`/`Info`/`Log`) one-for-one, so this seam isn't coupled to
/// BSP's wire format — a caller relaying a backend `build/logMessage` notification maps that
/// field onto this itself.
public enum LogLevel: Sendable, Equatable {
  case info
  case warning
  case error
}

/// Narrow logging seam so `Daemon` can report diagnostics (parse failures, backend
/// disconnection, dropped `build/logMessage` notifications, ...) without depending on any
/// particular destination. The real destination is Darwin-only (`OSLogging`, below) - a
/// deliberate, scoped exception to this project's general POSIX-portability goal, made because
/// Apple's unified logging already solves exactly the problems a hand-rolled file-based logger
/// would otherwise have to (storage/retention/rotation, never blocking the caller) with zero
/// custom code, and because logging itself has no bearing on whether the daemon/election/
/// relay/backend-spawning logic - the actual portable core - works on Linux. `DiscardingLogging`
/// is what every other platform gets instead, same as today.
///
/// Synchronous and non-throwing rather than `async throws`: logging is inherently best-effort -
/// nothing needs to await a log line being durably written before continuing, and a logging
/// failure should never itself become a reason for `Daemon` to fail whatever it was actually
/// doing. A real implementation is responsible for not blocking the caller (e.g. dispatching the
/// actual write to a background queue) and for swallowing its own I/O errors internally.
public protocol Logging: Sendable {
  func log(_ level: LogLevel, _ message: String)
}

extension DependencyValues {
  public var logging: any Logging {
    get { self[LoggingKey.self] }
    set { self[LoggingKey.self] = newValue }
  }

  private enum LoggingKey: DependencyKey {
    #if canImport(os)
    static let liveValue: any Logging = OSLogging()
    #else
    static let liveValue: any Logging = DiscardingLogging()
    #endif
    // Most tests don't care about logging at all and shouldn't have to override it just
    // because something they're exercising happens to log - swift-dependencies requires an
    // explicit testValue precisely to force that choice for callers who DO care (LoggingTests,
    // the DaemonTests cases that assert what got logged) rather than silently falling through
    // to the real liveValue in a test context.
    static let testValue: any Logging = DiscardingLogging()
  }
}

struct DiscardingLogging: Logging {
  func log(_ level: LogLevel, _ message: String) {}
}

#if canImport(os)
/// The real destination on Darwin: Apple's unified logging via the modern `os.Logger` API.
/// Mapped through `log(level:_:)`'s stable `OSLogType` rather than `Logger`'s convenience
/// methods (`.info`/`.error`/...), since `OSLogType` has no dedicated "warning" case either way
/// - `.default` (unified logging's own "notice" severity) is the closest fit for this seam's
/// `.warning`, between `.info` and `.error`.
struct OSLogging: Logging {
  private let logger = Logger(subsystem: "bsp-mux", category: "daemon")

  func log(_ level: LogLevel, _ message: String) {
    let type: OSLogType
    switch level {
    case .info: type = .info
    case .warning: type = .default
    case .error: type = .error
    }
    logger.log(level: type, "\(message, privacy: .public)")
  }
}
#endif
