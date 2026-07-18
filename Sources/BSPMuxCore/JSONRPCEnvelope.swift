import Foundation

public struct JSONRPCEnvelopeError: Swift.Error, CustomStringConvertible, Equatable {
  public let description: String

  public init(description: String) {
    self.description = description
  }
}

/// The raw JSON source text of a JSON-RPC `id` value (e.g. `42`, `"abc"`, `null`), preserved
/// verbatim rather than parsed into a Swift number/string. IDs are opaque tokens as far as
/// this multiplexer is concerned — it only ever needs to compare them for equality and
/// reproduce them exactly, never interpret them, so there's no reason to risk the precision
/// loss a numeric decode through `Double` could introduce for a large id.
public struct JSONRPCRawID: Sendable, Equatable, Hashable {
  public let rawText: String

  public init(rawText: String) {
    self.rawText = rawText
  }
}

/// A JSON-RPC message's envelope (`id`, `method`), with every other field — `params`,
/// `result`, `error`, and anything a specific backend adds that this multiplexer doesn't know
/// about — left as untouched raw bytes. Rewriting `id` splices only that field's byte range
/// rather than decoding and re-encoding the whole message, so nothing else can be silently
/// altered by a round trip (e.g. a large integer timestamp losing precision through `Double`).
public struct JSONRPCEnvelope: Sendable, Equatable {
  public let rawBytes: Data
  public let id: JSONRPCRawID?
  public let method: String?
  private let idValueRange: Range<Data.Index>?

  public init(rawBytes: Data) throws {
    self.rawBytes = rawBytes
    let bytes = [UInt8](rawBytes)
    let fields = try JSONByteScanner.topLevelObjectFields(bytes)

    if let idRange = fields["id"] {
      guard let idText = String(bytes: bytes[idRange], encoding: .utf8) else {
        throw JSONRPCEnvelopeError(description: "id value is not valid UTF-8")
      }
      self.id = JSONRPCRawID(rawText: idText)
      self.idValueRange = (rawBytes.startIndex + idRange.lowerBound)..<(rawBytes.startIndex + idRange.upperBound)
    } else {
      self.id = nil
      self.idValueRange = nil
    }

    if let methodRange = fields["method"] {
      self.method = try JSONByteScanner.decodeJSONStringLiteral(bytes, range: methodRange)
    } else {
      self.method = nil
    }
  }

  /// Returns `rawBytes` with the `id` value replaced by `newID`'s raw text, splicing only
  /// that byte range. Returns `rawBytes` unchanged if this message has no `id` (a
  /// notification) — there's nothing to rewrite.
  public func withRewrittenID(_ newID: JSONRPCRawID) -> Data {
    guard let idValueRange else { return rawBytes }
    var result = Data()
    result.append(rawBytes[rawBytes.startIndex..<idValueRange.lowerBound])
    result.append(contentsOf: Array(newID.rawText.utf8))
    result.append(rawBytes[idValueRange.upperBound...])
    return result
  }

  /// Looks up `key` within the top-level `params` object — e.g. `originId` — without decoding
  /// `params` as a whole. Returns the raw JSON source text of that field's value, or `nil` if
  /// `params` is absent, isn't an object, or doesn't contain `key`.
  public func paramsField(_ key: String) -> String? {
    let bytes = [UInt8](rawBytes)
    guard let topLevel = try? JSONByteScanner.topLevelObjectFields(bytes), let paramsRange = topLevel["params"] else {
      return nil
    }
    let paramsBytes = Array(bytes[paramsRange])
    guard let paramsFields = try? JSONByteScanner.topLevelObjectFields(paramsBytes), let fieldRange = paramsFields[key] else {
      return nil
    }
    return String(bytes: paramsBytes[fieldRange], encoding: .utf8)
  }
}

/// Finds byte ranges of named fields within a JSON object without decoding the whole
/// document — the minimum amount of JSON parsing needed to splice `id` and peek at
/// `params.originId` while leaving everything else byte-for-byte untouched.
enum JSONByteScanner {
  /// Scans a top-level JSON object and returns the byte range of each key's value within
  /// `bytes`. Ranges point at the value only (not the surrounding quotes for strings, so
  /// callers that want the raw source text — including quotes, for opaque round-tripping —
  /// get exactly what was written).
  static func topLevelObjectFields(_ bytes: [UInt8]) throws -> [String: Range<Int>] {
    var index = skipWhitespace(bytes, from: 0)
    guard index < bytes.count, bytes[index] == openBrace else {
      throw JSONRPCEnvelopeError(description: "expected a JSON object")
    }
    index += 1

    var fields: [String: Range<Int>] = [:]
    index = skipWhitespace(bytes, from: index)
    if index < bytes.count, bytes[index] == closeBrace {
      return fields
    }

    while true {
      index = skipWhitespace(bytes, from: index)
      guard index < bytes.count, bytes[index] == quote else {
        throw JSONRPCEnvelopeError(description: "expected object key at offset \(index)")
      }
      let keyStart = index
      let keyEnd = try skipString(bytes, from: index)
      let key = try decodeJSONStringLiteral(bytes, range: keyStart..<keyEnd)

      index = skipWhitespace(bytes, from: keyEnd)
      guard index < bytes.count, bytes[index] == colon else {
        throw JSONRPCEnvelopeError(description: "expected ':' at offset \(index)")
      }
      index = skipWhitespace(bytes, from: index + 1)

      let valueStart = index
      let valueEnd = try skipValue(bytes, from: index)
      fields[key] = valueStart..<valueEnd

      index = skipWhitespace(bytes, from: valueEnd)
      guard index < bytes.count else {
        throw JSONRPCEnvelopeError(description: "unterminated object")
      }
      if bytes[index] == comma {
        index += 1
        continue
      }
      if bytes[index] == closeBrace {
        return fields
      }
      throw JSONRPCEnvelopeError(description: "expected ',' or '}' at offset \(index)")
    }
  }

  /// Decodes an already-located JSON string literal (including its surrounding quotes) into a
  /// Swift `String`. Safe to round-trip through `JSONSerialization` here specifically because
  /// string decoding has no precision-loss failure mode the way number decoding does.
  static func decodeJSONStringLiteral(_ bytes: [UInt8], range: Range<Int>) throws -> String {
    let slice = Data(bytes[range])
    guard let decoded = try JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed]) as? String else {
      throw JSONRPCEnvelopeError(description: "invalid string literal")
    }
    return decoded
  }

  /// Returns the index one past the end of the JSON value starting at `start` (which must
  /// already point at its first non-whitespace byte).
  private static func skipValue(_ bytes: [UInt8], from start: Int) throws -> Int {
    guard start < bytes.count else {
      throw JSONRPCEnvelopeError(description: "unexpected end of input")
    }
    switch bytes[start] {
    case quote:
      return try skipString(bytes, from: start)
    case openBrace, openBracket:
      return try skipBalanced(bytes, from: start)
    case UInt8(ascii: "t"):
      return try skipLiteral(bytes, from: start, expecting: "true")
    case UInt8(ascii: "f"):
      return try skipLiteral(bytes, from: start, expecting: "false")
    case UInt8(ascii: "n"):
      return try skipLiteral(bytes, from: start, expecting: "null")
    case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
      var index = start
      while index < bytes.count, isNumberByte(bytes[index]) {
        index += 1
      }
      return index
    default:
      throw JSONRPCEnvelopeError(description: "unexpected byte at offset \(start)")
    }
  }

  /// Returns the index one past the closing quote of a string starting at `bytes[start]`
  /// (which must be `"`), correctly stepping over `\"` and other backslash escapes so an
  /// escaped quote or backslash inside the string isn't mistaken for the terminator.
  private static func skipString(_ bytes: [UInt8], from start: Int) throws -> Int {
    var index = start + 1
    while index < bytes.count {
      switch bytes[index] {
      case backslash:
        index += 2
      case quote:
        return index + 1
      default:
        index += 1
      }
    }
    throw JSONRPCEnvelopeError(description: "unterminated string starting at offset \(start)")
  }

  /// Returns the index one past the closing bracket matching the opening `{`/`[` at
  /// `bytes[start]`, skipping over string contents (which may themselves contain unbalanced
  /// bracket characters) along the way.
  private static func skipBalanced(_ bytes: [UInt8], from start: Int) throws -> Int {
    var depth = 0
    var index = start
    while index < bytes.count {
      switch bytes[index] {
      case quote:
        index = try skipString(bytes, from: index)
      case openBrace, openBracket:
        depth += 1
        index += 1
      case closeBrace, closeBracket:
        depth -= 1
        index += 1
        if depth == 0 {
          return index
        }
      default:
        index += 1
      }
    }
    throw JSONRPCEnvelopeError(description: "unterminated object/array starting at offset \(start)")
  }

  private static func skipLiteral(_ bytes: [UInt8], from start: Int, expecting literal: String) throws -> Int {
    let literalBytes = Array(literal.utf8)
    let end = start + literalBytes.count
    guard end <= bytes.count, Array(bytes[start..<end]) == literalBytes else {
      throw JSONRPCEnvelopeError(description: "invalid literal at offset \(start)")
    }
    return end
  }

  private static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
    var index = start
    while index < bytes.count, isWhitespace(bytes[index]) {
      index += 1
    }
    return index
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
  }

  private static func isNumberByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"),
      UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
      return true
    default:
      return false
    }
  }

  private static let openBrace = UInt8(ascii: "{")
  private static let closeBrace = UInt8(ascii: "}")
  private static let openBracket = UInt8(ascii: "[")
  private static let closeBracket = UInt8(ascii: "]")
  private static let quote = UInt8(ascii: "\"")
  private static let backslash = UInt8(ascii: "\\")
  private static let colon = UInt8(ascii: ":")
  private static let comma = UInt8(ascii: ",")
}
