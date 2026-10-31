import Foundation
import ImageIO
import WhaleCore

actor MessageAPIService {
    private struct Upload { let file: URL; let kind: IncomingMessageKind; let created: Date; let bytes: Int; var claimed = false }
    private var uploads: [UUID: Upload] = [:]
    private var records: [UUID: [String: String]] = [:]
    private var recordOrder: [UUID] = []
    private var settings: MessageAPISettings
    private let directory: URL
    private let conversations: MessageConversationStore
    private let receive: @Sendable (IncomingMessage) async -> Bool
    private let patchSettings: @Sendable (Data) async -> MessageAPISettings?
    init(settings: MessageAPISettings, directory: URL, conversations: MessageConversationStore,
         receive: @escaping @Sendable (IncomingMessage) async -> Bool,
         patchSettings: @escaping @Sendable (Data) async -> MessageAPISettings?) {
        self.settings = settings; self.directory = directory; self.conversations = conversations; self.receive = receive; self.patchSettings = patchSettings
    }
    func update(_ settings: MessageAPISettings) { self.settings = settings }
    func handle(_ request: MessageHTTPRequest) async -> MessageHTTPResponse {
        guard settings.enabled else { return .init(status: 503, json: ["error": "disabled"]) }
        guard !Task.isCancelled else { return .init(status: 503, json: ["error": "stopping"]) }
        prune()
        let head = request.head
        switch (head.method, head.path) {
        case ("GET", "/v1/health"):
            return .init(json: ["status": "ok", "api_version": "1"])
        case ("GET", "/v1/settings"):
            guard var object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))) as? [String: Any] else { return failure() }
            object.removeValue(forKey: "token")
            return .init(body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8))
        case ("PATCH", "/v1/settings"):
            guard let updated = await patchSettings(request.body) else { return .init(status: 422, json: ["error": "invalid_or_local_only_setting"]) }
            settings = updated
            return .init(json: ["status": "saved"])
        case ("GET", "/v1/outbox"):
            return await conversations.outboxResponse(target: head.target)
        case ("POST", "/v1/outbox/ack"):
            return await conversations.acknowledge(request.body)
        case ("POST", "/v1/uploads"):
            return upload(request)
        case ("POST", "/v1/messages"):
            guard head.headers["content-type"]?.split(separator: ";").first?.lowercased() == "application/json",
                  let raw = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  Set(raw.keys).isSubset(of: ["type", "text", "title", "upload_id", "conversation_id", "sender"]),
                  let submission = try? JSONDecoder().decode(IncomingMessageSubmission.self, from: request.body),
                  (try? submission.validate()) != nil else { return .init(status: 422, json: ["error": "invalid_message"]) }
            var file: URL?
            if let id = submission.uploadID {
                guard let item = uploads[id], !item.claimed, item.kind == submission.kind else { return .init(status: 409, json: ["error": "upload_unavailable_or_wrong_type"]) }
                file = item.file; uploads[id]?.claimed = true
            }
            let message = IncomingMessage(submission: submission, file: file)
            records[message.id] = ["id": message.id.uuidString, "type": submission.kind.rawValue, "status": "queued"]
            guard await receive(message) else {
                records.removeValue(forKey: message.id)
                if let id = submission.uploadID { uploads[id]?.claimed = false }
                return .init(status: 429, json: ["error": "queue_full_or_disabled"])
            }
            recordOrder.append(message.id)
            while recordOrder.count > 100 { records.removeValue(forKey: recordOrder.removeFirst()) }
            return .init(status: 202, json: ["id": message.id.uuidString, "status": "queued"])
        default:
            if head.method == "GET", head.path == "/v1/conversations" || head.path.hasPrefix("/v1/conversations/") {
                return await conversations.historyResponse(target: head.path)
            }
            if head.method == "GET", head.path.hasPrefix("/v1/messages/"),
               let id = UUID(uuidString: String(head.path.dropFirst("/v1/messages/".count))), let record = records[id] {
                return .init(json: record)
            }
            return .init(status: 404, json: ["error": "not_found"])
        }
    }
    func delivered(_ message: IncomingMessage, status: String) {
        records[message.id]?["status"] = status
        guard !["playing", "deferred", "queued"].contains(status), let id = message.submission.uploadID,
              let item = uploads.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: item.file)
    }
    private func upload(_ request: MessageHTTPRequest) -> MessageHTTPResponse {
        let type = request.head.headers["content-type"]?.split(separator: ";").first.map { $0.lowercased() } ?? ""
        let formats: [String: (IncomingMessageKind, String)] = [
            "image/png": (.image, "png"), "image/jpeg": (.image, "jpg"), "image/webp": (.image, "webp"), "image/gif": (.image, "gif"),
            "audio/mpeg": (.audio, "mp3"), "audio/mp4": (.audio, "m4a"), "audio/x-m4a": (.audio, "m4a"), "audio/wav": (.audio, "wav"), "audio/x-wav": (.audio, "wav"), "audio/aac": (.audio, "aac"), "audio/flac": (.audio, "flac"),
            "video/mp4": (.video, "mp4"), "video/quicktime": (.video, "mov"), "video/x-m4v": (.video, "m4v")]
        guard let (kind, ext) = formats[type] else { return .init(status: 415, json: ["error": "unsupported_media_type"]) }
        guard !request.body.isEmpty, request.body.count <= settings.maxUploadBytes else { return .init(status: 413, json: ["error": "upload_size"]) }
        guard uploads.count < 50, storedBytes() + request.body.count <= 256 * 1_048_576 else { return .init(status: 507, json: ["error": "media_storage_limit"]) }
        if kind == .image {
            guard let source = CGImageSourceCreateWithData(request.body as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 32768, height <= 32768,
                  width * height <= 100_000_000 else { return .init(status: 422, json: ["error": "invalid_image"]) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let id = UUID(), file = directory.appendingPathComponent(id.uuidString + "." + ext)
            try request.body.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            uploads[id] = Upload(file: file, kind: kind, created: Date(), bytes: request.body.count)
            return .init(status: 201, json: ["upload_id": id.uuidString, "type": kind.rawValue])
        } catch { return failure() }
    }
    func maintenance() { prune() }
    private func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let known = Set(uploads.values.map(\.file))
        for file in files where !known.contains(file) && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(modified) > 600 { try? FileManager.default.removeItem(at: file) }
        }
        for (id, upload) in uploads where !upload.claimed && Date().timeIntervalSince(upload.created) > 600 {
            try? FileManager.default.removeItem(at: upload.file); uploads.removeValue(forKey: id)
        }
    }
    private func storedBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    private func failure() -> MessageHTTPResponse { .init(status: 500, json: ["error": "storage_error"]) }
}
