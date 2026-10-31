import AppKit
import WhaleCore

struct MessageConversationEntry: Codable, Sendable {
    let id: UUID
    let conversationID: String
    let direction: String
    let kind: String
    let text: String
    let sender: String?
    let replyTo: UUID?
    let createdAt: Date
    let sequence: Int?
    var acknowledged: Bool
    enum CodingKeys: String, CodingKey {
        case id, direction, kind = "type", text, sender, sequence, acknowledged
        case conversationID = "conversation_id", replyTo = "reply_to", createdAt = "created_at"
    }
}

@MainActor
final class MessageConversationStore {
    static let changed = Notification.Name("WhaleGirl.MessageConversationChanged")
    private struct Journal: Codable { var nextSequence = 1; var entries: [MessageConversationEntry] = [] }
    let file: URL
    private var journal = Journal()
    private(set) var loadFailed = false
    var entries: [MessageConversationEntry] { journal.entries }
    var conversationIDs: [String] { Array(Set(journal.entries.map(\.conversationID)).union(["default"])).sorted() }
    init(file: URL) {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1_048_576 else { throw MessageAPIError.tooLarge }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                journal = try decoder.decode(Journal.self, from: Data(contentsOf: file))
                guard journal.entries.count <= 1000, journal.nextSequence > 0, journal.nextSequence < 1_000_000_000 else { throw MessageAPIError.invalidMessage }
            } catch { loadFailed = true }
        }
    }
    func recordIncoming(_ message: IncomingMessage) throws {
        let value = message.submission
        let entry = MessageConversationEntry(id: message.id, conversationID: value.conversationID ?? "default", direction: "incoming",
            kind: value.kind.rawValue, text: value.text ?? "", sender: value.sender, replyTo: nil,
            createdAt: message.receivedAt, sequence: nil, acknowledged: true)
        try append(entry)
    }
    @discardableResult
    func send(text: String, conversationID: String, replyTo: UUID? = nil) throws -> UUID {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 8000, Self.validConversation(conversationID),
              journal.entries.filter({ $0.direction == "outgoing" && !$0.acknowledged }).count < 500 else { throw MessageAPIError.invalidMessage }
        let entry = MessageConversationEntry(id: UUID(), conversationID: conversationID, direction: "outgoing", kind: "text", text: text,
            sender: "local", replyTo: replyTo, createdAt: Date(), sequence: journal.nextSequence, acknowledged: false)
        try append(entry, advanceSequence: true)
        return entry.id
    }
    private func append(_ entry: MessageConversationEntry, advanceSequence: Bool = false) throws {
        guard !loadFailed else { throw MessageAPIError.invalidMessage }
        var updated = journal
        updated.entries.append(entry)
        if advanceSequence { updated.nextSequence += 1 }
        while updated.entries.count > 1000 {
            guard let index = updated.entries.firstIndex(where: { $0.direction == "incoming" || $0.acknowledged }) else { throw MessageAPIError.tooLarge }
            updated.entries.remove(at: index)
        }
        try persist(updated)
    }
    private func persist(_ value: Journal) throws {
        guard !loadFailed else { throw MessageAPIError.invalidMessage }
        guard file.resolvingSymlinksInPath().standardizedFileURL.path == file.standardizedFileURL.path else { throw MessageAPIError.invalidSettings }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        journal = value
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    func outboxResponse(target: String) -> MessageHTTPResponse {
        guard !loadFailed else { return .init(status: 503, json: ["error": "conversation_storage_error"]) }
        let query = URLComponents(string: "http://localhost" + target)?.queryItems ?? []
        let afterText = query.first(where: { $0.name == "after" })?.value ?? "0"
        let conversation = query.first(where: { $0.name == "conversation_id" })?.value
        guard let after = Int(afterText), after >= 0, conversation.map(Self.validConversation) ?? true else { return .init(status: 400, json: ["error": "invalid_cursor_or_conversation"]) }
        let items = journal.entries.filter { $0.direction == "outgoing" && !$0.acknowledged && ($0.sequence ?? 0) > after && (conversation == nil || $0.conversationID == conversation) }.prefix(100)
        struct Outbox: Encodable { let messages: [MessageConversationEntry]; let next_cursor: Int }
        return encode(Outbox(messages: Array(items), next_cursor: items.last?.sequence ?? after))
    }
    func acknowledge(_ data: Data) -> MessageHTTPResponse {
        struct Acknowledgement: Decodable { let ids: [UUID] }
        guard let value = try? JSONDecoder().decode(Acknowledgement.self, from: data), !value.ids.isEmpty, value.ids.count <= 100 else { return .init(status: 422, json: ["error": "invalid_acknowledgement"]) }
        var updated = journal; let ids = Set(value.ids)
        for i in updated.entries.indices where ids.contains(updated.entries[i].id) && updated.entries[i].direction == "outgoing" { updated.entries[i].acknowledged = true }
        do { try persist(updated); return .init(json: ["status": "acknowledged"]) }
        catch { return .init(status: 500, json: ["error": "conversation_storage_error"]) }
    }
    func historyResponse(target: String) -> MessageHTTPResponse {
        guard !loadFailed else { return .init(status: 503, json: ["error": "conversation_storage_error"]) }
        if target == "/v1/conversations" { return encode(conversationIDs) }
        let id = String(target.dropFirst("/v1/conversations/".count)).removingPercentEncoding ?? ""
        guard Self.validConversation(id) else { return .init(status: 400, json: ["error": "invalid_conversation"]) }
        return encode(journal.entries.filter { $0.conversationID == id })
    }
    private func encode<T: Encodable>(_ value: T) -> MessageHTTPResponse {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return .init(status: 500, json: ["error": "encoding_error"]) }
        return .init(body: data)
    }
    static func validConversation(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 80 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
}
