import BSPMuxCore
import Foundation

let channel = FramedDuplexChannel(
  source: RealByteSource(fileDescriptor: FileHandle.standardInput.fileDescriptor),
  sink: RealByteSink(fileDescriptor: FileHandle.standardOutput.fileDescriptor)
)
let backend = RawBytesBSPBackend()

// Falling off the end of this loop on stdin EOF (the daemon died without a graceful build/exit)
// ends the process with a clean exit - no explicit exit(0)/dispatchMain() needed the way
// fake-bsp-backend needs for its GCD-based JSONRPCConnection, since this uses async/await
// directly and top-level `await` is supported in a main.swift file (confirmed by bsp-mux's own
// main.swift already doing exactly this).
while let bytes = try await channel.receive() {
  for message in try backend.handle(bytes) {
    try await channel.send(message)
  }
}
