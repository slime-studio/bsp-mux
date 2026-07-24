import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct RealByteStreamTests {
  private static func readBytes(_ source: RealByteSource, count: Int) async throws -> Data {
    var collected = Data()
    while collected.count < count, let chunk = try await source.read() {
      collected.append(chunk)
    }
    return collected
  }

  @Test func writtenBytesAreReadBackInOrder() async throws {
    let pipe = Pipe()
    let sink = RealByteSink(fileDescriptor: pipe.fileHandleForWriting.fileDescriptor)
    let source = RealByteSource(fileDescriptor: pipe.fileHandleForReading.fileDescriptor)

    try await sink.write(Data("hello".utf8))
    try await sink.write(Data(" world".utf8))

    let readBack = try await Self.readBytes(source, count: 11)
    #expect(readBack == Data("hello world".utf8))
  }

  @Test func readReturnsNilAtEOFWhenWriteEndCloses() async throws {
    let pipe = Pipe()
    let source = RealByteSource(fileDescriptor: pipe.fileHandleForReading.fileDescriptor)

    try pipe.fileHandleForWriting.close()

    let result = try await source.read()
    #expect(result == nil)
  }

  @Test func cancellingAPendingReadStopsPromptly() async throws {
    let pipe = Pipe()
    let source = RealByteSource(fileDescriptor: pipe.fileHandleForReading.fileDescriptor)

    // Nothing written and the write end stays open, so an uncancelled read would hang forever.
    let task = Task<Data?, Error> {
      try await source.read()
    }
    task.cancel()

    let outcome = try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        do {
          _ = try await task.value
          return "resolved"
        } catch {
          return "resolved with error"
        }
      }
      group.addTask {
        try await Task.sleep(for: .milliseconds(500))
        return "timed out"
      }
      let first = try await group.next()!
      group.cancelAll()
      return first
    }

    #expect(outcome != "timed out")
  }

  @Test func writeToAClosedReadEndPropagatesAnError() async throws {
    signal(SIGPIPE, SIG_IGN)
    let pipe = Pipe()
    let sink = RealByteSink(fileDescriptor: pipe.fileHandleForWriting.fileDescriptor)

    try pipe.fileHandleForReading.close()

    await #expect(throws: Error.self) {
      // The pipe buffer may absorb a small first write before the broken-pipe error surfaces,
      // so write enough that at least one write call is guaranteed to hit it.
      for _ in 0..<64 {
        try await sink.write(Data(repeating: 0, count: 4096))
      }
    }
  }
}
