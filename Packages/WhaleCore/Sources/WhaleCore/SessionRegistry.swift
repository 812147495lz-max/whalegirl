import Foundation

public struct SessionKey: Hashable, Codable, Sendable {
    public let source: EventSource
    public let sourceInstance: String
    public let sessionId: String

    public init(source: EventSource, sourceInstance: String, sessionId: String) {
        self.source = source
        self.sourceInstance = sourceInstance
        self.sessionId = sessionId
    }
}

public enum AgentSessionStatus: String, Codable, Sendable {
    case working
    case waitingInput
    case waitingApproval
    case turnCompleted
    case sessionCompleted
    case failed
    case interrupted
    case disconnected
}

public struct SessionSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let key: SessionKey
    public var parentSessionId: String?
    public var projectKey: String?
    public var status: AgentSessionStatus
    public var summary: String?
    public var updatedAt: Date
    public var lastObservedAt: Date
    public var lastSequence: UInt64?
    public var unreadCount: Int
    public var needsAttention: Bool

    public init(
        key: SessionKey,
        parentSessionId: String? = nil,
        projectKey: String? = nil,
        status: AgentSessionStatus,
        summary: String? = nil,
        updatedAt: Date,
        lastObservedAt: Date,
        lastSequence: UInt64? = nil,
        unreadCount: Int = 0,
        needsAttention: Bool = false
    ) {
        self.key = key
        self.parentSessionId = parentSessionId
        self.projectKey = projectKey
        self.status = status
        self.summary = summary
        self.updatedAt = updatedAt
        self.lastObservedAt = lastObservedAt
        self.lastSequence = lastSequence
        self.unreadCount = unreadCount
        self.needsAttention = needsAttention
    }

    public var id: String {
        key.source.rawValue + ":" + key.sourceInstance + ":" + key.sessionId
    }
}

public enum SessionReducer {
    public static func reduce(
        current: SessionSnapshot?,
        event: WhaleEvent,
        receivedAt: Date
    ) -> SessionSnapshot? {
        guard event.eventType.hasPrefix("agent."),
              let sessionId = event.sessionId,
              !sessionId.isEmpty else { return current }

        let key = SessionKey(source: event.source, sourceInstance: event.sourceInstance, sessionId: sessionId)
        guard current?.key == key else {
            if event.eventType == "agent.heartbeat" { return nil }
            guard let status = status(for: event.eventType) else { return nil }
            return SessionSnapshot(
                key: key,
                parentSessionId: event.parentSessionId,
                projectKey: event.projectKey,
                status: status,
                summary: event.summary,
                updatedAt: event.occurredAt,
                lastObservedAt: receivedAt,
                lastSequence: event.sequence,
                unreadCount: shouldBecomeUnread(event.eventType) ? 1 : 0,
                needsAttention: needsAttention(event.eventType)
            )
        }

        guard var snapshot = current else { return nil }
        if event.eventType == "agent.heartbeat" {
            snapshot.lastObservedAt = max(snapshot.lastObservedAt, receivedAt)
            return snapshot
        }
        guard shouldApply(event: event, to: snapshot), let newStatus = status(for: event.eventType) else {
            return snapshot
        }

        snapshot.parentSessionId = event.parentSessionId ?? snapshot.parentSessionId
        snapshot.projectKey = event.projectKey ?? snapshot.projectKey
        snapshot.status = newStatus
        snapshot.summary = event.summary ?? snapshot.summary
        snapshot.updatedAt = event.occurredAt
        snapshot.lastObservedAt = receivedAt
        snapshot.lastSequence = event.sequence ?? snapshot.lastSequence
        if shouldBecomeUnread(event.eventType) { snapshot.unreadCount += 1 }
        snapshot.needsAttention = needsAttention(event.eventType)
        return snapshot
    }

    private static func shouldApply(event: WhaleEvent, to current: SessionSnapshot) -> Bool {
        switch (current.lastSequence, event.sequence) {
        case let (.some(previous), .some(incoming)):
            return incoming > previous
        case (.some, .none):
            return false
        case (.none, .some):
            return true
        case (.none, .none):
            return event.occurredAt >= current.updatedAt
        }
    }

    private static func status(for eventType: String) -> AgentSessionStatus? {
        switch eventType {
        case "agent.session_started", "agent.working", "agent.tool_started", "agent.tool_finished": .working
        case "agent.waiting_input": .waitingInput
        case "agent.waiting_approval": .waitingApproval
        case "agent.turn_completed": .turnCompleted
        case "agent.session_completed": .sessionCompleted
        case "agent.failed": .failed
        case "agent.interrupted": .interrupted
        case "agent.disconnected": .disconnected
        default: nil
        }
    }

    private static func shouldBecomeUnread(_ eventType: String) -> Bool {
        switch eventType {
        case "agent.waiting_input", "agent.waiting_approval", "agent.turn_completed", "agent.session_completed", "agent.failed": true
        default: false
        }
    }

    private static func needsAttention(_ eventType: String) -> Bool {
        eventType == "agent.waiting_input" || eventType == "agent.waiting_approval"
    }
}

public struct EventHubSnapshot: Codable, Equatable, Sendable {
    public var sessions: [SessionSnapshot]
    public var recentEvents: [WhaleEvent]
    public var seenEventIDs: [String]
    public var decodeFailureCount: Int

    public init(
        sessions: [SessionSnapshot] = [],
        recentEvents: [WhaleEvent] = [],
        seenEventIDs: [String] = [],
        decodeFailureCount: Int = 0
    ) {
        self.sessions = sessions
        self.recentEvents = recentEvents
        self.seenEventIDs = seenEventIDs
        self.decodeFailureCount = decodeFailureCount
    }
}

public enum EventIngestDisposition: String, Codable, Sendable {
    case accepted
    case duplicate
}

public struct EventIngestResult: Sendable {
    public let disposition: EventIngestDisposition
    public let event: WhaleEvent
    public let session: SessionSnapshot?
    public let priority: Int
}

public actor EventHub {
    private let maximumRecentEvents: Int
    private let maximumSeenEventIDs: Int
    private var sessions: [SessionKey: SessionSnapshot] = [:]
    private var recentEvents: [WhaleEvent] = []
    private var seenEventIDs: Set<String> = []
    private var seenEventOrder: [String] = []
    private var decodeFailureCount = 0

    public init(maximumRecentEvents: Int = 100, maximumSeenEventIDs: Int = 2_048) {
        self.maximumRecentEvents = max(1, maximumRecentEvents)
        self.maximumSeenEventIDs = max(1, maximumSeenEventIDs)
    }

    public func ingest(_ incoming: WhaleEvent, receivedAt: Date = Date()) -> EventIngestResult {
        let event = incoming.received(at: receivedAt)
        let identifier = event.id
        if seenEventIDs.contains(identifier) {
            return EventIngestResult(
                disposition: .duplicate,
                event: event,
                session: session(for: event),
                priority: NotificationPolicy.priority(for: event)
            )
        }
        remember(identifier)

        var updatedSession: SessionSnapshot?
        if let sessionID = event.sessionId, event.eventType.hasPrefix("agent.") {
            let key = SessionKey(source: event.source, sourceInstance: event.sourceInstance, sessionId: sessionID)
            updatedSession = SessionReducer.reduce(current: sessions[key], event: event, receivedAt: receivedAt)
            if let updatedSession { sessions[key] = updatedSession }
        }
        recentEvents.insert(event, at: 0)
        if recentEvents.count > maximumRecentEvents {
            recentEvents.removeLast(recentEvents.count - maximumRecentEvents)
        }
        return EventIngestResult(
            disposition: .accepted,
            event: event,
            session: updatedSession,
            priority: NotificationPolicy.priority(for: event)
        )
    }

    public func recordDecodeFailure() {
        decodeFailureCount += 1
    }

    public func markAllRead() {
        for key in sessions.keys {
            sessions[key]?.unreadCount = 0
        }
    }

    public func snapshot() -> EventHubSnapshot {
        EventHubSnapshot(
            sessions: sessions.values.sorted { lhs, rhs in lhs.updatedAt > rhs.updatedAt },
            recentEvents: recentEvents,
            seenEventIDs: seenEventOrder,
            decodeFailureCount: decodeFailureCount
        )
    }

    public func restore(_ snapshot: EventHubSnapshot) {
        sessions = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.key, $0) })
        recentEvents = Array(snapshot.recentEvents.prefix(maximumRecentEvents))
        decodeFailureCount = snapshot.decodeFailureCount
        seenEventIDs.removeAll(keepingCapacity: true)
        seenEventOrder.removeAll(keepingCapacity: true)
        let persistedIDs = snapshot.seenEventIDs.isEmpty ? recentEvents.reversed().map(\.id) : snapshot.seenEventIDs
        for identifier in persistedIDs { remember(identifier) }
    }

    private func session(for event: WhaleEvent) -> SessionSnapshot? {
        guard let sessionID = event.sessionId else { return nil }
        return sessions[SessionKey(source: event.source, sourceInstance: event.sourceInstance, sessionId: sessionID)]
    }

    private func remember(_ identifier: String) {
        seenEventIDs.insert(identifier)
        seenEventOrder.append(identifier)
        while seenEventOrder.count > maximumSeenEventIDs {
            seenEventIDs.remove(seenEventOrder.removeFirst())
        }
    }
}
