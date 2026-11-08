import Foundation

/// A workspace's `buildServer.json`, read and validated - the one thing `Installer` (which
/// needs the whole parsed object, to rewrap `argv` while leaving every other field untouched)
/// and `DaemonStopSignal` (which only needs the validated `argv`, to recover the real backend's
/// command) both have to do before they can do anything else. Deliberately a loosely-typed
/// `[String: Any]`, not a `Codable` domain struct - the whole point (see `Installer`'s own doc
/// comment) is passing unknown fields through untouched without needing to understand a
/// specific backend's config schema.
public struct BuildServerJSON {
  public struct Error: Swift.Error, CustomStringConvertible {
    public let description: String
  }

  public let path: String
  public let json: [String: Any]
  public let argv: [String]

  /// - Parameter missingFileGuidance: Appended to the "no buildServer.json found" message -
  ///   the one piece each caller needs worded for its own next step (`install` points at
  ///   `sourcekit-xcode-bsp init`; `stop` just has nothing to do).
  public static func load(
    workspaceRoot: String,
    missingFileGuidance: String,
    using fileSystem: FileSystemProviding
  ) throws -> BuildServerJSON {
    let path = "\(workspaceRoot)/buildServer.json"
    guard fileSystem.fileExists(atPath: path) else {
      throw Error(description: "No buildServer.json found at \(path) - \(missingFileGuidance)")
    }

    let data = try fileSystem.contents(atPath: path)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Error(description: "\(path) does not contain a JSON object")
    }
    guard let argv = json["argv"] as? [String], !argv.isEmpty else {
      throw Error(description: "\(path) has no non-empty 'argv' array")
    }

    return BuildServerJSON(path: path, json: json, argv: argv)
  }
}
