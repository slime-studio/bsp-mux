import Dependencies
import Foundation
import Testing

@testable import BSPMuxCore

@Suite struct BuildServerJSONTests {
  static let workspaceRoot = "/test-workspace-xyz/project"
  static let buildServerJSONPath = "\(workspaceRoot)/buildServer.json"

  @Test func loadReturnsThePathParsedJSONAndArgv() throws {
    let fs = InMemoryFileSystem([
      Self.buildServerJSONPath: try JSONSerialization.data(withJSONObject: [
        "name": "sourcekit-xcode-bsp", "argv": ["/usr/local/bin/sourcekit-xcode-bsp", "serve"],
      ]),
    ])

    try withDependencies {
      $0.fileSystem = fs
    } operation: {
      let loaded = try BuildServerJSON.load(
        workspaceRoot: Self.workspaceRoot, missingFileGuidance: "irrelevant here.", using: fs)

      #expect(loaded.path == Self.buildServerJSONPath)
      #expect(loaded.argv == ["/usr/local/bin/sourcekit-xcode-bsp", "serve"])
      #expect(loaded.json["name"] as? String == "sourcekit-xcode-bsp")
    }
  }

  @Test func missingFileThrowsWithTheCallerSuppliedGuidance() {
    let fs = InMemoryFileSystem()

    withDependencies {
      $0.fileSystem = fs
    } operation: {
      #expect(throws: BuildServerJSON.Error.self) {
        try BuildServerJSON.load(workspaceRoot: Self.workspaceRoot, missingFileGuidance: "do the thing first.", using: fs)
      }
      do {
        _ = try BuildServerJSON.load(workspaceRoot: Self.workspaceRoot, missingFileGuidance: "do the thing first.", using: fs)
      } catch let error as BuildServerJSON.Error {
        #expect(error.description.contains("do the thing first."))
      } catch {
        Issue.record("expected a BuildServerJSON.Error")
      }
    }
  }

  @Test func notAJSONObjectThrows() throws {
    let fs = InMemoryFileSystem([Self.buildServerJSONPath: try JSONSerialization.data(withJSONObject: ["just", "an", "array"])])

    withDependencies {
      $0.fileSystem = fs
    } operation: {
      #expect(throws: BuildServerJSON.Error.self) {
        try BuildServerJSON.load(workspaceRoot: Self.workspaceRoot, missingFileGuidance: "", using: fs)
      }
    }
  }

  @Test func missingArgvThrows() throws {
    let fs = InMemoryFileSystem([Self.buildServerJSONPath: try JSONSerialization.data(withJSONObject: ["name": "backend"])])

    withDependencies {
      $0.fileSystem = fs
    } operation: {
      #expect(throws: BuildServerJSON.Error.self) {
        try BuildServerJSON.load(workspaceRoot: Self.workspaceRoot, missingFileGuidance: "", using: fs)
      }
    }
  }

  @Test func emptyArgvThrows() throws {
    let fs = InMemoryFileSystem([Self.buildServerJSONPath: try JSONSerialization.data(withJSONObject: ["argv": [String]()])])

    withDependencies {
      $0.fileSystem = fs
    } operation: {
      #expect(throws: BuildServerJSON.Error.self) {
        try BuildServerJSON.load(workspaceRoot: Self.workspaceRoot, missingFileGuidance: "", using: fs)
      }
    }
  }
}
