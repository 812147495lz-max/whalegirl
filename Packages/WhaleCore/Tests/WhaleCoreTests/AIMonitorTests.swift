import XCTest
@testable import WhaleCore

final class AIMonitorTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    func event(_ type: String, id: String = "child-1", parent: String? = "parent", time: Double = 0, source: EventSource = .dsh, client: String? = nil) -> WhaleEvent {
        .init(source: source, sourceInstance: "fixture", sessionId: id, parentSessionId: parent, eventType: type,
              occurredAt: start.addingTimeInterval(time), severity: .info, metadata: client.map { ["client": $0] })
    }
    func testMainAgentRequiresFreshWorkAndRetiresWithoutChildCollision() throws {
        var roster = AgentCompanionRoster(retirementSeconds: 12, includeRoots: true)
        for type in ["agent.session_started", "agent.heartbeat", "agent.turn_completed"] {
            XCTAssertTrue(roster.ingest(event(type, parent: nil), now: start).isEmpty)
        }
        XCTAssertTrue(roster.ingest(event("agent.working", parent: nil), now: start.addingTimeInterval(61)).isEmpty)
        let work = event("agent.working", parent: nil)
        let root = try XCTUnwrap(AgentCompanionRoster.rootKey(for: work))
        XCTAssertEqual(roster.ingest(work, now: start), [.spawn(root)])
        XCTAssertTrue(roster.ingest(work, now: start).isEmpty)
        let child = try XCTUnwrap(AgentCompanionRoster.key(for: event("agent.working")))
        XCTAssertEqual(roster.ingest(event("agent.working"), now: start), [.spawn(child)])
        XCTAssertNotEqual(root, child)
        var reconnect = AgentCompanionRoster(includeRoots: true)
        XCTAssertEqual(reconnect.ingest(event("agent.heartbeat", parent: nil, client: "dsh-whale-status"), now: start), [.spawn(root)])
        XCTAssertEqual(reconnect.tick(now: start.addingTimeInterval(899)), [])
        _ = reconnect.ingest(event("agent.heartbeat", parent: nil, time: 899, client: "dsh-whale-status"), now: start.addingTimeInterval(899))
        XCTAssertEqual(reconnect.tick(now: start.addingTimeInterval(1200)), [])
        XCTAssertEqual(roster.ingest(event("agent.turn_completed", parent: nil, time: 1), now: start.addingTimeInterval(1)), [.finished(root)])
        _ = roster.ingest(event("agent.heartbeat", parent: nil, time: 2), now: start.addingTimeInterval(2))
        XCTAssertNotNil(roster.entries[root]?.retireAt)
        _ = roster.ingest(event("agent.working", parent: nil, time: 3), now: start.addingTimeInterval(3))
        XCTAssertNil(roster.entries[root]?.retireAt)
        XCTAssertFalse(roster.entries[root]!.dismissed)
    }
    func testRandomRetirementAndSafeShortIdentity() throws {
        var deadlines: [Date] = []
        for index in 0..<12 {
            var roster = AgentCompanionRoster()
            let began = event("agent.working", id: "child-\(index)")
            let key = try XCTUnwrap(AgentCompanionRoster.key(for: began))
            _ = roster.ingest(began, now: start)
            _ = roster.ingest(event("agent.session_completed", id: "child-\(index)", time: 2), now: start.addingTimeInterval(2))
            let deadline = try XCTUnwrap(roster.entries[key]?.retireAt)
            XCTAssertTrue((10...20).contains(deadline.timeIntervalSince(start.addingTimeInterval(2))))
            _ = roster.ingest(event("agent.session_completed", id: "child-\(index)", time: 3), now: start.addingTimeInterval(3))
            XCTAssertEqual(roster.entries[key]?.retireAt, deadline, "Repeated terminal metadata cannot extend lifetime")
            deadlines.append(deadline)
        }
        XCTAssertGreaterThan(Set(deadlines).count, 1)
        XCTAssertTrue(AgentCompanionSpeech.introduction(id: "unit-13", label: "检查设置页面").contains("unit-13"))
        XCTAssertTrue(AgentCompanionSpeech.introduction(id: "unit-13", label: "检查设置页面").contains("检查设置页面"))
        XCTAssertLessThanOrEqual(AgentCompanionSpeech.ending(label: "检查非常长的系统监控设置界面").count, 10)
        XCTAssertNil(AgentCompanionSpeech.safeLabel("修改 /Users/private/file"))
        XCTAssertNil(AgentCompanionSpeech.safeLabel("Bearer credential"))
        XCTAssertEqual(AgentCompanionSpeech.ending(label: nil), "这轮工作结束了")
        XCTAssertEqual(AgentCompanionSpeech.ending(label: "审查代码", disconnected: true), "连接断开先告退")
    }

    func testRootIgnoredEachChildIsUniqueAndCompletionExpiresAtSixtySeconds() {
        var roster = AgentCompanionRoster(retirementSeconds: 60)
        XCTAssertTrue(roster.ingest(event("agent.session_started", parent: nil), now: start).isEmpty)
        let a = event("agent.session_started"), b = event("agent.working", id: "child-2")
        let ka = AgentCompanionRoster.key(for: a)!, kb = AgentCompanionRoster.key(for: b)!
        XCTAssertEqual(roster.ingest(a, now: start), [.spawn(ka)])
        XCTAssertEqual(roster.ingest(a, now: start), [])
        XCTAssertEqual(roster.ingest(b, now: start), [.spawn(kb)])
        XCTAssertEqual(roster.ingest(event("agent.session_completed", time: 10), now: start.addingTimeInterval(10)), [.finished(ka)])
        XCTAssertEqual(roster.ingest(event("agent.session_completed", time: 20), now: start.addingTimeInterval(20)), [])
        XCTAssertEqual(roster.tick(now: start.addingTimeInterval(69.99)), [])
        XCTAssertEqual(roster.tick(now: start.addingTimeInterval(70)), [.close(ka)])
        XCTAssertFalse(roster.entries[kb]!.dismissed)
    }
    func testResumeCancelsRetirementStaleEventsAndManualDismissDoNotRespawn() {
        var roster = AgentCompanionRoster(retirementSeconds: 60)
        let key = AgentCompanionRoster.key(for: event("agent.working"))!
        _ = roster.ingest(event("agent.working"), now: start)
        _ = roster.ingest(event("agent.session_completed", time: 2), now: start.addingTimeInterval(2))
        XCTAssertEqual(roster.ingest(event("agent.heartbeat", time: 3), now: start.addingTimeInterval(3)), [])
        XCTAssertNotNil(roster.entries[key]!.retireAt)
        _ = roster.ingest(event("agent.working", time: 4), now: start.addingTimeInterval(4))
        XCTAssertNil(roster.entries[key]!.retireAt)
        XCTAssertEqual(roster.ingest(event("agent.session_completed", time: 2), now: start.addingTimeInterval(5)), [])
        XCTAssertEqual(roster.tick(now: start.addingTimeInterval(65)), [])
        roster.dismiss(key)
        XCTAssertEqual(roster.ingest(event("agent.heartbeat", time: 66, client: "dsh-whale-status"), now: start.addingTimeInterval(66)), [])
    }
    func testCrossProviderIdentityRecoveryAndConnectionLossAreDistinct() {
        var roster = AgentCompanionRoster(retirementSeconds: 60, leaseSeconds: 120)
        let heartbeat = event("agent.heartbeat", client: "dsh-whale-status")
        let key = AgentCompanionRoster.key(for: heartbeat)!
        XCTAssertEqual(roster.ingest(heartbeat, now: start), [.spawn(key)])
        XCTAssertNotEqual(key, AgentCompanionRoster.key(for: event("agent.working", source: .codex)))
        XCTAssertEqual(roster.tick(now: start.addingTimeInterval(120)), [.disconnected(key)])
        XCTAssertEqual(roster.tick(now: start.addingTimeInterval(180)), [.close(key)])
        XCTAssertEqual(roster.ingest(event("agent.working", time: 181), now: start.addingTimeInterval(181)), [.spawn(key)])
    }
    func testFreshDSHEndRecoversMissingStartAndRetiresAtOriginalDeadline() {
        var roster = AgentCompanionRoster(retirementSeconds: 60)
        let end = event("agent.session_completed", client: "dsh-whale-status")
        let key = AgentCompanionRoster.key(for: end)!
        XCTAssertEqual(roster.ingest(end, now: start.addingTimeInterval(5)), [.spawn(key), .finished(key)])
        XCTAssertEqual(roster.ingest(end, now: start.addingTimeInterval(6)), [])
        XCTAssertEqual(roster.tick(now: start.addingTimeInterval(59.9)), [])
        XCTAssertEqual(roster.tick(now: start.addingTimeInterval(60)), [.close(key)])
        var old = AgentCompanionRoster(retirementSeconds: 60)
        XCTAssertEqual(old.ingest(end, now: start.addingTimeInterval(61)), [])
        XCTAssertEqual(old.ingest(event("agent.session_completed", source: .codex), now: start), [])
    }
    func testDelayedKnownEndKeepsOriginalSixtySecondDeadline() {
        var roster = AgentCompanionRoster(retirementSeconds: 60)
        let begin = event("agent.session_started", client: "dsh-whale-status")
        let key = AgentCompanionRoster.key(for: begin)!
        _ = roster.ingest(begin, now: start)
        _ = roster.ingest(event("agent.session_completed", time: 5, client: "dsh-whale-status"), now: start.addingTimeInterval(35))
        XCTAssertEqual(roster.tick(now: start.addingTimeInterval(64)), [])
        XCTAssertEqual(roster.tick(now: start.addingTimeInterval(65)), [.close(key)])
    }
    func testDelayedDSHStartCannotReviveCompletedChildInSameSecond() {
        var roster = AgentCompanionRoster(retirementSeconds: 60)
        func sequenced(_ type: String, _ sequence: UInt64) -> WhaleEvent {
            .init(source: .dsh, sourceInstance: "fixture", sessionId: "child", parentSessionId: "parent",
                  eventType: type, occurredAt: start, sequence: sequence, severity: .info, metadata: ["client":"dsh-whale-status"])
        }
        let end = sequenced("agent.session_completed", 2)
        _ = roster.ingest(end, now: start)
        let key = AgentCompanionRoster.key(for: end)!
        XCTAssertEqual(roster.ingest(sequenced("agent.session_started", 1), now: start), [])
        XCTAssertNotNil(roster.entries[key]?.retireAt)
        _ = roster.ingest(sequenced("agent.working", 3), now: start)
        XCTAssertNil(roster.entries[key]?.retireAt)
    }
    func testCodexWithoutHeartbeatDoesNotExpireWhileStillWorking() {
        var roster = AgentCompanionRoster(retirementSeconds: 60, leaseSeconds: 120)
        _ = roster.ingest(event("agent.session_started", source: .codex), now: start)
        XCTAssertEqual(roster.tick(now: start.addingTimeInterval(3600)), [])
    }
    func testQuotaPeriodsNeverBecomeInventedWeeklyOrHourlyLimits() {
        XCTAssertEqual(AIQuotaWindow(durationSeconds: 18000, remainingPercent: 20).periodTitle, "5小时")
        XCTAssertEqual(AIQuotaWindow(durationSeconds: 604800, remainingPercent: 90).periodTitle, "周")
        XCTAssertEqual(AIQuotaWindow(durationSeconds: 86400, remainingPercent: 80).periodTitle, "1天")
        XCTAssertFalse(AIQuotaWindow(durationSeconds: 0, remainingPercent: 30).isValid)
        XCTAssertTrue(AIQuotaWindow(durationSeconds: 0, remainingPercent: 30, periodLabel: "月额度").isValid)
        XCTAssertEqual(AIQuotaWindow(durationSeconds: 0, remainingPercent: 30, periodLabel: "月额度").periodTitle, "月额度")
        XCTAssertFalse(AIQuotaWindow(durationSeconds: 3600, remainingPercent: .nan).isValid)
        XCTAssertFalse(AIQuotaWindow(durationSeconds: 3600, remainingPercent: 101).isValid)
        XCTAssertFalse(AIQuotaBalance(currency: "CNY", amount: "4evil").isValid)
        XCTAssertTrue(AIQuotaBalance(currency: "CNY", amount: "6.1600867").isValid)
        XCTAssertTrue(AIMonitorPreferences.defaults.isValid)
        XCTAssertTrue(AIQuotaReading(providerId: "fixture", state: "ready", fetchedAt: start).isStale(at: start.addingTimeInterval(301)))
    }
}
