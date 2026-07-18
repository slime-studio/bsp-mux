import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct MessageFramingTests {
  @Test func frameProducesCorrectContentLengthHeader() {
    let body = Data(#"{"a":1}"#.utf8)
    let framed = MessageFraming.frame(body)
    #expect(String(bytes: framed, encoding: .utf8)! == "Content-Length: 7\r\n\r\n{\"a\":1}")
  }

  @Test func singleCompleteFrameInOneFeed() throws {
    let body = Data(#"{"a":1}"#.utf8)
    var reader = MessageFrameReader()
    let messages = try reader.feed(MessageFraming.frame(body))
    #expect(messages == [body])
  }

  @Test func multipleFramesCoalescedIntoOneFeed() throws {
    let bodyA = Data(#"{"a":1}"#.utf8)
    let bodyB = Data(#"{"b":2}"#.utf8)
    var combined = MessageFraming.frame(bodyA)
    combined.append(MessageFraming.frame(bodyB))

    var reader = MessageFrameReader()
    let messages = try reader.feed(combined)
    #expect(messages == [bodyA, bodyB])
  }

  @Test func headerSplitAcrossMultipleFeeds() throws {
    let body = Data(#"{"a":1}"#.utf8)
    let framed = MessageFraming.frame(body)
    let splitPoint = framed.index(framed.startIndex, offsetBy: 8)  // mid "Content-Length"

    var reader = MessageFrameReader()
    let first = try reader.feed(framed[framed.startIndex..<splitPoint])
    #expect(first.isEmpty)
    let second = try reader.feed(framed[splitPoint...])
    #expect(second == [body])
  }

  @Test func bodySplitAcrossMultipleFeeds() throws {
    let body = Data(#"{"a":1,"b":2}"#.utf8)
    let framed = MessageFraming.frame(body)
    let headerEnd = framed.range(of: Data("\r\n\r\n".utf8))!.upperBound
    let bodyMidpoint = framed.index(headerEnd, offsetBy: body.count / 2)

    var reader = MessageFrameReader()
    let first = try reader.feed(framed[framed.startIndex..<bodyMidpoint])
    #expect(first.isEmpty)
    let second = try reader.feed(framed[bodyMidpoint...])
    #expect(second == [body])
  }

  @Test func extremeByteAtATimeChunking() throws {
    let bodyA = Data(#"{"a":1}"#.utf8)
    let bodyB = Data(#"{"b":22222}"#.utf8)
    var allBytes = MessageFraming.frame(bodyA)
    allBytes.append(MessageFraming.frame(bodyB))

    var reader = MessageFrameReader()
    var received: [Data] = []
    for byte in allBytes {
      received.append(contentsOf: try reader.feed(Data([byte])))
    }
    #expect(received == [bodyA, bodyB])
  }

  @Test func contentLengthIsMeasuredInBytesNotCharacters() throws {
    // "café 🎉" is 6 Characters but more UTF-8 bytes (é is 2 bytes, 🎉 is 4 bytes).
    let body = Data(#"{"text":"café 🎉"}"#.utf8)
    var reader = MessageFrameReader()
    let messages = try reader.feed(MessageFraming.frame(body))
    #expect(messages == [body])
    #expect(String(bytes: messages[0], encoding: .utf8)! == #"{"text":"café 🎉"}"#)
  }

  @Test func missingContentLengthHeaderThrows() {
    var reader = MessageFrameReader()
    let malformed = Data("Content-Type: application/json\r\n\r\n{}".utf8)
    #expect(throws: MessageFrameError.self) {
      _ = try reader.feed(malformed)
    }
  }

  @Test func nonNumericContentLengthThrows() {
    var reader = MessageFrameReader()
    let malformed = Data("Content-Length: not-a-number\r\n\r\n{}".utf8)
    #expect(throws: MessageFrameError.self) {
      _ = try reader.feed(malformed)
    }
  }

  @Test func contentLengthHeaderNameIsCaseInsensitive() throws {
    let body = Data(#"{"a":1}"#.utf8)
    var reader = MessageFrameReader()
    let framed = Data("content-length: \(body.count)\r\n\r\n".utf8) + body
    let messages = try reader.feed(framed)
    #expect(messages == [body])
  }

  @Test func extraHeaderBeforeContentLengthIsIgnored() throws {
    let body = Data(#"{"a":1}"#.utf8)
    var reader = MessageFrameReader()
    let framed = Data("Content-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
    let messages = try reader.feed(framed)
    #expect(messages == [body])
  }

  @Test func emptyBodyIsValid() throws {
    var reader = MessageFrameReader()
    let framed = Data("Content-Length: 0\r\n\r\n".utf8)
    let messages = try reader.feed(framed)
    #expect(messages == [Data()])
  }

  @Test func readerRetainsStateAcrossManySmallFeedsForManyFrames() throws {
    var reader = MessageFrameReader()
    var received: [Data] = []
    for i in 0..<20 {
      let body = Data(#"{"i":\#(i)}"#.utf8)
      let framed = MessageFraming.frame(body)
      // Feed in two chunks each time to keep exercising the partial-buffer path.
      let mid = framed.index(framed.startIndex, offsetBy: framed.count / 2)
      received.append(contentsOf: try reader.feed(framed[framed.startIndex..<mid]))
      received.append(contentsOf: try reader.feed(framed[mid...]))
    }
    #expect(received.count == 20)
    for (i, message) in received.enumerated() {
      #expect(String(bytes: message, encoding: .utf8)! == #"{"i":\#(i)}"#)
    }
  }
}
