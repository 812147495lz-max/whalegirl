import AppKit
import AVKit
import XCTest
import WhaleCore
@testable import WhaleGirl

private actor MessageAPICapture {
    var items: [IncomingMessage] = []
    func accept(_ item: IncomingMessage) -> Bool { items.append(item); return true }
    func count() -> Int { items.count }
}

@MainActor
extension WhaleGirlAppTests {
    private func messageFixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/MessageAPI/" + name)
    }
    private func messageRequest(_ method: String, _ path: String, data: Data = Data(), type: String = "application/json") throws -> MessageHTTPRequest {
        var decoder = MessageHTTPDecoder(bodyLimit: 64 * 1_048_576)
        try decoder.append(Data("\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\n\r\n".utf8) + data)
        return try XCTUnwrap(decoder.request)
    }
    func testMessageHTTPAuthenticatedConversationOutboxAndAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversations = MessageConversationStore(file: directory.appendingPathComponent("conversations.json"))
        let capture = MessageAPICapture()
        var settings = MessageAPISettings(token: String(repeating: "f", count: 64)); settings.port = 0
        let service = MessageAPIService(settings: settings, directory: directory.appendingPathComponent("media"), conversations: conversations,
            receive: { item in
                await MainActor.run { try? conversations.recordIncoming(item) }
                return await capture.accept(item)
            }, patchSettings: { _ in nil })
        let server = try MessageHTTPServer(settings: settings, handler: { await service.handle($0) }, onState: { _ in })
        server.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while server.port == nil || server.port == 0 {
            guard ContinuousClock.now < deadline else { XCTFail("Listener did not bind"); await server.stop(); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try XCTUnwrap(server.port)
        let session = URLSession(configuration: .ephemeral)
        func call(_ method: String, _ path: String, _ body: Data = Data(), authorized: Bool = true) async throws -> (Data, Int) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!); request.httpMethod = method
            request.timeoutInterval = 5
            if authorized { request.setValue("Bearer " + settings.token, forHTTPHeaderField: "Authorization") }
            if !body.isEmpty {
                request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("100-continue", forHTTPHeaderField: "Expect")
            }
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        do {
            let (_, rejected) = try await call("GET", "/v1/health", authorized: false); XCTAssertEqual(rejected, 401)
            let (_, healthy) = try await call("GET", "/v1/health"); XCTAssertEqual(healthy, 200)
            let (body, status) = try await call("POST", "/v1/messages", JSONEncoder().encode(IncomingMessageSubmission(kind: .text, text: "hello", conversationID: "agent_a")))
            XCTAssertEqual(status, 202)
            let count = await capture.count(); XCTAssertEqual(count, 1)
            let accepted = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String]); let id = try XCTUnwrap(UUID(uuidString: accepted["id"] ?? ""))
            let reply = try conversations.send(text: "received", conversationID: "agent_a", replyTo: id)
            let (outbox, outStatus) = try await call("GET", "/v1/outbox?conversation_id=agent_a"); XCTAssertEqual(outStatus, 200)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outbox) as? [String: Any]); let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 1); XCTAssertEqual(messages[0]["text"] as? String, "received"); XCTAssertEqual(messages[0]["reply_to"] as? String, id.uuidString)
            let (_, ackStatus) = try await call("POST", "/v1/outbox/ack", JSONSerialization.data(withJSONObject: ["ids": [reply.uuidString]])); XCTAssertEqual(ackStatus, 200)
            let restored = MessageConversationStore(file: conversations.file)
            XCTAssertTrue(restored.entries.last?.acknowledged == true)
            let (empty, _) = try await call("GET", "/v1/outbox")
            let emptyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: empty) as? [String: Any]); XCTAssertEqual((emptyObject["messages"] as? [Any])?.count, 0)
        } catch { await server.stop(); throw error }
        await server.stop()
    }
    func testMessageUploadTypeReferencesAndNoArbitraryURLs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = MessageAPISettings(token: String(repeating: "a", count: 64))
        let conversations = MessageConversationStore(file: directory.appendingPathComponent("conversation.json"))
        let capture = MessageAPICapture()
        let service = MessageAPIService(settings: settings, directory: directory.appendingPathComponent("media"), conversations: conversations, receive: { await capture.accept($0) }, patchSettings: { _ in nil })
        let uploaded = await service.handle(try messageRequest("POST", "/v1/uploads", data: Data(contentsOf: messageFixture("image.png")), type: "image/png"))
        XCTAssertEqual(uploaded.status, 201)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: uploaded.body) as? [String: String]); let uploadID = try XCTUnwrap(UUID(uuidString: value["upload_id"] ?? ""))
        let accepted = await service.handle(try messageRequest("POST", "/v1/messages", data: JSONEncoder().encode(IncomingMessageSubmission(kind: .image, text: "image", uploadID: uploadID))))
        XCTAssertEqual(accepted.status, 202)
        let repeated = await service.handle(try messageRequest("POST", "/v1/messages", data: JSONEncoder().encode(IncomingMessageSubmission(kind: .image, uploadID: uploadID))))
        XCTAssertEqual(repeated.status, 409)
        let unsafe = await service.handle(try messageRequest("POST", "/v1/messages", data: Data("{\"type\":\"image\",\"url\":\"file:///etc/passwd\"}".utf8)))
        XCTAssertEqual(unsafe.status, 422)
        let invalid = await service.handle(try messageRequest("POST", "/v1/uploads", data: Data("not an image".utf8), type: "image/png"))
        XCTAssertEqual(invalid.status, 422)
        let count = await capture.count(); XCTAssertEqual(count, 1)
    }
    func testMessageRepliesSurviveRestartAndRemainIsolatedByConversation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json"); let store = MessageConversationStore(file: file)
        try store.send(text: "first", conversationID: "one"); try store.send(text: "second", conversationID: "two")
        let restored = MessageConversationStore(file: file)
        XCTAssertEqual(restored.entries.count, 2)
        let response = restored.outboxResponse(target: "/v1/outbox?conversation_id=two")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any]); let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1); XCTAssertEqual(messages[0]["text"] as? String, "second")
        XCTAssertThrowsError(try restored.send(text: "bad", conversationID: "../secret"))
    }
    func testMessageMediaBubblesDecodeImageAudioAndVideoAndReleasePlayers() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let anchor = CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 100, width: 80, height: 80)
        var settings = MessageAPISettings(token: String(repeating: "a", count: 64)); settings.imageSeconds = 1; settings.volume = 0
        let bubble = MessageBubbleController()
        for (kind, name) in [(IncomingMessageKind.image, "image.png"), (.audio, "audio.wav"), (.video, "video.mp4")] {
            let message = IncomingMessage(submission: .init(kind: kind, text: "Media test"), file: messageFixture(name))
            var started = false
            let result = await bubble.present(message, settings: settings, anchor: anchor, visibleFrame: screen.visibleFrame,
                onReply: { _ in true }, onOpenConversation: {}, onStarted: { started = true })
            XCTAssertTrue(started, name); XCTAssertEqual(result, .completed, name); XCTAssertFalse(bubble.isVisible)
        }
    }
    func testMessageTextBubbleReplyPersistsCorrelatedOutgoingMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MessageConversationStore(file: directory.appendingPathComponent("journal.json"))
        let screen = try XCTUnwrap(NSScreen.main); let bubble = MessageBubbleController()
        let message = IncomingMessage(submission: .init(kind: .text, text: "hello", conversationID: "thread_a"), file: nil)
        let settings = MessageAPISettings(token: String(repeating: "a", count: 64))
        let task = Task { @MainActor in
            await bubble.present(message, settings: settings, anchor: CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 100, width: 80, height: 80), visibleFrame: screen.visibleFrame,
                onReply: { text in (try? store.send(text: text, conversationID: "thread_a", replyTo: message.id)) != nil }, onOpenConversation: {}, onStarted: {})
        }
        try await waitForWanderingCondition(timeout: 5) { bubble.isVisible }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "鲸鱼娘消息" && $0.isVisible })
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let children = views(try XCTUnwrap(panel.contentView))
        let field = try XCTUnwrap(children.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "回复…" })
        field.stringValue = "你好"
        let send = try XCTUnwrap(children.compactMap { $0 as? NSButton }.first { $0.title == "发送" }); send.performClick(nil)
        let result = await task.value; XCTAssertEqual(result, .completed)
        XCTAssertEqual(store.entries.last?.replyTo, message.id); XCTAssertEqual(store.entries.last?.text, "你好")
        XCTAssertFalse(bubble.isVisible)
    }
    func testMessageExternalPresentationSettingsPersistWithoutChangingCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = MessageInboxController(configurationURL: directory.appendingPathComponent("settings.json"), mediaDirectory: directory.appendingPathComponent("media"))
        var settings = MessageAPISettings(token: String(repeating: "a", count: 64)); settings.enabled = false
        try await inbox.save(settings)
        let result = inbox.patchPresentation(Data("{\"volume\":0.25,\"textSeconds\":23}".utf8))
        XCTAssertEqual(result?.volume, 0.25); XCTAssertEqual(result?.textSeconds, 23)
        let saved = try JSONDecoder().decode(MessageAPISettings.self, from: Data(contentsOf: inbox.configurationURL))
        XCTAssertEqual(saved.volume, 0.25); XCTAssertEqual(saved.token, settings.token)
        XCTAssertNil(inbox.patchPresentation(Data("{\"listenHost\":\"0.0.0.0\"}".utf8)))
        XCTAssertNil(inbox.patchPresentation(Data("{\"token\":\"invalid\"}".utf8)))
        XCTAssertNil(inbox.patchPresentation(Data("{\"volume\":10}".utf8)))
        XCTAssertEqual(inbox.settings.volume, 0.25)
        inbox.stop()
    }

    func testMessageDamagedJournalIsPreservedInsteadOfOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json"), original = Data("not valid JSON".utf8)
        try original.write(to: file)
        let store = MessageConversationStore(file: file)
        XCTAssertTrue(store.loadFailed)
        XCTAssertThrowsError(try store.send(text: "hello", conversationID: "default"))
        XCTAssertEqual(store.outboxResponse(target: "/v1/outbox").status, 503)
        XCTAssertEqual(store.acknowledge(try JSONSerialization.data(withJSONObject: ["ids": [UUID().uuidString]])).status, 500)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testConversationWindowCanSelectChannelAndSendProactively() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MessageConversationStore(file: directory.appendingPathComponent("journal.json"))
        try store.send(text: "first", conversationID: "agent_a")
        try store.send(text: "second", conversationID: "agent_b")
        let controller = MessageConversationWindow(store: store)
        controller.show(conversationID: "agent_a")
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "鲸鱼娘 · 对话" && $0.isVisible })
        defer { window.close() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let nodes = views(try XCTUnwrap(window.contentView))
        let conversation = try XCTUnwrap(nodes.compactMap { $0 as? NSComboBox }.first)
        conversation.selectItem(withObjectValue: "agent_b")
        controller.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: conversation))
        XCTAssertEqual(conversation.stringValue, "agent_b")
        let field = try XCTUnwrap(nodes.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "输入回复或主动发送的消息" })
        field.stringValue = "主动消息"
        let send = try XCTUnwrap(nodes.compactMap { $0 as? NSButton }.first { $0.title == "发送" }); send.performClick(nil)
        XCTAssertEqual(store.entries.last?.conversationID, "agent_b")
        XCTAssertEqual(store.entries.last?.text, "主动消息")
        XCTAssertNil(store.entries.last?.replyTo)
    }

}
