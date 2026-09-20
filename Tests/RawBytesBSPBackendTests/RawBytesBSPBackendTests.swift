import Foundation
@testable import raw_bytes_bsp_backend
import Testing

@Suite struct RawBytesBSPBackendTests {
  private static func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func initializeEchoesTheRequestsBSPVersion() throws {
    let backend = RawBytesBSPBackend()
    let request = Data(#"{"jsonrpc":"2.0","id":"1","method":"build/initialize","params":{"bspVersion":"2.1.0"}}"#.utf8)

    let messages = try backend.handle(request)
    #expect(messages.count == 1)
    let object = try Self.jsonObject(messages[0])
    #expect(object["id"] as? String == "1")
    let result = try #require(object["result"] as? [String: Any])
    #expect(result["displayName"] as? String == "raw-bytes-bsp-backend")
    #expect(result["bspVersion"] as? String == "2.1.0")
  }

  @Test func shutdownReturnsAnEmptyResult() throws {
    let backend = RawBytesBSPBackend()
    let request = Data(#"{"jsonrpc":"2.0","id":"1","method":"build/shutdown"}"#.utf8)

    let messages = try backend.handle(request)
    #expect(messages.count == 1)
    let object = try Self.jsonObject(messages[0])
    #expect(object["id"] as? String == "1")
    #expect((object["result"] as? [String: Any])?.isEmpty == true)
  }

  @Test func emitNotificationTriggerReturnsTheNotificationThenTheReplyInOrder() throws {
    let backend = RawBytesBSPBackend()
    let json =
      #"{"jsonrpc":"2.0","id":"2","method":"test/emitNotification","params":{"originId":"task-1","#
      + #""notificationMethod":"build/taskStart","notificationParams":{"originId":"task-1"}}}"#
    let request = Data(json.utf8)

    let messages = try backend.handle(request)
    #expect(messages.count == 2)

    let notification = try Self.jsonObject(messages[0])
    #expect(notification["method"] as? String == "build/taskStart")
    #expect((notification["params"] as? [String: Any])?["originId"] as? String == "task-1")
    #expect(notification["id"] == nil)

    let reply = try Self.jsonObject(messages[1])
    #expect(reply["id"] as? String == "2")
    #expect((reply["result"] as? [String: Any])?.isEmpty == true)
  }

  @Test func emitNotificationTriggerWithoutANotificationMethodReturnsJustTheReply() throws {
    let backend = RawBytesBSPBackend()
    let request = Data(#"{"jsonrpc":"2.0","id":"2","method":"test/emitNotification","params":{}}"#.utf8)

    let messages = try backend.handle(request)
    #expect(messages.count == 1)
    let reply = try Self.jsonObject(messages[0])
    #expect(reply["id"] as? String == "2")
  }

  @Test func anyOtherRequestGetsAnEmptyAckAndNeverEmitsANotification() throws {
    let backend = RawBytesBSPBackend()
    let request = Data(#"{"jsonrpc":"2.0","id":"3","method":"buildTarget/compile","params":{}}"#.utf8)

    let messages = try backend.handle(request)
    #expect(messages.count == 1)
    let reply = try Self.jsonObject(messages[0])
    #expect(reply["id"] as? String == "3")
    #expect(reply["method"] == nil)
  }
}
