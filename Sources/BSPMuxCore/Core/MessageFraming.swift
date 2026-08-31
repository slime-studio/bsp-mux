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
  /// The header search and `Content-Length` parse, cached once found so a large body arriving
  /// across many `feed()` calls doesn't redo either on every single call while just waiting for
  /// more bytes - confirmed empirically to matter: re-parsing the header per call scales with
  /// call count, not message size, and at fine-grained chunking (e.g. one byte at a time) that's
  /// the difference between low-single-digit milliseconds and multiple seconds for a large body.
  private var pendingHeader: PendingHeader?

  private struct PendingHeader {
    let bodyStart: Data.Index
    let contentLength: Int
  }

  public init() {}

  /// Whether a partial header or partial body is currently buffered, waiting for more bytes.
  /// Lets a caller distinguish a clean EOF between messages from one that cuts a message off
  /// mid-frame - the latter means the connection died, not that it finished normally.
  public var hasBufferedPartialData: Bool {
    !buffer.isEmpty
  }

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
    let header: PendingHeader
    if let cached = pendingHeader {
      header = cached
    } else {
      guard let headerEndRange = buffer.range(of: Self.headerTerminator) else {
        return nil
      }
      let headerBytes = buffer[buffer.startIndex..<headerEndRange.lowerBound]
      let contentLength = try Self.parseContentLength(headerBytes)
      header = PendingHeader(bodyStart: headerEndRange.upperBound, contentLength: contentLength)
      pendingHeader = header
    }

    guard let bodyEnd = buffer.index(header.bodyStart, offsetBy: header.contentLength, limitedBy: buffer.endIndex) else {
      return nil
    }

    let body = Data(buffer[header.bodyStart..<bodyEnd])
    buffer.removeSubrange(buffer.startIndex..<bodyEnd)
    pendingHeader = nil
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
