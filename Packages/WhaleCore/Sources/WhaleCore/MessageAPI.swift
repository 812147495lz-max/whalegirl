import Foundation

public enum IncomingMessageKind: String, Codable, Sendable { case text, image, audio, video }
public struct MessageAPISettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var listenHost = "127.0.0.1"
    public var port: UInt16 = 38473
    public var token: String
    public var textSeconds = 10.0
    public var imageSeconds = 12.0
    public var maxPlaybackSeconds = 180.0
    public var volume = 0.7
    public var bubbleWidth = 340.0
    public var maxUploadMiB = 25
    public var maxQueue = 20
    public var maxWaitSeconds = 600.0
    public var respectQuietMode = true
    public init(token: String) { self.token = token }
    public var maxUploadBytes: Int { maxUploadMiB * 1_048_576 }
    public func validate() throws {
        guard ["127.0.0.1", "::1", "0.0.0.0"].contains(listenHost), port >= 1024,
              token.utf8.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...120).contains(textSeconds), (1...120).contains(imageSeconds),
              (1...600).contains(maxPlaybackSeconds), (0...1).contains(volume),
              (240...600).contains(bubbleWidth), (1...64).contains(maxUploadMiB),
              (1...50).contains(maxQueue), (10...3600).contains(maxWaitSeconds)
        else { throw MessageAPIError.invalidSettings }
    }
    public func requiresRestart(comparedTo other: Self) -> Bool {
        enabled != other.enabled || listenHost != other.listenHost || port != other.port || token != other.token || maxUploadMiB != other.maxUploadMiB
    }
}
public enum MessageAPIError: Error { case invalidSettings, invalidMessage, malformedHTTP, tooLarge }
public struct IncomingMessageSubmission: Codable, Sendable {
    public let kind: IncomingMessageKind
    public let text: String?
    public let title: String?
    public let uploadID: UUID?
    public let conversationID: String?
    public let sender: String?
    enum CodingKeys: String, CodingKey { case kind = "type", text, title, uploadID = "upload_id", conversationID = "conversation_id", sender }
    public init(kind: IncomingMessageKind, text: String? = nil, title: String? = nil, uploadID: UUID? = nil, conversationID: String? = nil, sender: String? = nil) {
        self.kind = kind; self.text = text; self.title = title; self.uploadID = uploadID; self.conversationID = conversationID; self.sender = sender
    }
    public func validate() throws {
        guard (text?.count ?? 0) <= 8000, (title?.count ?? 0) <= 120, (sender?.count ?? 0) <= 80,
              (conversationID.map { !$0.isEmpty && $0.utf8.count <= 80 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } } ?? true) else { throw MessageAPIError.invalidMessage }
        if kind == .text {
            guard uploadID == nil, !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MessageAPIError.invalidMessage }
        } else if uploadID == nil { throw MessageAPIError.invalidMessage }
    }
}
public struct IncomingMessage: Sendable {
    public let id: UUID
    public let submission: IncomingMessageSubmission
    public let file: URL?
    public let receivedAt: Date
    public init(id: UUID = UUID(), submission: IncomingMessageSubmission, file: URL?, receivedAt: Date = Date()) {
        self.id = id; self.submission = submission; self.file = file; self.receivedAt = receivedAt
    }
}
public enum MessageDelivery: String, Sendable { case completed, dismissed, failed, cancelled, deferred }
public enum MessageAPIAuthentication {
    public static func accepts(_ header: String?, token: String) -> Bool {
        guard let parts = header?.split(separator: " ", omittingEmptySubsequences: false), parts.count == 2,
              parts[0].lowercased() == "bearer" else { return false }
        let supplied = Array(parts[1].utf8), expected = Array(token.utf8)
        guard supplied.count == expected.count, expected.count == 64 else { return false }
        return zip(supplied, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
