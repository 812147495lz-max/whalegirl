import Foundation

public enum EventSource: String, Codable, CaseIterable, Sendable {
    case codex, dsh, mail, system, whale, remote
}

public enum EventSeverity: String, Codable, CaseIterable, Sendable {
    case info, success, warning, error, action_required
}

public enum PrivacyClass: String, Codable, CaseIterable, Sendable {
    case metadata_only, local_sensitive
}

public enum DisplayKind: String, Codable, CaseIterable, Sendable {
    case app, session, none
}

public struct DisplayTarget: Codable, Equatable, Sendable {
    public let kind: DisplayKind
    public let bundleId: String?
    public let uri: String?

    public init(kind: DisplayKind, bundleId: String? = nil, uri: String? = nil) {
        self.kind = kind
        self.bundleId = bundleId
        self.uri = uri
    }
}

public struct WhaleEvent: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let eventId: UUID
    public let source: EventSource
    public let sourceInstance: String
    public let sessionId: String?
    public let parentSessionId: String?
    public let projectKey: String?
    public let eventType: String
    public let occurredAt: Date
    public let receivedAt: Date?
    public let sequence: UInt64?
    public let severity: EventSeverity
    public let summary: String?
    public let displayTarget: DisplayTarget?
    public let metadata: [String: String]?
    public let privacyClass: PrivacyClass

    public var id: String {
        source.rawValue + ":" + sourceInstance + ":" + eventId.uuidString.lowercased()
    }

    public init(
        schemaVersion: Int = 1,
        eventId: UUID = UUID(),
        source: EventSource,
        sourceInstance: String,
        sessionId: String? = nil,
        parentSessionId: String? = nil,
        projectKey: String? = nil,
        eventType: String,
        occurredAt: Date,
        receivedAt: Date? = nil,
        sequence: UInt64? = nil,
        severity: EventSeverity,
        summary: String? = nil,
        displayTarget: DisplayTarget? = nil,
        metadata: [String: String]? = nil,
        privacyClass: PrivacyClass = .metadata_only
    ) {
        self.schemaVersion = schemaVersion
        self.eventId = eventId
        self.source = source
        self.sourceInstance = sourceInstance
        self.sessionId = sessionId
        self.parentSessionId = parentSessionId
        self.projectKey = projectKey
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.receivedAt = receivedAt
        self.sequence = sequence
        self.severity = severity
        self.summary = summary
        self.displayTarget = displayTarget
        self.metadata = metadata
        self.privacyClass = privacyClass
    }

    public func received(at date: Date) -> WhaleEvent {
        WhaleEvent(
            schemaVersion: schemaVersion,
            eventId: eventId,
            source: source,
            sourceInstance: sourceInstance,
            sessionId: sessionId,
            parentSessionId: parentSessionId,
            projectKey: projectKey,
            eventType: eventType,
            occurredAt: occurredAt,
            receivedAt: date,
            sequence: sequence,
            severity: severity,
            summary: summary,
            displayTarget: displayTarget,
            metadata: metadata,
            privacyClass: privacyClass
        )
    }
}

public enum WhaleEventContract {
    public static let allowedEventTypes: Set<String> = [
        "agent.session_started", "agent.working", "agent.tool_started", "agent.tool_finished",
        "agent.waiting_input", "agent.waiting_approval", "agent.turn_completed",
        "agent.session_completed", "agent.failed", "agent.interrupted", "agent.disconnected",
        "agent.heartbeat", "mail.new", "mail.read", "mail.connection_lost", "system.load_high",
        "system.battery_low", "system.woke", "system.slept", "system.idle_started",
        "system.user_returned", "pet.clicked", "pet.hovered", "pet.drag_started",
        "pet.drag_finished", "pet.roam_finished"
    ]

    public static let metadataKeys: Set<String> = ["client", "approvalKind", "provider", "agentLabel"]
    public static let maximumFrameBytes = 16 * 1024
    public static let maximumSummaryScalars = 200
    public static let maximumSummaryBytes = 800
    public static let maximumMetadataBytes = 2_048
}

public enum WhaleEventCodecError: Error, Equatable, CustomStringConvertible {
    case frameTooLarge
    case invalidJSON
    case missingField(String)
    case unknownField(String)
    case unsupportedSchema
    case invalidTimestamp(String)
    case unknownEventType
    case invalidSession
    case invalidSourceInstance
    case invalidProjectKey
    case summaryTooLong
    case sequenceOutOfRange
    case invalidMetadata
    case metadataTooLarge
    case invalidDisplayTarget

    public var description: String {
        switch self {
        case .frameTooLarge: "frame_too_large"
        case .invalidJSON: "invalid_json"
        case let .missingField(field): "missing_field:\(field)"
        case let .unknownField(field): "unknown_field:\(field)"
        case .unsupportedSchema: "unsupported_schema"
        case let .invalidTimestamp(field): "invalid_timestamp:\(field)"
        case .unknownEventType: "unknown_event_type"
        case .invalidSession: "invalid_session"
        case .invalidSourceInstance: "invalid_source_instance"
        case .invalidProjectKey: "invalid_project_key"
        case .summaryTooLong: "summary_too_long"
        case .sequenceOutOfRange: "sequence_out_of_range"
        case .invalidMetadata: "invalid_metadata"
        case .metadataTooLarge: "metadata_too_large"
        case .invalidDisplayTarget: "invalid_display_target"
        }
    }
}

public enum WhaleEventCodec {
    public static let v1SecondsPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$"#

    private static let topLevelKeys: Set<String> = [
        "schemaVersion", "eventId", "source", "sourceInstance", "sessionId", "parentSessionId",
        "projectKey", "eventType", "occurredAt", "receivedAt", "sequence", "severity", "summary",
        "displayTarget", "metadata", "privacyClass"
    ]
    private static let requiredKeys: Set<String> = [
        "schemaVersion", "eventId", "source", "sourceInstance", "eventType", "occurredAt", "severity",
        "privacyClass"
    ]
    private static let displayTargetKeys: Set<String> = ["kind", "bundleId", "uri"]

    public static func decode(_ data: Data) throws -> WhaleEvent {
        guard data.count <= WhaleEventContract.maximumFrameBytes else { throw WhaleEventCodecError.frameTooLarge }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw WhaleEventCodecError.invalidJSON
        }
        guard let dictionary = object as? [String: Any] else { throw WhaleEventCodecError.invalidJSON }

        for key in dictionary.keys where !topLevelKeys.contains(key) {
            throw WhaleEventCodecError.unknownField(key)
        }
        for key in requiredKeys where dictionary[key] == nil {
            throw WhaleEventCodecError.missingField(key)
        }
        if let target = dictionary["displayTarget"], !(target is NSNull) {
            guard let targetDictionary = target as? [String: Any] else { throw WhaleEventCodecError.invalidDisplayTarget }
            for key in targetDictionary.keys where !displayTargetKeys.contains(key) {
                throw WhaleEventCodecError.unknownField("displayTarget.\(key)")
            }
            guard targetDictionary["kind"] != nil else { throw WhaleEventCodecError.missingField("displayTarget.kind") }
        }
        try validateTimestamp(dictionary["occurredAt"], field: "occurredAt", required: true)
        try validateTimestamp(dictionary["receivedAt"], field: "receivedAt", required: false)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event: WhaleEvent
        do {
            event = try decoder.decode(WhaleEvent.self, from: data)
        } catch {
            throw WhaleEventCodecError.invalidJSON
        }
        try validate(event)
        return event
    }

    public static func encode(_ event: WhaleEvent) throws -> Data {
        try validate(event)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(event)
    }

    public static func validate(_ event: WhaleEvent) throws {
        guard event.schemaVersion == 1 else { throw WhaleEventCodecError.unsupportedSchema }
        guard WhaleEventContract.allowedEventTypes.contains(event.eventType) else { throw WhaleEventCodecError.unknownEventType }
        guard !event.sourceInstance.isEmpty, event.sourceInstance.utf8.count <= 128 else {
            throw WhaleEventCodecError.invalidSourceInstance
        }
        if event.eventType.hasPrefix("agent."), event.sessionId?.isEmpty != false {
            throw WhaleEventCodecError.invalidSession
        }
        if let projectKey = event.projectKey,
           projectKey.hasPrefix("/") || projectKey.hasPrefix("~") || projectKey.utf8.count > 160 {
            throw WhaleEventCodecError.invalidProjectKey
        }
        if let sequence = event.sequence, sequence > UInt64(Int64.max) {
            throw WhaleEventCodecError.sequenceOutOfRange
        }
        if let summary = event.summary,
           summary.unicodeScalars.count > WhaleEventContract.maximumSummaryScalars ||
           summary.utf8.count > WhaleEventContract.maximumSummaryBytes {
            throw WhaleEventCodecError.summaryTooLong
        }
        if let metadata = event.metadata {
            guard Set(metadata.keys).isSubset(of: WhaleEventContract.metadataKeys) else {
                throw WhaleEventCodecError.invalidMetadata
            }
            let bytes = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).count
            guard bytes <= WhaleEventContract.maximumMetadataBytes else { throw WhaleEventCodecError.metadataTooLarge }
        }
        if let target = event.displayTarget {
            if let bundleId = target.bundleId, bundleId.isEmpty || bundleId.utf8.count > 255 {
                throw WhaleEventCodecError.invalidDisplayTarget
            }
            if let uri = target.uri {
                guard let components = URLComponents(string: uri),
                      components.scheme?.lowercased() == "https",
                      components.host?.isEmpty == false else {
                    throw WhaleEventCodecError.invalidDisplayTarget
                }
            }
        }
    }

    private static func validateTimestamp(_ value: Any?, field: String, required: Bool) throws {
        if value == nil || value is NSNull {
            if required { throw WhaleEventCodecError.missingField(field) }
            return
        }
        guard let string = value as? String,
              string.range(of: v1SecondsPattern, options: .regularExpression) != nil else {
            throw WhaleEventCodecError.invalidTimestamp(field)
        }
        guard isCalendarValid(string) else { throw WhaleEventCodecError.invalidTimestamp(field) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard formatter.date(from: string) != nil else { throw WhaleEventCodecError.invalidTimestamp(field) }
    }

    private static func isCalendarValid(_ string: String) -> Bool {
        let characters = Array(string)
        func number(_ start: Int, _ length: Int) -> Int? {
            Int(String(characters[start..<(start + length)]))
        }
        guard characters.count >= 20,
              let year = number(0, 4),
              let month = number(5, 2),
              let day = number(8, 2),
              let hour = number(11, 2),
              let minute = number(14, 2),
              let second = number(17, 2),
              hour < 24, minute < 60, second < 60 else { return false }

        let offsetSeconds: Int
        if characters[19] == "Z" {
            offsetSeconds = 0
        } else {
            guard characters.count == 25,
                  let offsetHour = number(20, 2),
                  let offsetMinute = number(23, 2),
                  offsetHour < 24,
                  offsetMinute < 60 else { return false }
            let sign = characters[19] == "-" ? -1 : 1
            offsetSeconds = sign * ((offsetHour * 60 + offsetMinute) * 60)
        }
        guard let zone = TimeZone(secondsFromGMT: offsetSeconds) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = zone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = calendar.date(from: components) else { return false }
        let roundtrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return roundtrip.year == year && roundtrip.month == month && roundtrip.day == day &&
            roundtrip.hour == hour && roundtrip.minute == minute && roundtrip.second == second
    }
}
