import Dependencies
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import BSPMuxCore

@Suite struct DaemonTeardownTests {
  @Test func normalReasonUnlinksAndExitsWithoutSignalingTheProcessGroup() async {
    let fileSystem = InMemoryFileSystem(["/tmp/project.sock": Data()])
    let environment = FakeElectionEnvironment()
    let processExiting = FakeProcessExiting()

    await withDependencies {
      $0.fileSystem = fileSystem
      $0.electionEnvironment = environment
      $0.processExiting = processExiting
    } operation: {
      await DaemonTeardown.run(reason: .normal, socketPath: "/tmp/project.sock")
    }

    #expect(fileSystem.removedPaths == ["/tmp/project.sock"])
    #expect(!environment.calls.contains("signalOwnProcessGroup"))
    #expect(processExiting.exitCodes == [0])
  }

  @Test func signalReasonUnlinksSignalsTheProcessGroupAndExits() async {
    let fileSystem = InMemoryFileSystem(["/tmp/project.sock": Data()])
    let environment = FakeElectionEnvironment()
    let processExiting = FakeProcessExiting()

    await withDependencies {
      $0.fileSystem = fileSystem
      $0.electionEnvironment = environment
      $0.processExiting = processExiting
    } operation: {
      await DaemonTeardown.run(reason: .signal(SIGTERM), socketPath: "/tmp/project.sock")
    }

    #expect(fileSystem.removedPaths == ["/tmp/project.sock"])
    #expect(environment.calls.contains("signalOwnProcessGroup"))
    #expect(processExiting.exitCodes == [0])
  }
}
