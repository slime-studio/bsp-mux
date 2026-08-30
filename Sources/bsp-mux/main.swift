import BSPMuxCore
import Foundation

do {
  let command = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
  let application: any BSPMuxApplication = RealBSPMuxApplication()

  switch command {
  case .install(let workspaceRoot, let force):
    let result = try application.install(
      workspaceRoot: workspaceRoot,
      multiplexerExecutable: CommandLine.arguments[0],
      force: force
    )
    print(result.changed ? "Wrapped \(workspaceRoot)/buildServer.json." : "Already wrapped; nothing to do.")

  case .run(let workspaceRoot, let backendArgv):
    try await application.run(workspaceRoot: workspaceRoot, backendArgv: backendArgv)
  }
} catch {
  CLIArguments.exit(withError: error)
}
