import Foundation
import Testing

@testable import BSPMuxCore

/// `RealElectionEnvironment.signalOwnProcessGroup`'s real POSIX behavior is verified by hand,
/// not here - see its doc comment for why calling the real `kill(-getpgrp(), ...)` inside the
/// test runner's own process would be unsafe to automate. This only exercises the fake's own
/// recording behavior, the same way other seams' fakes get a small standalone test of their own
/// shape before anything production-facing consumes them.
@Suite struct ProcessGroupSignalingTests {
  @Test func fakeRecordsEverySignalRequestedInOrder() {
    let environment = FakeElectionEnvironment()

    environment.signalOwnProcessGroup(SIGTERM)
    environment.signalOwnProcessGroup(SIGKILL)

    #expect(environment.signaledProcessGroupSignals == [SIGTERM, SIGKILL])
    #expect(environment.calls == ["signalOwnProcessGroup", "signalOwnProcessGroup"])
  }
}
