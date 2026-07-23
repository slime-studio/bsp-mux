import Foundation

/// The loser-of-election path (see DESIGN.md's "Self-electing daemon"): pumps raw bytes between
/// this process's own stdio and a live daemon's socket, with no JSON-RPC parsing at all —
/// whatever's on the other end of the socket already does its own per-connection framing.
///
/// Whichever direction reaches EOF or errors first ends the whole relay. A relay process has no
/// other job, so there's nothing left to keep alive once either the editor (stdin closing) or
/// the daemon (the socket closing) is gone — the same EOF-is-enough reasoning `Daemon` relies on
/// for detecting a disconnected client, no heartbeats needed.
public enum Relay {
  public static func run(
    standardIn: any ByteSource, standardOut: any ByteSink, socket: any DuplexByteStream
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await pump(from: standardIn, to: socket) }
      group.addTask { try await pump(from: socket, to: standardOut) }
      try await group.next()
      group.cancelAll()
    }
  }

  private static func pump(from source: any ByteSource, to sink: any ByteSink) async throws {
    while let chunk = try await source.read() {
      try await sink.write(chunk)
    }
  }
}
