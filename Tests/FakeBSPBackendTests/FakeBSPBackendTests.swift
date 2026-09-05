import BuildServerProtocol
@testable import fake_bsp_backend
import LanguageServerProtocol
import Testing

@Suite struct FakeBSPBackendTests {
  /// `FakeBSPBackend.handle`/`exit` calls back synchronously and inline (no real dispatch queue
  /// involved when driving it directly like these tests do), but both are typed `@Sendable`, so a
  /// plain captured `var` doesn't satisfy the compiler - a reference type recorder does.
  private final class Recorder<Value>: @unchecked Sendable {
    private(set) var values: [Value] = []
    func record(_ value: Value) { values.append(value) }
  }

  private static func initializeRequest(bspVersion: String = "2.1.0") -> InitializeBuildRequest {
    InitializeBuildRequest(
      displayName: "editor", version: "1.0", bspVersion: bspVersion,
      rootUri: URI(filePath: "/workspace", isDirectory: true),
      capabilities: BuildClientCapabilities(languageIds: [Language(rawValue: "swift")])
    )
  }

  private static func reply<Request: RequestType>(
    to request: Request, on backend: FakeBSPBackend
  ) -> LSPResult<Request.Response> {
    let recorder = Recorder<LSPResult<Request.Response>>()
    backend.handle(request, id: .string("1")) { recorder.record($0) }
    return recorder.values[0]
  }

  @Test func initializeReturnsARealResponseEchoingTheRequestsBSPVersion() throws {
    let backend = FakeBSPBackend()
    let result = Self.reply(to: Self.initializeRequest(bspVersion: "2.1.0"), on: backend)
    let response = try result.get()
    #expect(response.displayName == "fake-bsp-backend")
    #expect(response.bspVersion == "2.1.0")
  }

  @Test func aRequestBeforeInitializeGetsServerNotInitialized() {
    let backend = FakeBSPBackend()
    let result = Self.reply(to: WorkspaceBuildTargetsRequest(), on: backend)
    guard case .failure(let error) = result else {
      Issue.record("expected a failure before initialize")
      return
    }
    #expect(error.code == .serverNotInitialized)
  }

  @Test func shutdownThenExitExitsZero() throws {
    let exitCodes = Recorder<Int32>()
    let backend = FakeBSPBackend(exit: { exitCodes.record($0) })
    _ = Self.reply(to: Self.initializeRequest(), on: backend)

    let shutdownResult = Self.reply(to: BuildShutdownRequest(), on: backend)
    #expect(try shutdownResult.get() == VoidResponse())

    backend.handle(OnBuildExitNotification())
    #expect(exitCodes.values == [0])
  }

  @Test func exitWithoutAPriorShutdownExitsOne() {
    let exitCodes = Recorder<Int32>()
    let backend = FakeBSPBackend(exit: { exitCodes.record($0) })
    _ = Self.reply(to: Self.initializeRequest(), on: backend)

    backend.handle(OnBuildExitNotification())
    #expect(exitCodes.values == [1])
  }

  @Test func exitBeforeInitializeIsStillHonored() {
    let exitCodes = Recorder<Int32>()
    let backend = FakeBSPBackend(exit: { exitCodes.record($0) })

    backend.handle(OnBuildExitNotification())
    #expect(exitCodes.values == [1])
  }

  @Test func otherPreInitializeNotificationsAreDropped() {
    let exitCodes = Recorder<Int32>()
    let backend = FakeBSPBackend(exit: { exitCodes.record($0) })

    // No observable effect expected - just confirms this doesn't crash or otherwise misbehave.
    backend.handle(OnBuildInitializedNotification())
    #expect(exitCodes.values.isEmpty)
  }

  @Test func workspaceBuildTargetsAndBuildTargetSourcesReturnEmptyResponses() throws {
    let backend = FakeBSPBackend()
    _ = Self.reply(to: Self.initializeRequest(), on: backend)

    let targetsResult = Self.reply(to: WorkspaceBuildTargetsRequest(), on: backend)
    #expect(try targetsResult.get().targets.isEmpty)

    let sourcesResult = Self.reply(to: BuildTargetSourcesRequest(targets: []), on: backend)
    #expect(try sourcesResult.get().items.isEmpty)
  }

  @Test func anUnhandledRequestGetsMethodNotFound() {
    let backend = FakeBSPBackend()
    _ = Self.reply(to: Self.initializeRequest(), on: backend)

    let result = Self.reply(to: CreateWorkDoneProgressRequest(token: .string("1")), on: backend)
    guard case .failure(let error) = result else {
      Issue.record("expected methodNotFound for an unhandled request")
      return
    }
    #expect(error.code == .methodNotFound)
  }
}
