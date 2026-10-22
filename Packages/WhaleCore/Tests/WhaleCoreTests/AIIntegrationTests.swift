import XCTest
@testable import WhaleCore

final class AIIntegrationTests: XCTestCase {
    func testNativeUsageParsingDoesNotConfuseCurrentWeeklyOrFakeDurations() {
        let data = NativeQuotaText.reading(provider: "gemini", text: "方案的用量限额 当前用量\n已使用 0%\n重置时间10:27\n每周限额 已使用 5%\n高级设置")
        XCTAssertEqual(data.state, "ready")
        XCTAssertEqual(data.windows.map(\.remainingPercent), [100, 95])
        XCTAssertEqual(data.windows.map(\.durationSeconds), [0, 604800])
        XCTAssertEqual(data.windows[0].periodTitle, "当前额度")
        XCTAssertEqual(NativeQuotaText.reading(provider: "grok", text: "Weekly usage 27.5% used On-demand usage 99% used").windows.first?.remainingPercent, 72.5)
        XCTAssertEqual(NativeQuotaText.reading(provider: "gemini", text: "当前用量 已使用 105% 每周限额 以后再来").state, "nativeUnavailable")
        XCTAssertEqual(NativeQuotaText.reading(provider: "gemini", text: "No data").windows, [])
    }
    func testDesktopMigrationPreservesUserChoicesAndSnapshots() {
        var preferences = AIMonitorPreferences(providers: [
            .init(id: "gemini", name: "Gemini", enabled: false, adapter: "codexbar"),
            .init(id: "grok", name: "Mine", adapter: "snapshot"),
            .init(id: "opencode", name: "OpenCode", adapter: "codexbar")])
        XCTAssertTrue(preferences.migrateDesktopSources())
        XCTAssertEqual(preferences.providers[0].adapter, "nativeApp")
        XCTAssertFalse(preferences.providers[0].enabled)
        XCTAssertEqual(preferences.providers[1].adapter, "snapshot")
        XCTAssertEqual(preferences.providers[1].name, "Mine")
        XCTAssertEqual(preferences.providers[2].adapter, "opencode")
        XCTAssertFalse(preferences.migrateDesktopSources())
        XCTAssertTrue(preferences.isValid)
        XCTAssertFalse(preferences.providers.first { $0.id == "gemini-cli" }!.enabled)
    }
    func testNativeUsageMatchesSplitAccessibleLabelsAndExcludesOnDemand() {
        let gemini = NativeQuotaText.reading(provider: "gemini", text: "当前用量\n已使用 87%\n重置时间：15:27 每周限额 已使用 10% 重置时间：下周 高级设置")
        XCTAssertEqual(gemini.windows.map(\.remainingPercent), [13, 90])
        let grok = NativeQuotaText.reading(provider: "grok", text: "用量与账单\n每周用量限额\n1\n%\n已用\n2 天后重置\n按需每月限额\n99% 已用")
        XCTAssertEqual(grok.windows.map(\.remainingPercent), [99])
        XCTAssertEqual(NativeQuotaText.reading(provider: "grok", text: "每周用量限额 暂不可用 按需每月限额 1% 已用").state, "nativeUnavailable")
        XCTAssertEqual(NativeQuotaText.reading(provider: "grok", text: "按需每月限额 1% 已用").state, "nativeUnavailable")
    }
    func testActivityRequiresRealFreshOrderedRootEventsAndKeepsParallelBusy() {
        let now = Date(timeIntervalSince1970: 1000)
        func event(_ type: String, id: String = "one", parent: String? = nil, sequence: UInt64 = 1, at: Date? = nil) -> WhaleEvent {
            .init(source: .remote, sourceInstance: "fixture", sessionId: id, parentSessionId: parent,
                eventType: type, occurredAt: at ?? now, sequence: sequence, severity: .info, metadata: ["provider": "opencode"])
        }
        var tracker = AIActivityTracker()
        XCTAssertFalse(tracker.ingest(event("agent.working", parent: "root"), now: now))
        XCTAssertNil(tracker.title(for: "opencode", now: now))
        XCTAssertTrue(tracker.ingest(event("agent.working"), now: now))
        XCTAssertTrue(tracker.ingest(event("agent.working", id: "two"), now: now))
        XCTAssertTrue(tracker.ingest(event("agent.turn_completed", sequence: 2), now: now))
        XCTAssertEqual(tracker.title(for: "opencode", now: now), "正在运行 · 1个会话")
        XCTAssertFalse(tracker.ingest(event("agent.working", sequence: 1), now: now))
        XCTAssertTrue(tracker.ingest(event("agent.turn_completed", id: "two", sequence: 2), now: now))
        XCTAssertEqual(tracker.title(for: "opencode", now: now), "本轮回复已结束")
        XCTAssertEqual(tracker.title(for: "opencode", now: now.addingTimeInterval(301)), "事件状态已过期")
        XCTAssertFalse(tracker.ingest(event("agent.working", at: now.addingTimeInterval(-61)), now: now))
    }
}
