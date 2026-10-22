import Foundation
import Testing
@testable import WhaleCore

struct SessionRegistryTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        source: EventSource = .codex,
        session: String,
        type: String,
        seconds: TimeInterval,
        sequence: UInt64? = nil,
        id: UUID = UUID()
    ) -> WhaleEvent {
        WhaleEvent(
            eventId: id,
            source: source,
            sourceInstance: "local",
            sessionId: session,
            projectKey: "project-\(session)",
            eventType: type,
            occurredAt: base.addingTimeInterval(seconds),
            sequence: sequence,
            severity: type.contains("waiting") ? .action_required : .info,
            summary: type
        )
    }

    @Test func concurrentSessionsRemainIndependent() async {
        let hub = EventHub()
        _ = await hub.ingest(event(session: "one", type: "agent.working", seconds: 1, sequence: 1))
        _ = await hub.ingest(event(source: .dsh, session: "two", type: "agent.waiting_approval", seconds: 2, sequence: 1))
        _ = await hub.ingest(event(session: "one", type: "agent.session_completed", seconds: 3, sequence: 2))
        let sessions = await hub.snapshot().sessions
        #expect(sessions.count == 2)
        #expect(sessions.first(where: { $0.key.sessionId == "one" })?.status == .sessionCompleted)
        #expect(sessions.first(where: { $0.key.sessionId == "two" })?.status == .waitingApproval)
    }

    @Test func sequenceIsAuthoritativeAndHeartbeatDoesNotCreateSession() async {
        let hub = EventHub()
        _ = await hub.ingest(event(session: "s", type: "agent.heartbeat", seconds: 10))
        #expect(await hub.snapshot().sessions.isEmpty)

        _ = await hub.ingest(event(session: "s", type: "agent.working", seconds: 20))
        _ = await hub.ingest(event(session: "s", type: "agent.waiting_approval", seconds: 10, sequence: 1))
        _ = await hub.ingest(event(session: "s", type: "agent.working", seconds: 30))
        #expect(await hub.snapshot().sessions.first?.status == .waitingApproval)

        _ = await hub.ingest(event(session: "s", type: "agent.session_completed", seconds: 5, sequence: 2))
        #expect(await hub.snapshot().sessions.first?.status == .sessionCompleted)
    }

    @Test func duplicateEventDoesNotIncreaseUnreadCount() async {
        let hub = EventHub()
        let identifier = UUID()
        let incoming = event(session: "s", type: "agent.waiting_input", seconds: 1, sequence: 1, id: identifier)
        let first = await hub.ingest(incoming)
        let duplicate = await hub.ingest(incoming)
        #expect(first.disposition == .accepted)
        #expect(duplicate.disposition == .duplicate)
        #expect(await hub.snapshot().sessions.first?.unreadCount == 1)
    }

    @Test func duplicateIdentitySurvivesSnapshotRestore() async {
        let identifier = UUID()
        let incoming = event(session: "persisted", type: "agent.turn_completed", seconds: 1, id: identifier)
        let original = EventHub()
        _ = await original.ingest(incoming)
        let stored = await original.snapshot()

        let restored = EventHub()
        await restored.restore(stored)
        let result = await restored.ingest(incoming)
        #expect(result.disposition == .duplicate)
        #expect(await restored.snapshot().recentEvents.count == 1)
    }

    @Test func approvalHasHigherPriorityThanCompletion() {
        #expect(NotificationPolicy.priority(for: event(session: "s", type: "agent.waiting_approval", seconds: 1)) == 100)
        #expect(NotificationPolicy.priority(for: event(session: "s", type: "agent.turn_completed", seconds: 2)) == 75)
    }

    @Test func framedReaderHandlesSplitAndJoinedFrames() {
        var reader = FramedJSONReader(maximumFrameBytes: 8)
        #expect(reader.append(Data("{\"a\"".utf8)).isEmpty)
        let frames = reader.append(Data(":1}\n{}\r\n".utf8))
        #expect(frames.count == 2)
        #expect((try? frames[0].get()) == Data("{\"a\":1}".utf8))
        #expect((try? frames[1].get()) == Data("{}".utf8))

        #expect(reader.append(Data("123456789\n".utf8)).first == .failure(.frameTooLarge))
    }
}
