import Foundation

/// Runs a real `bsp-mux` invocation to completion and captures its result - for the one-shot
/// subcommands (`install`, `stop`) rather than `run`, which `SimulatedClient` drives instead
/// since it never exits on its own.
enum BSPMuxCLI {
  struct Result {
    let exitCode: Int32
    let standardOutput: String
  }

  static func run(_ arguments: [String]) throws -> Result {
    let process = Process()
    process.executableURL = BinaryLocator.bspMux
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()  // discarded - matches SimulatedClient's own convention
    try process.run()
    process.waitUntilExit()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    return Result(exitCode: process.terminationStatus, standardOutput: String(data: output, encoding: .utf8) ?? "")
  }
}
