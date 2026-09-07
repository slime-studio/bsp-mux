import Foundation

/// Finds real `fake-bsp-backend` processes system-wide via `pgrep -f`, anchored to match only a
/// command line that's *exactly* the backend's own path - confirmed empirically that this still
/// returns exactly one line with two `bsp-mux` processes alive at once (a winner and a relay,
/// both with the backend path somewhere in their own argv), since neither's full command line
/// equals the anchored pattern.
enum BackendProcesses {
  static func pids() -> [Int32] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "^\(BinaryLocator.fakeBSPBackend.path)$"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
      try process.run()
    } catch {
      fatalError("BackendProcesses: failed to run 'pgrep': \(error)")
    }
    process.waitUntilExit()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: output, encoding: .utf8) ?? ""
    return text.split(separator: "\n").compactMap { Int32($0) }
  }
}
