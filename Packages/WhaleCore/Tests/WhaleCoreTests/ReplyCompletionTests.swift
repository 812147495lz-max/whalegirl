import XCTest
@testable import WhaleCore
final class ReplyCompletionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func event(_ type: String = "agent.turn_completed", source: EventSource = .codex, parent: String? = nil,
               provider: String? = nil, seconds: Double = 0, sequence: UInt64? = nil) -> WhaleEvent {
        .init(source: source, sourceInstance: "fixture", sessionId: "root", parentSessionId: parent,
              eventType: type, occurredAt: now.addingTimeInterval(seconds), sequence: sequence, severity: .success,
              metadata: provider.map { ["provider":$0] })
    }
    func testRoutineCompletionsNeverPushButActionRequiredStillDoes() {
        for parent in [nil, "parent"] as [String?] {
            for type in ["agent.turn_completed", "agent.session_completed"] {
                XCTAssertFalse(NotificationPolicy.shouldDeliverSystemNotification(for: event(type, parent: parent)))
            }
        }
        XCTAssertTrue(NotificationPolicy.shouldDeliverSystemNotification(for: event("agent.waiting_approval")))
        XCTAssertTrue(NotificationPolicy.shouldDeliverSystemNotification(for: event("agent.failed")))
    }
    func testNamesRootOnlyAndNoToolOrSessionEndFalseCompletion() {
        var tracker = ReplyCompletionTracker()
        XCTAssertNil(tracker.ingest(event(parent: "parent"), now: now))
        XCTAssertNil(tracker.ingest(event("agent.tool_finished"), now: now))
        XCTAssertNil(tracker.ingest(event("agent.session_completed"), now: now))
        XCTAssertNil(tracker.ingest(event("agent.failed"), now: now))
        XCTAssertEqual(tracker.ingest(event(), now: now), "Codex")
        XCTAssertEqual(tracker.ingest(event(source: .dsh), now: now), "DeepSeek Harness")
        for (id, name) in [("gemini","Gemini"),("grok","Grok"),("claudecc","Claude Code"),("cursor","Cursor"),("copilot","GitHub Copilot"),("opencode","OpenCode")] {
            var separate = ReplyCompletionTracker()
            XCTAssertEqual(separate.ingest(event(source: .remote, provider: id), now: now), name)
        }
    }
    func testDuplicateStaleOutOfOrderAndNextTurnRearm() {
        var tracker = ReplyCompletionTracker()
        XCTAssertEqual(tracker.ingest(event(sequence: 2), now: now), "Codex")
        XCTAssertNil(tracker.ingest(event(sequence: 3), now: now))
        XCTAssertNil(tracker.ingest(event("agent.working", sequence: 1), now: now))
        XCTAssertNil(tracker.ingest(event(sequence: 4), now: now))
        _ = tracker.ingest(event("agent.working", seconds: 1, sequence: 5), now: now.addingTimeInterval(1))
        XCTAssertEqual(tracker.ingest(event(seconds: 2, sequence: 6), now: now.addingTimeInterval(2)), "Codex")
        var old = ReplyCompletionTracker()
        XCTAssertNil(old.ingest(event(), now: now.addingTimeInterval(61)))
        XCTAssertNil(old.ingest(event(seconds: 10), now: now))
        XCTAssertNil(old.ingest(event(source: .remote, provider: "bad\nname"), now: now))
    }
}
