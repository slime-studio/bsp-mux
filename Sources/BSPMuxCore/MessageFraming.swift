import Foundation

public struct MessageFrameError: Swift.Error, CustomStringConvertible, Equatable {
  public let description: String

  public init(description: String) {
    self.description = description
  }
}

/// `Content-Length`-framing for outbound JSON-RPC messages, the wire format BSP shares with
/// LSP: a `Content-Length` header naming the body's byte count, a blank line, then the body.
public enum MessageFraming {
  public static func frame(_ body: Data) -> Data {
    var result = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
    result.append(body)
    return result
  }
}

/// Incrementally accumulates bytes read from a JSON-RPC transport (stdio, a socket, ...) and
/// yields complete message bodies as `Content-Length`-framed messages become available.
///
/// Deliberately byte-oriented and push-based rather than tied to any particular I/O source:
/// `Content-Length` counts bytes, not characters, and a single underlying `read()` can deliver
/// a partial frame, several coalesced frames, or anything in between — this type only knows
/// how to accumulate and slice bytes; whoever owns the actual stdio/socket read loop feeds it.
public struct MessageFrameReader: Sendable {
  private var buffer = Data()

  public init() {}

  /// Feeds newly-received bytes and returns every complete message body extracted so far, in
  /// order. Incomplete trailing data (a partial header or partial body) stays buffered for the
  /// next call.
  public mutating func feed(_ chunk: Data) throws -> [Data] {
    buffer.append(chunk)
    var messages: [Data] = []
    while let message = try extractNextMessage() {
      messages.append(message)
    }
    return messages
  }

  private mutating func extractNextMessage() throws -> Data? {
    guard let headerEndRange = buffer.range(of: Self.headerTerminator) else {
      return nil
    }
    let headerBytes = buffer[buffer.startIndex..<headerEndRange.lowerBound]
    let contentLength = try Self.parseContentLength(headerBytes)

    let bodyStart = headerEndRange.upperBound
    guard let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength, limitedBy: buffer.endIndex) else {
      return nil
    }

    let body = Data(buffer[bodyStart..<bodyEnd])
    buffer.removeSubrange(buffer.startIndex..<bodyEnd)
    return body
  }

  private static let headerTerminator = Data("\r\n\r\n".utf8)

  private static func parseContentLength(_ headerBytes: some DataProtocol) throws -> Int {
    guard let headerString = String(bytes: headerBytes, encoding: .utf8) else {
      throw MessageFrameError(description: "header is not valid UTF-8")
    }
    for line in headerString.components(separatedBy: "\r\n") where !line.isEmpty {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
      guard name.caseInsensitiveCompare("Content-Length") == .orderedSame else { continue }
      let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
      guard let length = Int(value), length >= 0 else {
        throw MessageFrameError(description: "invalid Content-Length value: \(value)")
      }
      return length
    }
    throw MessageFrameError(description: "missing Content-Length header")
  }
}
