import BuildServerProtocol
import Foundation
import LanguageServerProtocolTransport

let connection = JSONRPCConnection(
  name: "fake-bsp-backend", protocol: .bspProtocol,
  receiveFD: .standardInput, sendFD: .standardOutput
)
// Two exit paths, both load-bearing: `FakeBSPBackend.handle`'s own `exit(...)` call on a real
// `build/exit` notification (the graceful path), and this `closeHandler` firing on stdin EOF (the
// abrupt path - the daemon on the other end died, e.g. SIGKILLed, so no `build/exit` was ever
// sent). `JSONRPCConnection`'s own read loop `close()`s itself on EOF, but `dispatchMain()` below
// never returns on its own - without this, the process would live on as an orphan with nothing
// left to talk to.
connection.start(receiveHandler: FakeBSPBackend()) { exit(0) }
dispatchMain()
