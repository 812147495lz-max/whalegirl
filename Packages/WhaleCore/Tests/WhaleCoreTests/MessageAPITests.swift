import XCTest
@testable import WhaleCore

final class MessageAPITests: XCTestCase {
    private let token = String(repeating: "a", count: 64)
    func testFragmentedHTTPKeepsUTF8BodyAndByteLength() throws {
        let body = Data("{\"text\":\"你好\"}".utf8)
        let bytes = Data("POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\nContent-Type: application/json\r\n\r\n".utf8) + body
        var decoder = MessageHTTPDecoder(bodyLimit: 100)
        for byte in bytes { try decoder.append(Data([byte])) }
        XCTAssertEqual(decoder.request?.body, body)
        XCTAssertEqual(decoder.request?.head.path, "/v1/messages")
    }
    func testAmbiguousHTTPHeadersAndPipeliningAreRejected() {
        for headers in ["Content-Length: 0\r\nContent-Length: 1", "Transfer-Encoding: chunked", " Content-Length: 0", "Content-Length: -1", "Content-Length: 999999999999999999999999", "Bad Name: x", "Expect: something-else"] {
            var decoder = MessageHTTPDecoder(bodyLimit: 100)
            XCTAssertThrowsError(try decoder.append(Data("POST /v1/messages HTTP/1.1\r\nHost: localhost\r\n\(headers)\r\n\r\n".utf8)), headers)
        }
        var decoder = MessageHTTPDecoder(bodyLimit: 100)
        XCTAssertThrowsError(try decoder.append(Data("GET /v1/health HTTP/1.1\r\nHost: localhost\r\n\r\nGET / HTTP/1.1\r\n\r\n".utf8)))
    }
    func testBodyAndHeaderCapsApplyBeforeCompletion() {
        var decoder = MessageHTTPDecoder(bodyLimit: 4)
        XCTAssertThrowsError(try decoder.append(Data("POST /v1/uploads HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\n".utf8)))
        var header = MessageHTTPDecoder(bodyLimit: 1_000_000)
        XCTAssertThrowsError(try header.append(Data(repeating: 65, count: 16_385)))
    }
    func testBearerRequiresExactKeyAndRejectsMissingOrInjectedValues() {
        XCTAssertTrue(MessageAPIAuthentication.accepts("Bearer " + token, token: token))
        XCTAssertTrue(MessageAPIAuthentication.accepts("bearer " + token, token: token))
        for value in [nil, "", token, "Bearer  " + token, "Bearer " + String(repeating: "b", count: 64), "Bearer " + token + "\n"] {
            XCTAssertFalse(MessageAPIAuthentication.accepts(value, token: token))
        }
    }
    func testSettingsDefaultLocalAndBoundPlaybackMemoryAndPort() throws {
        var settings = MessageAPISettings(token: token)
        try settings.validate(); XCTAssertEqual(settings.listenHost, "127.0.0.1")
        settings.listenHost = "attacker.invalid"; XCTAssertThrowsError(try settings.validate())
        settings.listenHost = "127.0.0.1"; settings.maxUploadMiB = 1000; XCTAssertThrowsError(try settings.validate())
        settings.maxUploadMiB = 25; settings.volume = .nan; XCTAssertThrowsError(try settings.validate())
        settings.volume = 0.5; settings.port = 80; XCTAssertThrowsError(try settings.validate())
    }
    func testMessageNeedsValidConversationAndRegisteredUploadReference() throws {
        try IncomingMessageSubmission(kind: .text, text: "hello", conversationID: "agent_1").validate()
        XCTAssertThrowsError(try IncomingMessageSubmission(kind: .text, text: "   ").validate())
        XCTAssertThrowsError(try IncomingMessageSubmission(kind: .image).validate())
        XCTAssertThrowsError(try IncomingMessageSubmission(kind: .text, text: "hello", conversationID: "../private").validate())
        XCTAssertThrowsError(try IncomingMessageSubmission(kind: .text, text: String(repeating: "x", count: 8001)).validate())
        try IncomingMessageSubmission(kind: .video, uploadID: UUID()).validate()
    }
    func testResponseLengthCountsBytesAndClosesConnection() {
        let response = MessageHTTPResponse(json: ["status": "已接收"])
        let head = String(decoding: response.bytes, as: UTF8.self)
        XCTAssertTrue(head.contains("Content-Length: \(response.body.count)\r\n"))
        XCTAssertTrue(head.contains("Connection: close\r\n"))
    }
    func testContinueHeaderCanBeAuthenticatedBeforeReadingBody() throws {
        var decoder = MessageHTTPDecoder(bodyLimit: 100)
        try decoder.append(Data("POST /v1/uploads HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\n".utf8))
        XCTAssertEqual(decoder.head?.headers["expect"], "100-continue")
        XCTAssertNil(decoder.request)
        try decoder.append(Data("abc".utf8))
        XCTAssertEqual(decoder.request?.body, Data("abc".utf8))
    }

}
