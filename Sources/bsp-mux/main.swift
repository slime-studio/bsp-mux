import BSPMuxCore
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The running binary's own real path - NOT `CommandLine.arguments[0]`, which is whatever the
/// shell happened to invoke it as (confirmed empirically: invoking a bare name resolved via
/// `PATH` leaves `arguments[0]` as just that name, with no `/` in it at all). `Installer` splices
/// this straight into `buildServer.json`'s `argv` for a *different* process (`sourcekit-lsp`) to
/// exec later from a different cwd, so a wrong-but-plausible-looking path here is worse than
/// most - `RealFileSystem.resolvePath`'s `realpath(3)` call can't recover a bare name, since
/// `realpath` resolves relative paths against cwd, not `PATH` - it silently falls back to
/// `<cwd>/<name>`, a path that generally doesn't exist. Querying the OS directly for the real
/// executable path (rather than reconstructing it from argv[0] + a PATH search) sidesteps the
/// ambiguity entirely, regardless of how the process was invoked.
func currentExecutablePath() -> String {
  #if canImport(Darwin)
  var size: UInt32 = 0
  _NSGetExecutablePath(nil, &size)
  var buffer = [Int8](repeating: 0, count: Int(size))
  guard _NSGetExecutablePath(&buffer, &size) == 0 else { return CommandLine.arguments[0] }
  return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  #elseif canImport(Glibc) || canImport(Musl)
  var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
  let count = readlink("/proc/self/exe", &buffer, buffer.count - 1)
  guard count > 0 else { return CommandLine.arguments[0] }
  buffer[Int(count)] = 0
  return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  #else
  return CommandLine.arguments[0]
  #endif
}

do {
  let command = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
  let application: any BSPMuxApplication = RealBSPMuxApplication()

  switch command {
  case .install(let workspaceRoot, let force):
    let result = try application.install(
      workspaceRoot: workspaceRoot,
      multiplexerExecutable: currentExecutablePath(),
      force: force
    )
    print(result.changed ? "Wrapped \(workspaceRoot)/buildServer.json." : "Already wrapped; nothing to do.")

  case .run(let workspaceRoot, let backendArgv):
    try await application.run(
      workspaceRoot: workspaceRoot,
      backendArgv: backendArgv,
      standardIn: RealByteSource(fileDescriptor: STDIN_FILENO),
      standardOut: RealByteSink(fileDescriptor: STDOUT_FILENO)
    )

  case .stop(let workspaceRoot, let force):
    let result = try await application.stop(
      workspaceRoot: workspaceRoot,
      multiplexerExecutable: currentExecutablePath(),
      force: force
    )
    switch result.outcome {
    case .stopped:
      print("Stopped the bsp-mux daemon for \(workspaceRoot).")
    case .notRunning:
      print("No running bsp-mux daemon found for \(workspaceRoot).")
    }
  }
} catch {
  CLIArguments.exit(withError: error)
}
