import Dependencies

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
/// particular destination. Deliberately just the interface for now: DESIGN.md's Logging section
/// already commits to file-based/portable/never-stdout-or-stderr, but which concrete
/// implementation satisfies that (a plain file, a file plus `os_log` on Darwin, ...) is being
/// decided separately - nothing production-facing depends on this seam yet.
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
    // A real destination hasn't been chosen yet (see the protocol's doc comment) - silently
    // discarding is the only safe placeholder, since DESIGN.md already rules out stdout/stderr
    // as a stopgap and nothing calls into this seam in production yet anyway.
    static let liveValue: any Logging = DiscardingLogging()
  }
}

struct DiscardingLogging: Logging {
  func log(_ level: LogLevel, _ message: String) {}
}
