import AppKit
import QuartzCore
import WhaleCore
import XCTest
@testable import WhaleGirl

extension WhaleGirlAppTests {
    func testDesktopConnectorSettingsExplainPermissionsAndAuthFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("AI额度"), withIntermediateDirectories: true)
        let preferences = AIMonitorPreferences(providers: [
            .init(id: "gemini", name: "Gemini", enabled: false, adapter: "codexbar"),
            .init(id: "grok", name: "Grok", enabled: false, adapter: "codexbar"),
            .init(id: "opencode-fixture", name: "OpenCode Go")])
        try JSONEncoder().encode(preferences).write(to: root.appendingPathComponent("AI工具设置.json"))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(AIQuotaReading(providerId: "opencode-fixture", state: "authenticationFailed"))
            .write(to: root.appendingPathComponent("AI额度/opencode-fixture.json"))
        let store = AIMonitorStore(directory: root)
        defer { store.stop() }
        store.refresh()
        XCTAssertEqual(store.preferences.providers[0].adapter, "nativeApp")
        XCTAssertFalse(store.preferences.providers[0].enabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("AI工具设置.json.before-native-sources.bak").path))
        XCTAssertEqual(store.reading(for: store.preferences.providers[2]).statusTitle, "登录凭据未通过验证")
        store.recordActivity(.init(source: .remote, sourceInstance: "fixture", sessionId: "root", eventType: "agent.working", occurredAt: Date(), severity: .info, metadata: ["provider": "opencode"]))
        XCTAssertEqual(store.activityTitle("opencode"), "正在运行 · 1个会话")
        let settings = AIMonitorSettingsWindow(store: store); settings.showWindow(nil)
        defer { settings.close() }
        let content = try XCTUnwrap(settings.window?.contentView)
        let titles = descendants(of: content).compactMap { ($0 as? NSButton)?.title }
        XCTAssertTrue(titles.contains("打开软件"))
        XCTAssertTrue(titles.contains("授权读取软件用量页面…"))
        XCTAssertTrue(titles.contains("安装／修复官方事件接入"))
        XCTAssertFalse(titles.contains("连接浏览器"))
        XCTAssertTrue(AIMonitorStore.integrationDescription(store.preferences.providers[0]).contains("用量限额页面"))
        XCTAssertTrue(AIMonitorStore.integrationDescription(store.preferences.providers[1]).contains("暂无法自动读取"))
        content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
        try attachSnapshot(of: content, named: "desktop-connector-settings")
        let unsupported = await NativeAppQuotaReader.read("unregistered-fixture")
        XCTAssertEqual(unsupported.state, "unsupported")
    }

    func testMetricSelectionPersistsAndSMCDecodingRejectsInvalidValues() throws {
        let suite = "WhaleGirlMetricsTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SystemMetricPreferences(defaults: defaults)
        XCTAssertEqual(preferences.enabled.count, 8)
        let fullHeight = preferences.panelBaseHeight
        preferences.set(.gpu, enabled: false)
        preferences.set(.temperature, enabled: false)
        let restored = SystemMetricPreferences(defaults: defaults)
        XCTAssertFalse(restored.enabled.contains(.gpu))
        XCTAssertFalse(restored.enabled.contains(.temperature))
        XCTAssertLessThan(restored.panelBaseHeight, fullHeight)
        restored.setAll(false)
        XCTAssertTrue(SystemMetricPreferences(defaults: defaults).enabled.isEmpty)
        restored.setAll(true)
        XCTAssertEqual(SystemMetricPreferences(defaults: defaults).enabled.count, 8)
        XCTAssertEqual(ReadOnlySMC.decode(type: 0x73703738, bytes: [0x2a, 0x80]), 42.5)
        XCTAssertEqual(ReadOnlySMC.decode(type: 0x666c7420, bytes: [0, 0, 0x2a, 0x42]), 42.5)
        XCTAssertNil(ReadOnlySMC.decode(type: 0x666c7420, bytes: [0]))
        XCTAssertNil(ReadOnlySMC.decode(type: 0, bytes: [0, 0]))
        XCTAssertFalse(HardwareMetricsReader.validTemperature(.nan))
        XCTAssertFalse(HardwareMetricsReader.validTemperature(0))
        XCTAssertFalse(HardwareMetricsReader.validTemperature(200))
        XCTAssertTrue(HardwareMetricsReader.validTemperature(42.5))
        XCTAssertTrue(SMCTemperatureKeys.forChip("Apple M4").cpu.contains("Te05"))
        XCTAssertFalse(SMCTemperatureKeys.forChip("Apple M4").cpu.contains("Tp0P"))
        XCTAssertFalse(SMCTemperatureKeys.forChip("Intel Core i7").cpu.contains("Tp0P"))
        XCTAssertTrue(SMCTemperatureKeys.forChip("Intel Core i7").gpu.contains("TCGC"))
        XCTAssertEqual(ComputerInformationView.formattedValues(.unavailable)[1], "—")
        let settings = SystemMetricSettingsWindow()
        settings.showWindow(nil)
        defer { settings.close() }
        let settingsView = try XCTUnwrap(settings.window?.contentView)
        settingsView.layoutSubtreeIfNeeded()
        settingsView.displayIfNeeded()
        try attachSnapshot(of: settingsView, named: "system-metric-selection")
        settings.close()
    }

    func testAutomaticUserFilesUseApplicationSupport() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhaleGirl/UserData", isDirectory: true)
        XCTAssertEqual(WhaleGirlUserFiles.directory, support)
        XCTAssertEqual(DeepSeekChanDialog.fileURL.deletingLastPathComponent(), support)
        XCTAssertEqual(AIMonitorStore().directory, support)
    }

    func testAIQuotaPanelSelectionSnapshotReloadAndRender() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("AI额度"), withIntermediateDirectories: true)
        let providers: [AIQuotaProvider] = [.init(id: "codex-fixture", name: "Codex"), .init(id: "gemini-fixture", name: "Gemini")]
        let preferences = AIMonitorPreferences(providers: providers)
        try JSONEncoder().encode(preferences).write(to: directory.appendingPathComponent("AI工具设置.json"))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let quota = AIQuotaReading(providerId: providers[0].id, state: "ready", windows: [
            .init(durationSeconds: 18000, remainingPercent: 73, resetsAt: Date().addingTimeInterval(3600)),
            .init(durationSeconds: 604800, remainingPercent: 54, resetsAt: Date().addingTimeInterval(86400))])
        try encoder.encode(quota).write(to: directory.appendingPathComponent("AI额度/codex-fixture.json"))
        let store = AIMonitorStore(directory: directory)
        store.refresh()
        XCTAssertEqual(store.visibleProviders.count, 2)
        XCTAssertTrue(AIQuotaSectionView.summary(store.reading(for: providers[0])).contains("5小时 73%"))
        XCTAssertEqual(AIQuotaSectionView.summary(store.reading(for: providers[1])), "周 —  ·  小时 —")
        let sampler = SystemMetricsSampler()
        let controller = MenuBarInformationController(sampler: sampler, aiStore: store)
        defer { controller.shutdown(); store.stop() }
        let screen = try XCTUnwrap(NSScreen.main)
        controller.open(anchor: CGRect(x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.maxY, width: 40, height: 24), screen: screen, scale: 0.9)
        try await waitForWanderingCondition(timeout: 15) { controller.state == .descending }
        for _ in 0..<55 { controller.advanceAnimation() }
        try await waitForWanderingCondition(timeout: 15) { controller.state == .showing }
        let panel = try XCTUnwrap(controller.informationPanel)
        XCTAssertFalse(panel.ignoresMouseEvents, "Quota selector/scroll uses only the visible card bounds")
        XCTAssertGreaterThan(panel.frame.height, 224)
        let view = try XCTUnwrap(controller.informationView)
        await sampler.waitForHardwareSample()
        view.update(sampler.sample())
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        try attachSnapshot(of: view, named: "ai-quotas-card")
        store.setProvider(providers[1].id, enabled: false)
        XCTAssertEqual(store.visibleProviders.count, 1)
        store.setShowQuotas(false)
        XCTAssertTrue(store.visibleProviders.isEmpty)
        XCTAssertEqual(panel.frame.height, SystemMetricPreferences.shared.panelBaseHeight, accuracy: 1)
        XCTAssertFalse(panel.ignoresMouseEvents)
        let reloaded = AIMonitorStore(directory: directory)
        XCTAssertFalse(reloaded.preferences.showQuotas)
        XCTAssertFalse(reloaded.preferences.providers[1].enabled)
        store.setShowQuotas(true)
        XCTAssertGreaterThan(panel.frame.height, 224)
        store.addProvider(name: "另一个 AI")
        XCTAssertEqual(store.preferences.providers.last?.name, "另一个 AI")
    }

    func testInformationDesignBusyLoadingAndMissingStates() throws {
        let suite = "WhaleGirlDesign." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SystemMetricPreferences(defaults: defaults)
        let view = ComputerInformationView(frame: NSRect(x: 0, y: 0, width: 236, height: preferences.panelBaseHeight), aiStore: nil, preferences: preferences)
        var busy = SystemMetricsSnapshot(cpuPercent: 95, memoryUsedBytes: 14_000_000_000, memoryTotalBytes: 16_000_000_000,
            downloadBytesPerSecond: 3_000_000, uploadBytesPerSecond: 400_000, batteryPercent: 12, batteryCharging: false)
        busy.hardware = .init(gpuPercent: 91, cpuTemperature: 87, gpuTemperature: 82,
            storageUsedBytes: 480_000_000_000, storageTotalBytes: 500_000_000_000, fetchedAt: Date())
        var missing = SystemMetricsSnapshot.unavailable
        missing.hardware.fetchedAt = Date(); missing.batteryPresent = false
        for (name, metrics) in [("busy", busy), ("loading", SystemMetricsSnapshot.unavailable), ("missing", missing)] {
            view.update(metrics); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            try attachSnapshot(of: view, named: "design-" + name)
        }
    }

    func testDashboardBuildsAndAcceptsPhaseOneState() {
        let controller = DashboardWindowController()
        let metrics = SystemMetricsSnapshot(
            cpuPercent: 12,
            memoryUsedBytes: 8_000_000_000,
            memoryTotalBytes: 16_000_000_000,
            downloadBytesPerSecond: 1_024,
            uploadBytesPerSecond: 512,
            batteryPercent: 80,
            batteryCharging: true
        )
        let key = SessionKey(source: .codex, sourceInstance: "test", sessionId: "session")
        let session = SessionSnapshot(
            key: key,
            projectKey: "WhaleGirl",
            status: .waitingApproval,
            updatedAt: Date(),
            lastObservedAt: Date(),
            lastSequence: 1,
            unreadCount: 1,
            needsAttention: true
        )
        controller.update(
            metrics: metrics,
            eventState: EventHubSnapshot(sessions: [session]),
            socketStatus: "测试中",
            launchAtLoginStatus: "未启用"
        )
        XCTAssertEqual(controller.window?.title, "WhaleGirl Dashboard")
        controller.close()
    }

    func testSystemMetricsSamplerReturnsPhysicalMemory() {
        let sampler = SystemMetricsSampler()
        let first = sampler.sample()
        let second = sampler.sample()
        XCTAssertGreaterThan(first.memoryTotalBytes, 0)
        XCTAssertLessThanOrEqual(first.memoryUsedBytes, first.memoryTotalBytes)
        XCTAssertLessThanOrEqual(second.memoryUsedBytes, second.memoryTotalBytes)
    }
}
