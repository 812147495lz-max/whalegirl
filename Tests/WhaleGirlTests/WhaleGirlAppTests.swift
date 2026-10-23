import AppKit
import QuartzCore
import WhaleCore
import XCTest
@testable import WhaleGirl

@MainActor
final class WhaleGirlAppTests: XCTestCase {
    func testQuickNetworkPipelineSharesResultsAndCancelDoesNotAnnounce() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NetworkDownloadFixtureProtocol.self]
        let store = NetworkDiagnosticsStore(downloadConfiguration: config)
        store.targetIndex = 4; store.customAddress = "https://127.0.0.1/ok"; store.settings.maxHops = 1
        var announcements: [String] = []; store.onQuickCompletion = { announcements.append($0) }
        store.startQuick()
        XCTAssertTrue(store.isRunning)
        store.start(.capacity, input: "www.apple.com") // Cannot start a competing test.
        try await waitForWanderingCondition(timeout: 12) { !store.isRunning }
        XCTAssertEqual(announcements.count, 1)
        XCTAssertNotNil(store.latency)
        XCTAssertEqual(store.trace.reachedHop, 1)
        XCTAssertNotNil(store.downloadReading)
        XCTAssertTrue(try XCTUnwrap(store.lastSpeech).contains("到达目标共 1 跳"))
        XCTAssertTrue(try XCTUnwrap(store.lastSpeech).contains("下载"))
        store.startQuick(); store.cancel()
        try await waitForWanderingCondition(timeout: 4) { !store.isRunning }
        XCTAssertEqual(announcements.count, 1, "Stopped runs must not announce successful completion")
        let quick = NetworkQuickTestController(store: store); _ = quick.view
        XCTAssertEqual(quick.target.indexOfSelectedItem, 4)
        XCTAssertEqual(quick.address.stringValue, "https://127.0.0.1/ok")
        XCTAssertEqual(quick.mode.itemTitles.count, 4)
    }
    func testRopeNetworkResultBubbleAndQuickButtonCleanup() async throws {
        let controller = MenuBarInformationController()
        let screen = try XCTUnwrap(NSScreen.main)
        controller.open(anchor: CGRect(x: screen.visibleFrame.minX + 160, y: screen.visibleFrame.maxY, width: 40, height: 24), screen: screen, scale: 0.9)
        defer { controller.shutdown() }
        try await waitForWanderingCondition(timeout: 15) { controller.state == .showing }
        let view = try XCTUnwrap(controller.informationView)
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        XCTAssertTrue(views(view).compactMap { $0 as? NSButton }.contains { $0.title == "测速" })
        let speedButton = try XCTUnwrap(view.networkTestButton)
        speedButton.performClick(nil)
        let options = try XCTUnwrap(NetworkQuickTestController.visibleWindow)
        XCTAssertTrue(options.isVisible)
        XCTAssertGreaterThanOrEqual(options.frame.minX, try XCTUnwrap(controller.informationPanel).frame.maxX - 30)
        XCTAssertTrue(screen.visibleFrame.contains(options.frame))
        let optionsView = try XCTUnwrap(options.contentView)
        optionsView.layoutSubtreeIfNeeded(); optionsView.displayIfNeeded()
        let bitmap = try XCTUnwrap(optionsView.bitmapImageRepForCachingDisplay(in: optionsView.bounds))
        optionsView.cacheDisplay(in: optionsView.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "network-quick-options"; attachment.lifetime = .keepAlways; add(attachment)
        NetworkQuickTestController.dismiss()
        controller.showNetworkResult("测好啦！example.test\n平均延迟 12.0 ms\n到达目标共 5 跳\n目标下载 20.00 Mbps")
        let bubble = try XCTUnwrap(controller.networkSpeechPanel)
        XCTAssertTrue(bubble.isVisible)
        XCTAssertTrue(screen.visibleFrame.contains(bubble.frame))
        controller.close()
        XCTAssertNil(controller.networkSpeechPanel)
    }
    func testNetworkDiagnosticsWindowHasTargetsRouteRowsAndSafeIdleState() throws {
        var trace = RouteTrace()
        trace.ingest("traceroute to example.test (203.0.113.8), 30 hops max")
        trace.ingest(" 1  192.0.2.1  1.100 ms 2.000 ms *")
        let store = NetworkDiagnosticsStore(trace: trace)
        let controller = NetworkDiagnosticsWindow(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let buttons = views(content).compactMap { $0 as? NSButton }
        for title in ["开始检测", "测试设置"] {
            XCTAssertTrue(buttons.contains { $0.title == title && $0.isEnabled })
        }
        XCTAssertTrue(buttons.contains { $0.title == "停止" && !$0.isEnabled })
        let popup = try XCTUnwrap(views(content).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Google") })
        XCTAssertEqual(popup.itemTitles, ["Google", "GitHub", "百度", "哔哩哔哩", "自定义网址 / IP"])
        let address = try XCTUnwrap(views(content).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "networkTarget" })
        XCTAssertFalse(address.isEnabled)
        popup.selectItem(at: 4)
        _ = popup.target?.perform(popup.action, with: popup)
        XCTAssertTrue(address.isEnabled)
        XCTAssertFalse(store.busy)
        let table = try XCTUnwrap(views(content).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 1)
        content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "network-diagnostics-fixture"; attachment.lifetime = .keepAlways; add(attachment)
        store.start(.route, input: "--help")
        XCTAssertFalse(store.busy)
        XCTAssertTrue(store.status.contains("有效"))
    }
    func testNetworkDownloadBoundsAndHTTPFailuresWithoutExternalTraffic() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetworkDownloadFixtureProtocol.self]
        let result = try await NetworkTargetDownload(configuration: config, byteLimit: 1024).run(url: URL(string: "https://network-fixture.invalid/ok")!)
        XCTAssertEqual(result.bytes, 1024)
        XCTAssertTrue(result.limited)
        XCTAssertTrue(result.megabitsPerSecond.isFinite)
        do {
            _ = try await NetworkTargetDownload(configuration: config).run(url: URL(string: "https://network-fixture.invalid/forbidden")!)
            XCTFail("HTTP error must not yield a speed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("403")) }
        let streaming = NetworkTargetDownload(configuration: config, timeLimit: 5)
        let operation = Task { try await streaming.run(url: URL(string: "https://network-fixture.invalid/stall")!) }
        try await Task.sleep(for: .milliseconds(50))
        streaming.cancel()
        do { _ = try await operation.value; XCTFail("Active download must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancelled = NetworkTargetDownload(configuration: config); cancelled.cancel()
        do { _ = try await cancelled.run(url: URL(string: "https://network-fixture.invalid/ok")!); XCTFail("Cancelled before start") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testNetworkProcessStreamsLinesBeforeExit() async throws {
        let timestamps = NetworkLineTimingFixture()
        let process = NetworkDiagnosticProcess()
        let result = try await Task.detached {
            try process.run(executable: "/usr/bin/python3", arguments: ["-u", "-c", "import time; print('first', flush=True); time.sleep(0.8); print('second', flush=True)"], timeout: 3) { line in
                timestamps.record(line)
            }
        }.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(timestamps.gap, 0.5, "Lines must arrive as produced, rather than together after EOF")
    }
    func testNetworkProcessTimeoutAndCancelAreBounded() async throws {
        let process = NetworkDiagnosticProcess()
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await Task.detached {
            try process.run(executable: "/bin/sleep", arguments: ["2"], timeout: 0.15)
        }.value
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.8)
        let cancelled = NetworkDiagnosticProcess(); cancelled.cancel()
        do {
            _ = try await Task.detached { try cancelled.run(executable: "/usr/bin/true", arguments: [], timeout: 1) }.value
            XCTFail("Cancelled process must not launch")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
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
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let titles = allViews(content).compactMap { ($0 as? NSButton)?.title }
        XCTAssertTrue(titles.contains("打开软件"))
        XCTAssertTrue(titles.contains("授权读取软件用量页面…"))
        XCTAssertTrue(titles.contains("安装／修复官方事件接入"))
        XCTAssertFalse(titles.contains("连接浏览器"))
        XCTAssertTrue(AIMonitorStore.integrationDescription(store.preferences.providers[0]).contains("用量限额页面"))
        XCTAssertTrue(AIMonitorStore.integrationDescription(store.preferences.providers[1]).contains("暂无法自动读取"))
        content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "desktop-connector-settings"; attachment.lifetime = .keepAlways; add(attachment)
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
        let settingsBitmap = try XCTUnwrap(settingsView.bitmapImageRepForCachingDisplay(in: settingsView.bounds))
        settingsView.cacheDisplay(in: settingsView.bounds, to: settingsBitmap)
        let settingsPNG = try XCTUnwrap(settingsBitmap.representation(using: .png, properties: [:]))
        let settingsAttachment = XCTAttachment(data: settingsPNG, uniformTypeIdentifier: "public.png")
        settingsAttachment.name = "system-metric-selection"; settingsAttachment.lifetime = .keepAlways; add(settingsAttachment)
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
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "ai-quotas-card"; attachment.lifetime = .keepAlways; add(attachment)
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
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "design-" + name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testAgentBirthWaitsTwoSecondsAndClaimsDistinctActions() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Contents/Resources/CommunityActions/catalog.json")
        // Reload a fresh repository with two real fixture action slots.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        var actions = try XCTUnwrap(object["actions"] as? [[String: String]])
        actions.append(["clipID": "full.community.manual", "title": "检查", "category": "测试"])
        object["actions"] = actions
        try JSONSerialization.data(withJSONObject: object).write(to: catalog)
        let manifestURL = catalog.deletingLastPathComponent().appendingPathComponent("sprite-manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var atlases = try XCTUnwrap(manifest["atlases"] as? [[String: Any]])
        var separateAtlas = atlases[0]; separateAtlas["id"] = "community.manual"
        atlases.append(separateAtlas); manifest["atlases"] = atlases
        var clips = try XCTUnwrap(manifest["clips"] as? [[String: Any]])
        for index in clips.indices where clips[index]["id"] as? String == "full.community.manual" { clips[index]["atlasID"] = "community.manual" }
        manifest["clips"] = clips
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let available = try SpriteRepository(bundle: XCTUnwrap(Bundle(url: root)))
        var autonomy = PetView.AutonomyConfiguration()
        autonomy.agentBirthDelay = 2; autonomy.idleDelay = 100...100; autonomy.finishedPoseDelay = 100
        let first = PetView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), repository: available, autonomy: autonomy)
        let second = PetView(frame: first.frame, repository: available, autonomy: autonomy)
        defer { first.pauseAnimation(); second.pauseAnimation(); first.releaseStationaryAction(); second.releaseStationaryAction() }
        for (index, view) in [first, second].enumerated() {
            view.play("full.idle")
            view.beginAgentLife(introduction: "子代理 \(index) 报到")
        }
        try await Task.sleep(for: .milliseconds(1800))
        XCTAssertEqual(first.currentClipID, "full.community.idle")
        XCTAssertEqual(second.currentClipID, "full.community.idle")
        try await waitForWanderingCondition(timeout: 4) {
            first.currentClipID != "full.community.idle" && second.currentClipID != "full.community.idle"
        }
        XCTAssertNotEqual(first.currentClipID, second.currentClipID)
        _ = repository // Preserve the fixture producer until the test has finished.
    }

    func testAngelDepartureRendersFeatherAndHalo() async throws {
        let domain = "WhaleGirl.AngelPreview." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let repository = try SpriteRepository(bundle: .main, defaults: defaults)
        _ = repository.selectSkin(.classic)
        let ready = await repository.prepareClip("full.idle")
        XCTAssertTrue(ready)
        let view = PetView(frame: NSRect(x: 0, y: 0, width: 300, height: 350), repository: repository)
        view.play("full.idle"); view.pauseAnimation(); view.layoutSubtreeIfNeeded()
        defer { view.cancelAngelDeparture(); view.pauseAnimation() }
        _ = view.beginAngelDeparture(duration: 3.6, reducedMotion: false)
        let mask = try XCTUnwrap(view.agentDepartureMask)
        let animation = try XCTUnwrap(mask.animation(forKey: "featheredDeparture") as? CABasicAnimation)
        let start = try XCTUnwrap(animation.fromValue as? Double)
        let end = try XCTUnwrap(animation.toValue as? Double)
        let image = try XCTUnwrap(mask.contents) as! CGImage
        let bytes = try XCTUnwrap(image.dataProvider?.data)
        let pointer = try XCTUnwrap(CFDataGetBytePtr(bytes))
        func alpha(_ x: Int, _ row: Int) -> UInt8 { pointer[row * image.bytesPerRow + x * 4 + 3] }
        let middle = image.width / 2, side = image.width / 4
        let centerBoundary = try XCTUnwrap((0..<image.height).first { alpha(middle, $0) >= 128 })
        let sideBoundary = try XCTUnwrap((0..<image.height).first { alpha(side, $0) >= 128 })
        XCTAssertGreaterThan(centerBoundary, sideBoundary, "The lip bows downward in the center rather than being a straight line")
        XCTAssertGreaterThan((0..<image.height).filter { alpha(middle, $0) > 0 && alpha(middle, $0) < 255 }.count, 12, "A feathered transition must span many pixels")
        mask.removeAllAnimations()
        for (index, progress) in [0.0, 0.5, 1.0].enumerated() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            mask.position.y = start + (end - start) * progress
            CATransaction.commit(); CATransaction.flush()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/whale-angel-\(index).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "angel-wipe-\(index)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testAgentAscendsAfterFarewellAndWorkingCancelsAscent() async throws {
        await FullScreenAvoidance.shared.waitForInitialSnapshot()
        let repository = try SpriteRepository(bundle: .main)
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = RoamPanelController(repository: repository)
        controller.show(centeredAt: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY), screen: screen, scale: 1, clipID: "full.idle")
        defer { controller.hide() }
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertTrue(controller.isVisible)
        let origin = panel.frame.origin
        var closes = 0
        controller.completeAgentDeparture { closes += 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(closes, 0, "Departure must animate instead of closing immediately")
        controller.cancelAgentDeparture()
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(closes, 0, "Resumed work cancels a queued close")
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(panel.frame.minY, origin.y, accuracy: 1)
        XCTAssertNil(controller.petView?.agentDepartureMask)
        XCTAssertNil(controller.petView?.agentHalo)
        controller.completeAgentDeparture { closes += 1 }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let mask = try XCTUnwrap(controller.petView?.agentDepartureMask)
            let animation = try XCTUnwrap(mask.animation(forKey: "featheredDeparture") as? CABasicAnimation)
            let from = try XCTUnwrap(animation.fromValue as? Double)
            let to = try XCTUnwrap(animation.toValue as? Double)
            XCTAssertEqual(animation.duration, 3.6)
            XCTAssertEqual(mask.name, "agent.departure.curvedFeather")
            XCTAssertNotNil(mask.contents)
            let halo = try XCTUnwrap(controller.petView?.agentHalo)
            XCTAssertGreaterThan(halo.shadowRadius, 0)
            XCTAssertTrue(controller.petView?.layer?.mask === mask, "The halo and body share the erase mask")
            try await Task.sleep(for: .seconds(1.8))
            XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01, "Normal departure erases spatially, never fades the whole pet")
            XCTAssertEqual(closes, 0)
            try await Task.sleep(for: .seconds(2.1))
            XCTAssertEqual(panel.frame.minY - origin.y, from - to, accuracy: 1, "Rise and wipe cover identical distances in the same duration")
        } else {
            try await Task.sleep(for: .seconds(0.5))
            XCTAssertEqual(panel.alphaValue, 0, accuracy: 0.01)
        }
        XCTAssertEqual(closes, 1)
    }

    func testClassicFarewellIsExactSharedAndResumeCancelsClose() async throws {
        let repository = try SpriteRepository(bundle: .main)
        let old = repository.selectedSkin; _ = repository.selectSkin(.classic)
        defer { _ = repository.selectSkin(old) }
        let wave = RoamPanelController.classicFarewell
        let clip = try XCTUnwrap(repository.clip(wave))
        XCTAssertEqual(clip.frames.count, 120)
        XCTAssertEqual(clip.frames.reduce(0) { $0 + $1.duration }, 10, accuracy: 0.01)
        let ready = await repository.prepareClip(wave)
        XCTAssertTrue(ready)
        let first = PetView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), repository: repository)
        let second = PetView(frame: first.frame, repository: repository)
        defer { first.pauseAnimation(); second.pauseAnimation() }
        first.play(wave, looping: false, allowSharedAction: true)
        second.play(wave, looping: false, allowSharedAction: true)
        XCTAssertEqual(first.currentClipID, wave)
        XCTAssertEqual(second.currentClipID, wave)
        let controller = AgentCompanionController()
        var resumed = 0; controller.onResumed = { _ in resumed += 1 }
        let now = Date()
        func event(_ kind: String, _ offset: Double) -> WhaleEvent {
            .init(source: .dsh, sourceInstance: "fixture", sessionId: "child", parentSessionId: "root",
                  eventType: kind, occurredAt: now.addingTimeInterval(offset), severity: .info,
                  metadata: ["agentLabel": "检查设置页面"])
        }
        controller.receive(event("agent.working", 0))
        controller.receive(event("agent.session_completed", 1))
        controller.receive(event("agent.working", 2))
        XCTAssertEqual(resumed, 1)
        XCTAssertNil(controller.roster.entries.values.first?.retireAt)
        XCTAssertEqual(controller.labels.values.first, "检查设置页面")
        controller.closeAll()
    }

    func testAgentCompanionCallbacksAreIdempotentAndToggleOnlyClosesOwnedAgents() {
        let controller = AgentCompanionController()
        var spawned: [String] = [], spoken: [String] = [], closed: [String] = []
        controller.onSpawn = { spawned.append($0) }
        controller.onFinished = { key, success in if success { spoken.append(key) } }
        controller.onClose = { closed.append($0) }
        let now = Date()
        func event(_ id: String, _ type: String, parent: String? = "root") -> WhaleEvent {
            .init(source: .dsh, sourceInstance: "fixture", sessionId: id, parentSessionId: parent,
                  eventType: type, occurredAt: now, severity: .info)
        }
        controller.receive(event("root", "agent.working", parent: nil))
        controller.receive(event("a", "agent.session_started"))
        controller.receive(event("a", "agent.working"))
        controller.receive(event("b", "agent.session_started"))
        XCTAssertEqual(spawned.count, 3)
        controller.receive(event("a", "agent.session_completed"))
        controller.receive(event("a", "agent.session_completed"))
        XCTAssertEqual(spoken.count, 1)
        let entry = controller.roster.entries[spoken[0]]!
        XCTAssertTrue((10...20).contains(entry.retireAt!.timeIntervalSince(entry.lastSeen)))
        controller.setEnabled(false)
        XCTAssertEqual(Set(closed), Set(spawned))
        controller.receive(event("c", "agent.session_started"))
        XCTAssertEqual(spawned.count, 3)
        controller.setEnabled(true)
        controller.receive(event("c", "agent.session_started"))
        XCTAssertEqual(spawned.count, 4)
        controller.closeAll()
    }

    func testAgentCompanionRecoversFreshDSHTerminalWithoutStart() {
        let controller = AgentCompanionController()
        var spawned = 0, spoken = 0
        controller.onSpawn = { _ in spawned += 1 }
        controller.onFinished = { _, _ in spoken += 1 }
        let ended = Date().addingTimeInterval(-2)
        let event = WhaleEvent(source: .dsh, sourceInstance: "recovery-fixture", sessionId: "missing-start", parentSessionId: "parent",
            eventType: "agent.session_completed", occurredAt: ended, severity: .info, metadata: ["client":"dsh-whale-status"])
        controller.receive(event)
        XCTAssertEqual(spawned, 1)
        XCTAssertEqual(spoken, 1)
        let key = AgentCompanionRoster.key(for: event)!
        XCTAssertTrue((10...20).contains(controller.roster.entries[key]!.retireAt!.timeIntervalSince(ended)))
        controller.closeAll()
    }

    func testReplyCompletionUsesPeekSpeechForTenSecondsAndArrow() async throws {
        let repository = try SpriteRepository(bundle: .main)
        let suppressed = MenuBarController(repository: repository, metricsSampler: .init(), peekSuppression: { _ in true })
        suppressed.install(scale: 0.9)
        suppressed.showReplyCompletion(sourceName: "Grok")
        XCTAssertFalse(suppressed.isCompletionPeekActive)
        suppressed.uninstall()
        let menuBar = MenuBarController(repository: repository, metricsSampler: .init(), peekSuppression: { _ in false })
        defer { menuBar.uninstall() }
        menuBar.install(scale: 0.9)
        menuBar.showReplyCompletion(sourceName: "Codex")
        try await waitForWanderingCondition(timeout: 20) { menuBar.completionSpeechLine == "Codex 回复完成啦" && menuBar.isHoverCharacterVisible }
        let speech = try XCTUnwrap(menuBar.completionSpeechPanel)
        XCTAssertTrue(speech.isVisible)
        XCTAssertTrue(speech.ignoresMouseEvents)
        XCTAssertTrue(speech.collectionBehavior.contains(.fullScreenNone))
        // Notification ownership survives mouse enter/exit and the next wink.
        func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        menuBar.mouseEntered(with: try crossing(.mouseEntered))
        menuBar.mouseExited(with: try crossing(.mouseExited))
        menuBar.showReplyCompletion(sourceName: "Gemini")
        menuBar.showReplyCompletion(sourceName: "Codex")
        try await waitForWanderingCondition { menuBar.completionSpeechLine == "Codex、Gemini 回复完成啦" }
        try await Task.sleep(for: .milliseconds(400))
        let bubble = try XCTUnwrap(speech.contentView as? HoverSpeechBubbleView)
        bubble.layoutSubtreeIfNeeded(); bubble.displayIfNeeded()
        let path = HoverSpeechBubbleView.bubblePath(in: bubble.bounds.insetBy(dx: 0.5, dy: 0.5), tailX: bubble.tailX)
        XCTAssertTrue(path.contains(CGPoint(x: bubble.tailX, y: bubble.bounds.maxY - 2)))
        XCTAssertFalse(path.contains(CGPoint(x: bubble.bounds.midX - 18, y: bubble.bounds.maxY - 2)))
        if let bitmap = bubble.bitmapImageRepForCachingDisplay(in: bubble.bounds) {
            bubble.cacheDisplay(in: bubble.bounds, to: bitmap)
            let image = NSImage(size: bubble.bounds.size); image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image); attachment.name = "peek-reply-arrow"; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await Task.sleep(for: .seconds(9))
        XCTAssertTrue(menuBar.isHoverCharacterVisible)
        XCTAssertTrue(menuBar.isCompletionPeekActive)
        XCTAssertTrue(speech.isVisible)
        try await waitForWanderingCondition(timeout: 4) { !menuBar.isHoverCharacterVisible && !menuBar.isCompletionPeekActive }
        try await waitForWanderingCondition { !speech.isVisible }
        menuBar.showReplyCompletion(sourceName: "Claude Code")
        try await waitForWanderingCondition(timeout: 4) { menuBar.isHoverCharacterVisible }
        menuBar.uninstall()
        XCTAssertFalse(menuBar.isCompletionPeekActive)
        XCTAssertFalse(speech.isVisible)
    }

    func testEditableDialogueCSVReloadAndSafeFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("气泡文案.csv")
        let store = DialogueCSVStore(url: url, defaults: ["默认一", "默认二"])
        try store.ensureFile()
        XCTAssertEqual(store.currentLines(), ["默认一", "默认二"])
        try DialogueCSV.encode(["自定义你好", "带逗号,和引号\"的文案"]).write(to: url, atomically: true, encoding: .utf8)
        try store.ensureFile()
        XCTAssertEqual(store.currentLines(), ["自定义你好", "带逗号,和引号\"的文案"])
        try "气泡文案\n只有新文案\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.currentLines(), ["只有新文案"], "Save must replace the list on the next request")
        for broken in ["", "气泡文案\n", "气泡文案\n\"未保存完", "气泡文案\n多个,非空列"] {
            try broken.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(store.currentLines(), ["只有新文案"])
        }
        try DialogueCSV.encode(["UTF16 文案🐋"]).write(to: url, atomically: true, encoding: .utf16)
        XCTAssertEqual(store.currentLines(), ["UTF16 文案🐋"])
        try Data(repeating: 65, count: 1_048_577).write(to: url)
        XCTAssertEqual(store.currentLines(), ["UTF16 文案🐋"])
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(store.currentLines(), ["UTF16 文案🐋"])
    }

    func testTrimmedFallRevealsCardAfterBounceBeforeFinalPoseAndClosesCleanly() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let resource = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("ClickAnimations"))
        let manifest = try SpriteManifest.decode(Data(contentsOf: resource.appendingPathComponent("sprite-manifest.json")))
        let fall = try XCTUnwrap(manifest.clip(id: "fall"))
        XCTAssertEqual(fall.frames.count, 52)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resource.appendingPathComponent("provenance.json"))) as? [String: Any])
        let policy = try XCTUnwrap(metadata["playback"] as? [String: Any])
        let sourceFrames = try XCTUnwrap(policy["fallSourceFrameNumbers"] as? [Int])
        XCTAssertEqual(sourceFrames.first, 1, "Preserve the exact hover handoff")
        XCTAssertEqual(sourceFrames.last, 68)
        XCTAssertTrue((15...58).allSatisfy { sourceFrames.contains($0) }, "Keep drop, flip, rebound and arm motion")
        let controller = MenuBarInformationController()
        defer { controller.shutdown() }
        XCTAssertEqual(sourceFrames[controller.informationRevealFrameIndex], 42)
        controller.open(anchor: CGRect(x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.maxY,
                                       width: 40, height: 24), screen: screen, scale: 0.9)
        try await waitForWanderingCondition(timeout: 15) { controller.state == .descending }
        while controller.frameIndex < controller.informationRevealFrameIndex - 1 { controller.advanceAnimation() }
        XCTAssertFalse(controller.informationPanel?.isVisible == true)
        controller.advanceAnimation()
        XCTAssertEqual(controller.state, .descending, "Card opens while arm animation is still running")
        let card = try XCTUnwrap(controller.informationPanel)
        XCTAssertTrue(card.isVisible)
        controller.close()
        XCTAssertFalse(card.isVisible, "Closing during early reveal hides the card immediately")
        for _ in 0..<55 { controller.advanceAnimation() }
        try await waitForWanderingCondition(timeout: 15) { controller.state == .ascending }
        XCTAssertFalse(card.isVisible)
        controller.shutdown()
        XCTAssertFalse(card.isVisible)
    }

    func testRopeHandoffUsesExactHoverBitmapAndKeepsCanvasThroughShowAndUp() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = MenuBarInformationController()
        defer { controller.shutdown() }
        let alignment = try XCTUnwrap(controller.alignment)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "frame_0030", withExtension: "png", subdirectory: "HoverAnimations/appear"))
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        var rawRect = CGRect(origin: .zero, size: image.size)
        let raw = try XCTUnwrap(image.cgImage(forProposedRect: &rawRect, context: nil, hints: nil))
        let crop = alignment.hoverCrop
        let hoverBitmap = try XCTUnwrap(raw.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)))
        let anchor = CGRect(x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.maxY, width: 40, height: 24)
        let hoverFrame = MenuBarInformationController.hoverPresentationFrame(anchor: anchor, visibleFrame: screen.visibleFrame,
            sourceSize: CGSize(width: hoverBitmap.width, height: hoverBitmap.height), displayScale: 0.9 * 1.3)
        var verified = false
        controller.onPresentationReady = {
            guard let panel = controller.characterPanel,
                  let layers = panel.contentView?.layer?.sublayers,
                  let handoff = layers.first(where: { $0.name == "hover-handoff" }) else { return XCTFail("Missing handoff layer") }
            XCTAssertTrue((handoff.contents as AnyObject?) === hoverBitmap)
            XCTAssertFalse(handoff.isHidden)
            XCTAssertTrue(layers.first?.isHidden == true, "Never double-render the two shared poses")
            let actual = handoff.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
            XCTAssertEqual(actual.minX, hoverFrame.minX, accuracy: 0.00001)
            XCTAssertEqual(actual.minY, hoverFrame.minY, accuracy: 0.00001)
            XCTAssertEqual(actual.size, hoverFrame.size)
            verified = true
        }
        controller.open(anchor: anchor, screen: screen, scale: 0.9, handoffPose: .init(image: hoverBitmap, frame: hoverFrame))
        try await waitForWanderingCondition(timeout: 15) { verified }
        let panel = try XCTUnwrap(controller.characterPanel)
        let layer = try XCTUnwrap(panel.contentView?.layer?.sublayers?.first)
        let canvas = layer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        controller.advanceAnimation()
        XCTAssertFalse(layer.isHidden)
        XCTAssertTrue(panel.contentView?.layer?.sublayers?.last?.isHidden == true)
        for _ in 0..<70 { controller.advanceAnimation() }
        try await waitForWanderingCondition(timeout: 15) { controller.state == .showing }
        XCTAssertEqual(layer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY), canvas)
        controller.close()
        try await waitForWanderingCondition(timeout: 15) { controller.state == .ascending && controller.frameIndex == 0 }
        XCTAssertEqual(layer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY), canvas)
        controller.shutdown()
    }

    func testRopeRegisteredPoseMapsToHoverAtEverySizeAndDisplayEdge() throws {
        let alignment = try XCTUnwrap(MenuBarInformationController().alignment)
        let visible = CGRect(x: -1280, y: 50, width: 1280, height: 750)
        for scale in [0.8, 1.0, 1.3, 1.5] {
            for x in [-1270.0, -640, -80] {
                let frames = MenuBarInformationController.presentationFrames(anchor: CGRect(x: x, y: 800, width: 40, height: 24),
                    visibleFrame: visible, alignment: alignment, scale: scale)
                XCTAssertTrue(visible.contains(frames.character))
                XCTAssertTrue(visible.contains(frames.card))
                let h = alignment.hoverCrop, f = alignment.fallCrop
                for point in [CGPoint(x: 470, y: 70), CGPoint(x: 630, y: 240), CGPoint(x: 700, y: 460)] {
                    let fromFall = CGPoint(x: frames.canvas.minX + (point.x - f.x) / f.width * frames.canvas.width,
                        y: frames.canvas.maxY - (point.y - f.y) / f.height * frames.canvas.height)
                    let expected = CGPoint(x: frames.hover.minX + (point.x * alignment.sourceScale + alignment.offsetX - h.x) / h.width * frames.hover.width,
                        y: frames.hover.maxY - (point.y * alignment.sourceScale + alignment.offsetY - h.y) / h.height * frames.hover.height)
                    XCTAssertEqual(fromFall.x, expected.x, accuracy: 0.00001)
                    XCTAssertEqual(fromFall.y, expected.y, accuracy: 0.00001)
                }
            }
        }
    }

    func testRopeInfoDownStaticCardAndUpLifecycle() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = MenuBarInformationController()
        defer { controller.shutdown() }
        let anchor = CGRect(x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.maxY, width: 40, height: 24)
        controller.open(anchor: anchor, screen: screen, scale: 0.9)
        try await waitForWanderingCondition(timeout: 15) { controller.state == .descending }
        let character = try XCTUnwrap(controller.characterPanel)
        let original = character.frame
        XCTAssertTrue(character.isVisible)
        XCTAssertTrue(character.ignoresMouseEvents)
        XCTAssertFalse(controller.informationPanel?.isVisible == true)
        for _ in 0..<70 { controller.advanceAnimation() }
        try await waitForWanderingCondition(timeout: 15) { controller.state == .showing }
        let card = try XCTUnwrap(controller.informationPanel)
        XCTAssertTrue(card.isVisible)
        XCTAssertFalse(card.ignoresMouseEvents, "The visible card contains metric preferences and scroll controls")
        let alignment = try XCTUnwrap(controller.alignment)
        let frames = MenuBarInformationController.presentationFrames(anchor: anchor,
            visibleFrame: screen.visibleFrame, alignment: alignment, scale: 0.9)
        let hand = MenuBarInformationController.presentationHand(canvas: frames.canvas, alignment: alignment)
        XCTAssertEqual(frames.card.minX, hand.x + 10, accuracy: 1)
        XCTAssertEqual(frames.card.maxY, hand.y + 44, accuracy: 1)
        XCTAssertEqual(character.frame, original)
        let pose = controller.frameIndex
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.frameIndex, pose, "Show is a static picture, never a loop")
        let view = try XCTUnwrap(controller.informationView)
        XCTAssertEqual(view.frame.width, 236, accuracy: 1)
        func checkOpaqueText(_ node: NSView) {
            if let label = node as? NSTextField {
                XCTAssertEqual(label.textColor?.alphaComponent ?? 0, 1)
            }
            for child in node.subviews { checkOpaqueText(child) }
        }
        checkOpaqueText(view)
        XCTAssertEqual(view.alphaValue, 1)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "computer-status-card"
        attachment.lifetime = .keepAlways
        add(attachment)
        controller.close()
        XCTAssertFalse(card.isVisible)
        try await waitForWanderingCondition(timeout: 15) { controller.state == .ascending && controller.frameIndex == 0 }
        // Give the asynchronous up texture time to replace the held show picture.
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<24 { controller.advanceAnimation() }
        try await waitForWanderingCondition { controller.state == .hidden }
        XCTAssertFalse(character.isVisible)
        XCTAssertFalse(card.isVisible)
    }

    func testRopeInfoRapidCloseAndShutdownCannotLeaveOrphanWindows() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let anchor = CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 30, height: 24)
        let controller = MenuBarInformationController()
        defer { controller.shutdown() }
        controller.open(anchor: anchor, screen: screen, scale: 1)
        controller.close()
        XCTAssertEqual(controller.state, .hidden)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(controller.characterPanel?.isVisible == true)
        controller.open(anchor: anchor, screen: screen, scale: 1)
        try await waitForWanderingCondition(timeout: 15) { controller.state == .descending }
        controller.close()
        for _ in 0..<70 { controller.advanceAnimation() }
        try await waitForWanderingCondition { controller.state == .ascending }
        XCTAssertFalse(controller.informationPanel?.isVisible == true)
        controller.shutdown()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(controller.state, .hidden)
        XCTAssertFalse(controller.characterPanel?.isVisible == true)
    }

    func testRopeInfoMenuButtonRoutingAndUninstallCleanup() async throws {
        let repository = try SpriteRepository(bundle: .main)
        var menus = 0
        let menuBar = MenuBarController(repository: repository, metricsSampler: .init(), contextMenuPresenter: { menu, _, _ in
            XCTAssertNotNil(menu.item(withTitle: "退出 WhaleGirl"))
            XCTAssertNotNil(menu.item(withTitle: "编辑气泡文案 CSV"))
            menus += 1
        })
        defer { menuBar.uninstall() }
        menuBar.install(scale: 0.9)
        func click(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        menuBar.handleStatusClick(try click(.rightMouseUp, modifiers: .option))
        XCTAssertEqual(menus, 1)
        XCTAssertEqual(menuBar.informationState, .hidden)
        menuBar.handleStatusClick(try click(.rightMouseUp))
        try await waitForWanderingCondition(timeout: 15) { menuBar.informationState == .showing }
        menuBar.handleStatusClick(try click(.leftMouseUp))
        XCTAssertEqual(menus, 2)
        XCTAssertEqual(menuBar.informationState, .showing)
        menuBar.handleStatusClick(try click(.rightMouseUp, modifiers: .option))
        XCTAssertEqual(menus, 3)
        XCTAssertEqual(menuBar.informationState, .showing)
        menuBar.handleStatusClick(try click(.rightMouseUp))
        try await waitForWanderingCondition(timeout: 15) { menuBar.informationState == .hidden }
        XCTAssertTrue(menuBar.isHoverCoolingDown)
        func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil))
        }
        menuBar.mouseEntered(with: try crossing(.mouseEntered))
        menuBar.showPeek()
        XCTAssertFalse(menuBar.isPeekPinned, "Explicit peek must also respect the cooldown")
        XCTAssertFalse(menuBar.isHoverCharacterVisible)
        try await Task.sleep(for: .milliseconds(400))
        menuBar.mouseExited(with: try crossing(.mouseExited))
        menuBar.mouseEntered(with: try crossing(.mouseEntered))
        XCTAssertTrue(menuBar.isHoverCoolingDown, "Leaving/re-entering must not bypass the deadline")
        XCTAssertFalse(menuBar.isHoverCharacterVisible)
        try await waitForWanderingCondition(timeout: 2) { !menuBar.isHoverCoolingDown }
        // Pin acceptance is independent of the existing asynchronous tail/hover decoder.
        menuBar.showPeek()
        XCTAssertTrue(menuBar.isPeekPinned)
        menuBar.handleStatusClick(try click(.rightMouseUp))
        menuBar.uninstall()
        XCTAssertEqual(menuBar.informationState, .hidden)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(menuBar.isHoverCharacterVisible, "Uninstall cancels cooldown wakeup")
    }

    func testRopeInfoGeometryStaysOnDisplayAndFormatsUnavailableMetrics() throws {
        let visible = CGRect(x: -1280, y: 50, width: 1280, height: 750)
        let alignment = try XCTUnwrap(MenuBarInformationController().alignment)
        for x in [-1270.0, -640, -80] {
            let frames = MenuBarInformationController.presentationFrames(
                anchor: CGRect(x: x, y: 800, width: 40, height: 24), visibleFrame: visible,
                alignment: alignment, scale: 1)
            XCTAssertTrue(visible.contains(frames.character))
            XCTAssertTrue(visible.contains(frames.card))
        }
        let values = ComputerInformationView.formattedValues(.unavailable)
        XCTAssertEqual(values.count, 5)
        XCTAssertEqual(values[0], "—")
        XCTAssertEqual(values[2], "—")
        XCTAssertEqual(values[3], "—")
        XCTAssertEqual(values[4], "—")
        XCTAssertTrue(values.allSatisfy { !$0.lowercased().contains("nan") && !$0.lowercased().contains("inf") })
    }

    func testOneShotHoldsFinalPoseThenRestsBeforeAnotherAction() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = await repository.prepareClip("full.community.manual")
        XCTAssertTrue(ready)
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), repository: repository,
            autonomy: .init(drawActionCount: { 3 }, idleDelay: 0.5...0.5, finishedPoseDelay: 0.2))
        defer { view.pauseAnimation(); view.releaseStationaryAction() }
        view.play("full.community.manual", looping: false)
        try await waitForWanderingCondition { view.isHoldingFinishedAction }
        let lastRect = view.layer?.sublayers?.first?.contentsRect
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(view.currentClipID, "full.community.manual")
        XCTAssertEqual(view.layer?.sublayers?.first?.contentsRect, lastRect)
        try await waitForWanderingCondition { view.currentClipID == repository.resolvedClipID("full.idle") }
        XCTAssertFalse(view.isHoldingFinishedAction)
        let idleRect = view.layer?.sublayers?.first?.contentsRect
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(view.currentClipID, repository.resolvedClipID("full.idle"))
        XCTAssertEqual(view.layer?.sublayers?.first?.contentsRect, idleRect)
        try await waitForWanderingCondition { view.currentClipID != repository.resolvedClipID("full.idle") }
        XCTAssertEqual(view.currentClipID, "full.community.running")
    }

    func testFinishedPoseTimerCannotOverrideNewPlaybackOrRestartWhilePaused() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = await repository.prepareClip("full.community.manual")
        XCTAssertTrue(ready)
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), repository: repository,
            autonomy: .init(drawActionCount: { 3 }, idleDelay: 10...10, finishedPoseDelay: 0.15))
        defer { view.pauseAnimation(); view.releaseStationaryAction() }
        view.play("full.community.manual", looping: false)
        try await waitForWanderingCondition { view.isHoldingFinishedAction }
        view.pauseAnimation()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(view.currentClipID, "full.community.manual")
        view.resumeAnimation()
        try await waitForWanderingCondition { view.currentClipID == repository.resolvedClipID("full.idle") }
        view.play("full.community.manual", looping: false)
        try await waitForWanderingCondition { view.isHoldingFinishedAction }
        view.play("full.walk", looping: true)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(view.currentClipID, "full.walk")
        XCTAssertFalse(view.isHoldingFinishedAction)
    }

    func testCoordinatorSwitchesThreeLiveCharactersWithoutMovingTheirWindows() async throws {
        let original = UserDefaults.standard.object(forKey: "desktopPetSkin")
        let coordinator = try AppCoordinator.make()
        defer {
            coordinator.stop()
            if let original { UserDefaults.standard.set(original, forKey: "desktopPetSkin") }
            else { UserDefaults.standard.removeObject(forKey: "desktopPetSkin") }
        }
        coordinator.menuBarDidSelectSkin(.classic)
        let screen = try XCTUnwrap(NSScreen.main)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        for offset in [-180.0, 0, 180.0] {
            coordinator.menuBarDidDragCharacter(to: CGPoint(x: screen.visibleFrame.midX + offset,
                                                           y: screen.visibleFrame.midY), isNew: true)
        }
        let windows = NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) && $0.contentView is PetView }
        XCTAssertEqual(windows.count, 3)
        let views = try windows.map { try XCTUnwrap($0.contentView as? PetView) }
        try await waitForWanderingCondition(timeout: 15) {
            windows.allSatisfy(\.isVisible) && views.allSatisfy { $0.layer?.sublayers?.first?.contents != nil }
        }
        let frames = windows.map(\.frame)
        let oldTextures = try views.map { try XCTUnwrap($0.layer?.sublayers?.first?.contents) as AnyObject }
        coordinator.menuBarDidSelectSkin(.red)
        try await waitForWanderingCondition(timeout: 15) {
            views.indices.allSatisfy { index in
                guard let texture = views[index].layer?.sublayers?.first?.contents as AnyObject? else { return false }
                return views[index].currentClipID.hasPrefix("full.community.red.") && texture !== oldTextures[index]
            }
        }
        XCTAssertEqual(Set(views.map(\.currentClipID)).count, 1, "Resting pets share the neutral pose")
        XCTAssertEqual(windows.map(\.frame), frames)
        let redTextures = try views.map { try XCTUnwrap($0.layer?.sublayers?.first?.contents) as AnyObject }
        let rects = views.map { $0.layer?.sublayers?.first?.contentsRect }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(views.map { $0.layer?.sublayers?.first?.contentsRect }, rects, "Idle is a held neutral pose")
        coordinator.menuBarDidSelectSkin(.classic)
        try await waitForWanderingCondition(timeout: 15) {
            views.indices.allSatisfy { index in
                guard let texture = views[index].layer?.sublayers?.first?.contents as AnyObject? else { return false }
                return !views[index].currentClipID.hasPrefix("full.community.red.") && texture !== redTextures[index]
            }
        }
        XCTAssertEqual(Set(views.map(\.currentClipID)).count, 1, "Resting pets share the neutral pose")
        XCTAssertEqual(windows.map(\.frame), frames)
        coordinator.menuBarDidRequestCloseAllCharacters()
        XCTAssertTrue(windows.allSatisfy { !$0.isVisible })
    }

    func testAllAddedSkinAtlasesActuallyDecodeAndStayWithinInactiveCacheBudget() async throws {
        let domain = "io.whalegirl.tests.decode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let repository = try SpriteRepository(bundle: .main, defaults: defaults)
        let yanz = repository.communityActions.filter { $0.clipID.hasPrefix("full.community.yanz.") }
        XCTAssertEqual(yanz.count, 27)
        XCTAssertTrue(repository.selectSkin(.red))
        let actions = yanz + repository.communityActions
        XCTAssertEqual(actions.count, 189)
        for action in actions {
            let ready = await repository.prepareClip(action.clipID)
            XCTAssertTrue(ready, action.title)
            let clip = try XCTUnwrap(repository.clip(action.clipID))
            let atlas = try XCTUnwrap(repository.decodedAtlas(atlasID: clip.atlasID))
            XCTAssertTrue(atlas.alpha.contains { $0 != 0 }, action.title)
            let frame = try XCTUnwrap(clip.frames.first)
            XCTAssertGreaterThan(atlas.image.width, 0)
            XCTAssertLessThanOrEqual(frame.rect.x + frame.rect.width, Double(atlas.image.width))
            XCTAssertLessThanOrEqual(repository.cachedCommunityBytes, repository.communityCacheBudget)
        }
    }

    func testSkinAndSpecificAnimationMenuActionsReachTheLiveTexture() async throws {
        let domain = "io.whalegirl.tests.menu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let repository = try SpriteRepository(bundle: .main, defaults: defaults)
        let screen = try XCTUnwrap(NSScreen.main)
        let pet = RoamPanelController(repository: repository,
            autonomy: .init(drawActionCount: { 3 }, idleDelay: 60...60))
        defer { pet.hide() }
        pet.show(centeredAt: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY),
                 screen: screen, scale: 1, clipID: "full.idle")
        pet.onSelectSkin = { skin in
            if repository.selectSkin(skin) { pet.petView?.refreshSkin() }
        }
        defer { pet.onSelectSkin = nil }
        let skins = try XCTUnwrap(pet.makeContextMenu().item(withTitle: "桌宠皮肤")?.submenu)
        let red = try XCTUnwrap(skins.item(withTitle: "赤风RED"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(red.action), to: red.target, from: red))
        XCTAssertEqual(repository.selectedSkin, .red)
        XCTAssertEqual(pet.makeContextMenu().item(withTitle: "桌宠皮肤")?.submenu?.item(withTitle: "赤风RED")?.state, .on)
        let chosen = try XCTUnwrap(repository.communityActions.first { $0.title == "Popcat 平滑" })
        let ready = await repository.prepareClip(chosen.clipID)
        XCTAssertTrue(ready)
        let clip = try XCTUnwrap(repository.clip(chosen.clipID))
        let expected = try XCTUnwrap(repository.cgImage(atlasID: clip.atlasID))
        let actions = try XCTUnwrap(pet.makeContextMenu().item(withTitle: "播放动画")?.submenu)
        let entry = try XCTUnwrap(actions.items.flatMap { $0.submenu?.items ?? [] }.first {
            ($0.representedObject as? String) == chosen.clipID
        })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(entry.action), to: entry.target, from: entry))
        let texture = try XCTUnwrap(pet.petView?.layer?.sublayers?.first?.contents) as AnyObject
        XCTAssertTrue(texture === expected)
    }

    func testSkinSelectionSeparatesActionsAliasesAndPersistsWithoutDecoding() throws {
        let domain = "io.whalegirl.tests.skins.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let repository = try SpriteRepository(bundle: .main, defaults: defaults)
        XCTAssertEqual(repository.selectedSkin, .classic)
        let classic = Set(repository.communityActions.map(\.clipID))
        let classicIdle = repository.resolvedClipID("full.idle")
        XCTAssertEqual(classic.count, 133)
        XCTAssertEqual(repository.walkingActions.count, 2)
        XCTAssertTrue(repository.selectSkin(.red))
        let red = Set(repository.communityActions.map(\.clipID))
        XCTAssertEqual(red.count, 162)
        XCTAssertTrue(classic.isDisjoint(with: red))
        for alias in ["idle", "happy", "poke", "dragged", "greet", "return"] {
            XCTAssertTrue(red.contains(repository.resolvedClipID("full.\(alias)")))
        }
        XCTAssertTrue(repository.walkingActions.isEmpty)
        XCTAssertEqual(repository.communityDecodeCount, 0)
        let restored = try SpriteRepository(bundle: .main, defaults: defaults)
        XCTAssertEqual(restored.selectedSkin, .red)
        XCTAssertTrue(restored.selectSkin(.classic))
        XCTAssertEqual(restored.resolvedClipID("full.idle"), classicIdle)
        XCTAssertEqual(Set(restored.communityActions.map(\.clipID)), classic)
    }

    func testBundledManifestAndAtlasesLoad() throws {
        let repository = try SpriteRepository(bundle: .main)
        XCTAssertNotNil(repository.clip("mini.idle"))
        XCTAssertNotNil(repository.clip("peek.wave"))
        XCTAssertNotNil(repository.clip("full.return"))
        XCTAssertNotNil(repository.image(atlasID: "mini"))
        XCTAssertNotNil(repository.image(atlasID: "peek"))
        XCTAssertNotNil(repository.image(atlasID: "full"))
        XCTAssertNotNil(repository.image(atlasID: "joy"))
        XCTAssertNotNil(repository.image(atlasID: "drag"))
        XCTAssertNotNil(repository.image(atlasID: "error"))
        XCTAssertNotNil(repository.cgImage(atlasID: "full"))
    }

    func testMenuBarAnimationFramesAreBundled() {
        for index in 1...20 {
            XCTAssertNotNil(
                Bundle.main.url(forResource: "png_\(index)", withExtension: "png", subdirectory: "MenuBarFrames"),
                "Missing menu bar animation frame png_\(index).png"
            )
        }
    }

    func testAllCommunityActionsDecodeWithTransparencyAndBoundedCache() async throws {
        let repository = try SpriteRepository(bundle: .main)
        XCTAssertEqual(repository.communityActions.count, 133)
        let firstID = try XCTUnwrap(repository.communityActions.first?.clipID)
        let firstAtlas = try XCTUnwrap(repository.clip(firstID)?.atlasID)
        for action in repository.communityActions {
            let prepared = await repository.prepareClip(action.clipID)
            XCTAssertTrue(prepared, "Failed to decode \(action.title)")
            let clip = try XCTUnwrap(repository.clip(action.clipID))
            let image = try XCTUnwrap(repository.cgImage(atlasID: clip.atlasID))
            let atlas = try XCTUnwrap(repository.manifest.atlas(id: clip.atlasID))
            XCTAssertEqual(image.width, atlas.pixelWidth)
            XCTAssertEqual(image.height, atlas.pixelHeight)
            XCTAssertTrue([CGImageAlphaInfo.premultipliedFirst, .premultipliedLast, .first, .last].contains(image.alphaInfo))
            XCTAssertLessThanOrEqual(repository.cachedCommunityBytes, repository.communityCacheBudget)
        }
        XCTAssertNil(repository.cgImage(atlasID: firstAtlas))
        XCTAssertTrue(repository.clip("full.idle")?.id.hasPrefix("full.community.") == true)
        XCTAssertNotNil(repository.clip("full.return"))
        XCTAssertEqual(repository.clip("peek.idle")?.id, "peek.idle")
    }

    func testActiveAtlasIsSharedAfterCacheEvictionAndMasksMatchFramePixels() async throws {
        let repository = try SpriteRepository(bundle: .main)
        let first = try XCTUnwrap(repository.communityActions.first)
        let prepared = await repository.prepareClip(first.clipID)
        XCTAssertTrue(prepared)
        let clip = try XCTUnwrap(repository.clip(first.clipID))
        let held = try XCTUnwrap(repository.decodedAtlas(atlasID: clip.atlasID))
        for action in repository.communityActions.dropFirst().prefix(5) {
            let ready = await repository.prepareClip(action.clipID)
            XCTAssertTrue(ready)
        }
        let decodes = repository.communityDecodeCount
        let again = await repository.prepareClip(first.clipID)
        XCTAssertTrue(again)
        XCTAssertTrue(repository.decodedAtlas(atlasID: clip.atlasID) === held)
        XCTAssertEqual(repository.communityDecodeCount, decodes, "An active player's atlas must never be decoded again")
        XCTAssertLessThanOrEqual(repository.cachedCommunityBytes, repository.communityCacheBudget)
        for frame in [clip.frames[0], clip.frames[clip.frames.count / 2], try XCTUnwrap(clip.frames.last)] {
            let rect = CGRect(x: frame.rect.x, y: frame.rect.y, width: frame.rect.width, height: frame.rect.height)
            let sharedMask = held.mask(for: rect)
            let reference = try XCTUnwrap(SpriteAlphaMask(image: held.image, rect: rect))
            for y in stride(from: 0.025, to: 1.0, by: 0.05) {
                for x in stride(from: 0.025, to: 1.0, by: 0.05) {
                    let point = CGPoint(x: x, y: y)
                    XCTAssertEqual(sharedMask.contains(normalized: point), reference.contains(normalized: point))
                }
            }
        }
    }

    func testActivityFrameMidpointPreservesSharedPixelsAndMovesChangingContent() throws {
        let first = syntheticActivityFrame(tailOriginX: 60)
        let second = syntheticActivityFrame(tailOriginX: 68)
        let midpoint = try XCTUnwrap(ActivityFrameMorpher.midpoint(from: first, to: second))

        let firstPixels = try XCTUnwrap(rgbaPixels(of: first))
        let midpointPixels = try XCTUnwrap(rgbaPixels(of: midpoint))
        let unchangedBodyPixel = pixel(atX: 57, y: 20, in: firstPixels)
        XCTAssertEqual(pixel(atX: 57, y: 20, in: midpointPixels), unchangedBodyPixel)

        let midpointTailAlpha = (64...67).flatMap { x in
            (15...21).map { y in pixel(atX: x, y: y, in: midpointPixels)[3] }
        }.max() ?? 0
        XCTAssertGreaterThan(midpointTailAlpha, 0, "The interpolated tail should occupy the in-between position")
    }

    private func syntheticActivityFrame(tailOriginX: Int) -> NSImage {
        let size = CGSize(width: 100, height: 60)
        let context = CGContext(data: nil, width: 100, height: 60, bitsPerComponent: 8,
                                bytesPerRow: 100 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(origin: .zero, size: size))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 40, y: 10, width: 20, height: 20))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: tailOriginX, y: 15, width: 8, height: 8))
        return NSImage(cgImage: context.makeImage()!, size: size)
    }

    private func rgbaPixels(of image: NSImage) -> [UInt8]? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                                          bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        return rendered ? pixels : nil
    }

    private func pixel(atX x: Int, y: Int, in pixels: [UInt8]) -> [UInt8] {
        let index = (y * 100 + x) * 4
        return Array(pixels[index..<(index + 4)])
    }

    func testStatusIconInputOwnsDragAndPreservesAllClickButtons() throws {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        let input = StatusIconInputView(frame: button.bounds)
        button.addSubview(input)
        XCTAssertTrue(button.hitTest(NSPoint(x: 20, y: 12)) === input,
                      "The icon input must receive events instead of the default button")
        var pointers: [NSEvent.EventType] = []
        var clicks: [NSEvent.EventType] = []
        input.onPointerEvent = { pointers.append($0.type) }
        input.onClick = { clicks.append($0.type) }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                                            timestamp: 0, windowNumber: 0, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        input.mouseDown(with: try event(.leftMouseDown))
        input.mouseDragged(with: try event(.leftMouseDragged))
        input.mouseUp(with: try event(.leftMouseUp))
        input.rightMouseUp(with: try event(.rightMouseUp))
        input.otherMouseUp(with: try event(.otherMouseUp))
        XCTAssertEqual(pointers, [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        XCTAssertEqual(clicks, [.leftMouseUp, .rightMouseUp, .otherMouseUp])
    }

    func testCoordinatorCreatesMovesAndClosesMultipleCharacters() throws {
        let coordinator = try AppCoordinator.make()
        defer { coordinator.stop() }
        let screen = try XCTUnwrap(NSScreen.main)
        let center = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        func createdWindows() -> [NSWindow] {
            NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) && $0.contentView is PetView && $0.isVisible }
        }
        coordinator.menuBarDidDragCharacter(to: center, isNew: true)
        coordinator.menuBarDidDragCharacter(to: CGPoint(x: center.x - 140, y: center.y), isNew: false)
        XCTAssertEqual(createdWindows().count, 1, "A continuous drag must create only one character")
        coordinator.menuBarDidDragCharacter(to: center, isNew: true)
        coordinator.menuBarDidDragCharacter(to: CGPoint(x: center.x + 140, y: center.y), isNew: true)
        let windows = createdWindows()
        XCTAssertEqual(windows.count, 3)
        let moved = try XCTUnwrap(windows.first)
        let view = try XCTUnwrap(moved.contentView as? PetView)
        let others = windows.filter { $0 !== moved }.map { ($0, $0.frame) }
        let oldFrame = moved.frame
        coordinator.petView(view, didDragTo: CGPoint(x: center.x, y: center.y - 150), downwardDistance: 150)
        coordinator.petViewDidEndDrag(view)
        XCTAssertNotEqual(moved.frame, oldFrame)
        XCTAssertTrue(moved.isVisible, "Releasing a desktop character must not return it to the menu bar")
        for (window, frame) in others { XCTAssertEqual(window.frame, frame) }
        coordinator.petViewDidRequestDismiss(view)
        XCTAssertFalse(moved.isVisible)
        XCTAssertEqual(createdWindows().count, 2)
        coordinator.menuBarDidRequestCloseAllCharacters()
        XCTAssertTrue(createdWindows().isEmpty)
        coordinator.menuBarDidRequestFull()
        XCTAssertEqual(createdWindows().count, 1, "Closing all must keep the application able to spawn again")
    }

    func testCharacterContextMenuActionsTargetOnlyTheirOwnWindow() throws {
        let repository = try SpriteRepository(bundle: .main)
        let screen = try XCTUnwrap(NSScreen.main)
        let point = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let first = RoamPanelController(repository: repository)
        let second = RoamPanelController(repository: repository)
        defer { first.hide(); second.hide() }
        first.show(centeredAt: point, screen: screen, scale: 1, clipID: "full.idle")
        second.show(centeredAt: point, screen: screen, scale: 1, clipID: "full.idle")
        first.onClose = { [weak first] in first?.hide() }
        let menu = first.makeContextMenu()
        let sizes = try XCTUnwrap(menu.item(withTitle: "调整大小")?.submenu)
        let control = try XCTUnwrap(sizes.items.first?.view)
        let slider = try XCTUnwrap(control.subviews.compactMap { $0 as? NSSlider }.first)
        let secondFrame = second.panel?.frame
        let original = try XCTUnwrap(first.panel?.frame)
        slider.doubleValue = 60
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        XCTAssertLessThan(try XCTUnwrap(first.panel?.frame.height), original.height)
        XCTAssertEqual(second.panel?.frame, secondFrame)
        let close = try XCTUnwrap(menu.item(withTitle: "关闭这只鲸鱼娘"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(close.action), to: close.target, from: close))
        XCTAssertFalse(first.isVisible)
        XCTAssertTrue(second.isVisible)
    }

    func testSelectedAnimationChangesOnlyTheChosenCharactersTexture() async throws {
        let repository = try SpriteRepository(bundle: .main)
        let idleReady = await repository.prepareClip("full.idle")
        XCTAssertTrue(idleReady)
        let idleID = repository.resolvedClipID("full.idle")
        let chosen = try XCTUnwrap(repository.communityActions.first { $0.clipID != idleID })
        let chosenReady = await repository.prepareClip(chosen.clipID)
        XCTAssertTrue(chosenReady)
        let clip = try XCTUnwrap(repository.clip(chosen.clipID))
        let expected = try XCTUnwrap(repository.cgImage(atlasID: clip.atlasID))
        let screen = try XCTUnwrap(NSScreen.main)
        let point = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let first = RoamPanelController(repository: repository)
        let second = RoamPanelController(repository: repository)
        defer { first.hide(); second.hide() }
        first.show(centeredAt: point, screen: screen, scale: 1, clipID: "full.idle")
        second.show(centeredAt: point, screen: screen, scale: 1, clipID: "full.idle")
        let originalSecondTexture = try XCTUnwrap(second.petView?.layer?.sublayers?.first?.contents) as AnyObject
        let menu = first.makeContextMenu()
        let actions = try XCTUnwrap(menu.item(withTitle: "播放动画")?.submenu)
        let item = try XCTUnwrap(actions.items.flatMap { $0.submenu?.items ?? [] }.first {
            ($0.representedObject as? String) == chosen.clipID
        })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        let firstTexture = try XCTUnwrap(first.petView?.layer?.sublayers?.first?.contents) as AnyObject
        let secondTexture = try XCTUnwrap(second.petView?.layer?.sublayers?.first?.contents) as AnyObject
        XCTAssertTrue(firstTexture === expected)
        XCTAssertTrue(secondTexture === originalSecondTexture)
    }

    func testDesktopCharactersHaveIndependentWindowsSizesAndMenus() throws {
        let repository = try SpriteRepository(bundle: .main)
        let screen = try XCTUnwrap(NSScreen.main)
        let first = RoamPanelController(repository: repository)
        let second = RoamPanelController(repository: repository)
        defer { first.hide(); second.hide() }
        first.show(centeredAt: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY),
                   screen: screen, scale: 1, clipID: "full.idle")
        second.show(centeredAt: CGPoint(x: screen.visibleFrame.midX + 200, y: screen.visibleFrame.midY),
                    screen: screen, scale: 1, clipID: "full.idle")
        XCTAssertFalse(first.panel === second.panel)
        let originalSecondFrame = try XCTUnwrap(second.panel?.frame)
        let originalFirstFrame = try XCTUnwrap(first.panel?.frame)
        first.setCharacterScale(0.6)
        XCTAssertLessThan(try XCTUnwrap(first.panel?.frame.height), originalFirstFrame.height)
        XCTAssertEqual(second.panel?.frame, originalSecondFrame)
        let menu = first.makeContextMenu()
        XCTAssertNotNil(menu.item(withTitle: "关闭这只鲸鱼娘"))
        XCTAssertNotNil(menu.item(withTitle: "退出 WhaleGirl"))
        let animations = try XCTUnwrap(menu.item(withTitle: "播放动画")?.submenu)
        let actionCount = animations.items.reduce(0) { $0 + ($1.submenu?.items.count ?? 0) }
        XCTAssertEqual(actionCount, repository.communityActions.count)
        first.hide()
        XCTAssertFalse(first.isVisible)
        XCTAssertTrue(second.isVisible)
    }

    func testPanelCanOpenAndCloseTwoHundredTimesWithoutMultiplyingWindows() throws {
        let repository = try SpriteRepository(bundle: .main)
        let controller = PeekPanelController(repository: repository)
        let frame = CGRect(x: 100, y: 100, width: 110, height: 90)
        var identity: ObjectIdentifier?

        for _ in 0..<200 {
            controller.show(frame: frame, clipID: "peek.idle")
            guard let panel = controller.panel else { return XCTFail("Panel was not created") }
            if let identity {
                XCTAssertEqual(identity, ObjectIdentifier(panel))
            } else {
                identity = ObjectIdentifier(panel)
            }
            controller.hide()
        }
        XCTAssertFalse(controller.isVisible)
    }

    func testCharacterHasNoControlDockAndTransparentPixelsPassThrough() async throws {
        let repository = try SpriteRepository(bundle: .main)
        let ready = await repository.prepareClip("full.idle")
        XCTAssertTrue(ready)
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = RoamPanelController(repository: repository)
        defer { controller.hide() }
        controller.show(centeredAt: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY),
                        screen: screen, scale: 1, clipID: "full.idle")
        let panel = try XCTUnwrap(controller.panel)
        let view = try XCTUnwrap(controller.petView)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.subviews.compactMap { $0 as? NSVisualEffectView }.isEmpty)
        XCTAssertTrue(view.subviews.compactMap { $0 as? NSButton }.isEmpty)
        XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenPrimary))
        func findPoints() throws -> (CGPoint, CGPoint) {
            var opaque: CGPoint?
            var clear: CGPoint?
            for y in stride(from: 1.0, to: view.bounds.height, by: 3) {
                for x in stride(from: 1.0, to: view.bounds.width, by: 3) {
                    let point = CGPoint(x: x, y: y)
                    if view.containsCharacter(at: point) { opaque = opaque ?? point }
                    else { clear = clear ?? point }
                }
            }
            return (try XCTUnwrap(opaque), try XCTUnwrap(clear))
        }
        func verifyMouseAcceptance() throws {
            let (opaque, clear) = try findPoints()
            XCTAssertTrue(view.hitTest(opaque) === view)
            XCTAssertNil(view.hitTest(clear))
            controller.refreshMouseAcceptance(at: panel.convertPoint(toScreen: clear))
            XCTAssertTrue(panel.ignoresMouseEvents, "Transparent pixels must make the whole window ignore mouse events")
            controller.refreshMouseAcceptance(at: panel.convertPoint(toScreen: opaque))
            XCTAssertFalse(panel.ignoresMouseEvents, "Opaque character pixels must remain interactive")
        }
        try verifyMouseAcceptance()
        controller.setCharacterScale(0.6)
        view.layoutSubtreeIfNeeded()
        try verifyMouseAcceptance()
    }

    func testAlphaMaskMatchesImageOrientationAndRejectsTransparentPixels() throws {
        // Explicit top-to-bottom RGBA rows: only top-right and bottom-left opaque.
        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for (x, y) in [(3, 0), (0, 3)] {
            let offset = (y * 4 + x) * 4
            pixels[offset] = 255
            pixels[offset + 3] = 255
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let mask = try XCTUnwrap(SpriteAlphaMask(image: image, rect: CGRect(x: 0, y: 0, width: 4, height: 4)))
        XCTAssertTrue(mask.contains(normalized: CGPoint(x: 0.875, y: 0.875)))
        XCTAssertTrue(mask.contains(normalized: CGPoint(x: 0.125, y: 0.125)))
        XCTAssertFalse(mask.contains(normalized: CGPoint(x: 0.125, y: 0.875)))
        XCTAssertFalse(mask.contains(normalized: CGPoint(x: 0.875, y: 0.125)))
        XCTAssertFalse(mask.contains(normalized: CGPoint(x: -0.1, y: 0.5)))
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
    private func wanderingFixture() throws -> (SpriteRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        let community = resources.appendingPathComponent("CommunityActions")
        try FileManager.default.createDirectory(at: community, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "io.whalegirl.tests." + UUID().uuidString,
                                   "CFBundlePackageType": "BNDL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        func writeJSON(_ value: Any, to url: URL) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: url)
        }
        try writeJSON(["schemaVersion": 1, "atlases": [], "clips": []],
                      to: resources.appendingPathComponent("sprite-manifest.json"))
        func frame(_ x: Int) -> [String: Any] {
            ["rect": ["x": x, "y": 0, "width": 4, "height": 4], "duration": 0.03,
             "anchor": ["x": 0.5, "y": 1],
             "visualBounds": ["x": 0, "y": 0, "width": 1, "height": 1],
             "hitbox": ["x": 0, "y": 0, "width": 1, "height": 1]]
        }
        let idle: [String: Any] = ["id": "full.community.idle", "atlasID": "community.fixture",
                                   "looping": true, "frames": [frame(0)]]
        let running: [String: Any] = ["id": "full.community.running", "atlasID": "community.fixture",
                                      "looping": false, "frames": (0..<52).map { frame(($0 % 2) * 4) }]
        let manual: [String: Any] = ["id": "full.community.manual", "atlasID": "community.fixture",
                                     "looping": false, "frames": [frame(4)]]
        try writeJSON(["schemaVersion": 1,
                       "atlases": [["id": "community.fixture", "resource": "CommunityActions/fixture.png",
                                    "pixelWidth": 8, "pixelHeight": 4]],
                       "clips": [idle, running, manual]], to: community.appendingPathComponent("sprite-manifest.json"))
        try writeJSON(["aliases": ["idle": "full.community.idle"],
                       "actions": [["clipID": "full.community.idle", "title": "待机", "category": "测试"],
                                   ["clipID": "full.community.running", "title": "原地左转奔跑", "category": "测试"]]],
                      to: community.appendingPathComponent("catalog.json"))
        var pixels = [UInt8](repeating: 0, count: 8 * 4 * 4)
        for y in 0..<4 {
            for x in [0, 1, 4, 5] {
                let index = (y * 8 + x) * 4
                pixels[index] = 255
                pixels[index + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 8, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: community.appendingPathComponent("fixture.png"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        return (try SpriteRepository(bundle: bundle), root)
    }

    private func waitForWanderingCondition(timeout: Double = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Timed out waiting for autonomous activity")
    }

    func testWanderingOccursAfterExactlyZeroThroughThreeCompletedActions() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for count in 0...3 {
            let view = PetView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), repository: repository,
                autonomy: .init(drawActionCount: { count }, idleDelay: 0.02...0.02, finishedPoseDelay: 0.02))
            var walks = 0
            var observed = [count]
            view.onRequestWander = {
                XCTAssertEqual(view.randomActionsUntilWalk, 0)
                walks += 1
            }
            view.play("full.idle")
            let deadline = Date().addingTimeInterval(8)
            while walks == 0, Date() < deadline {
                if observed.last != view.randomActionsUntilWalk { observed.append(view.randomActionsUntilWalk) }
                try await Task.sleep(for: .milliseconds(5))
            }
            if observed.last != view.randomActionsUntilWalk { observed.append(view.randomActionsUntilWalk) }
            XCTAssertEqual(walks, 1, "Must reach one walk for a count of \(count)")
            XCTAssertEqual(observed, Array(stride(from: count, through: 0, by: -1)))
            XCTAssertTrue(view.isWandering)
            view.finishAutonomousWalk()
            XCTAssertEqual(view.randomActionsUntilWalk, count, "A finished outing draws a new count")
            view.pauseAnimation()
            view.onRequestWander = nil
        }
    }

    func testWanderingIsInterruptedByInteractionManualPlaybackAndPause() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), repository: repository,
            autonomy: .init(drawActionCount: { 0 }, idleDelay: 0.02...0.02, finishedPoseDelay: 0.02))
        defer { view.pauseAnimation() }
        var requests = 0, cancels = 0
        view.onRequestWander = { requests += 1 }
        view.onCancelWander = { cancels += 1 }
        view.play("full.idle")
        try await waitForWanderingCondition { view.isWandering }
        view.beginUserInteraction()
        XCTAssertFalse(view.isWandering)
        XCTAssertEqual(cancels, 1)
        let stoppedAt = requests
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests, stoppedAt)
        view.endUserInteraction()
        try await waitForWanderingCondition { view.isWandering }
        view.onContextMenu = { _ in
            XCTAssertTrue(view.isUserInteracting)
            XCTAssertFalse(view.isWandering)
        }
        let right = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.rightMouseDown(with: right)
        try await waitForWanderingCondition { view.isWandering }
        view.play("full.community.manual", looping: false)
        XCTAssertFalse(view.isWandering)
        XCTAssertEqual(view.currentClipID, "full.community.manual")
        try await waitForWanderingCondition { view.isWandering }
        view.pauseAnimation()
        XCTAssertFalse(view.isWandering)
        let pausedAt = requests
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests, pausedAt)
        view.resumeAnimation()
        try await waitForWanderingCondition { view.isWandering }
    }

    func testWanderingMirrorsClickPixelsWithTheCharacter() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = await repository.prepareClip("full.walk")
        XCTAssertTrue(ready)
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), repository: repository)
        defer { view.pauseAnimation() }
        view.play("full.walk", looping: true)
        view.layoutSubtreeIfNeeded()
        let left = CGPoint(x: 10, y: 50), right = CGPoint(x: 90, y: 50)
        XCTAssertTrue(view.containsCharacter(at: left))
        XCTAssertFalse(view.containsCharacter(at: right))
        view.setWalkingDirection(toRight: true)
        XCTAssertFalse(view.containsCharacter(at: left))
        XCTAssertTrue(view.containsCharacter(at: right))
        view.setWalkingDirection(toRight: false)
        XCTAssertTrue(view.containsCharacter(at: left))
    }

    func testWanderingMovesWithinScreenAndStopsOnDragAndHide() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = RoamPanelController(repository: repository,
            autonomy: .init(drawActionCount: { 0 }, idleDelay: 0.02...0.02, finishedPoseDelay: 0.02))
        defer { controller.hide() }
        controller.show(centeredAt: CGPoint(x: screen.visibleFrame.maxX, y: screen.visibleFrame.maxY),
                        screen: screen, scale: 1, clipID: "full.idle")
        let view = try XCTUnwrap(controller.petView)
        let panel = try XCTUnwrap(controller.panel)
        try await waitForWanderingCondition { view.isWandering }
        let start = panel.frame
        controller.advanceWander(at: CACurrentMediaTime() + 100)
        XCTAssertNotEqual(panel.frame.origin, start.origin)
        XCTAssertTrue(screen.visibleFrame.contains(panel.frame))
        XCTAssertFalse(view.isWandering)
        try await waitForWanderingCondition { view.isWandering }
        view.beginUserInteraction()
        let stopped = panel.frame
        controller.advanceWander(at: CACurrentMediaTime() + 100)
        XCTAssertEqual(panel.frame, stopped)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(panel.frame, stopped)
        view.endUserInteraction()
        try await waitForWanderingCondition { view.isWandering }
        controller.hide()
        let hidden = panel.frame
        controller.advanceWander(at: CACurrentMediaTime() + 100)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.frame, hidden)
    }

    func testBundledWalkClipUsesOnlyTheContinuousRunningSection() throws {
        let repository = try SpriteRepository(bundle: .main)
        let source = try XCTUnwrap(repository.clip("full.community.318690038a1b"))
        let walk = try XCTUnwrap(repository.clip("full.walk"))
        XCTAssertTrue(walk.looping)
        XCTAssertEqual(walk.atlasID, source.atlasID)
        XCTAssertEqual(walk.frames, Array(source.frames[24..<52]))
        XCTAssertEqual(repository.communityActions.count, 133)
    }

    func testStationaryActionsAreUniqueAcrossFiveCharactersAndManualRequests() async throws {
        let repository = try SpriteRepository(bundle: .main)
        let preferred = repository.resolvedClipID("full.idle")
        let ready = await repository.prepareClip(preferred)
        XCTAssertTrue(ready)
        let views = (0..<5).map { _ in PetView(frame: CGRect(x: 0, y: 0, width: 240, height: 135),
            repository: repository, autonomy: .init(drawActionCount: { 3 }, idleDelay: 30...30)) }
        defer { views.forEach { $0.pauseAnimation(); $0.releaseStationaryAction() } }
        for view in views { view.play("full.idle"); view.beginUserInteraction() }
        XCTAssertEqual(Set(views.map(\.currentClipID)).count, 1)
        let action = try XCTUnwrap(repository.communityActions.first { $0.clipID != preferred })
        for view in views { view.play(action.clipID, looping: false) }
        XCTAssertEqual(Set(views.map(\.currentClipID)).count, 5)
        let firstID = views[0].currentClipID
        views[1].play(firstID, looping: false)
        XCTAssertNotEqual(views[1].currentClipID, firstID)
        XCTAssertEqual(Set(views.map(\.currentClipID)).count, 5)
        views[0].releaseStationaryAction()
        views[1].play(firstID, looping: false)
        XCTAssertEqual(views[1].currentClipID, firstID)
    }

    func testActionReservationsProtectOutgoingTexturesAndReleaseDeadOwners() throws {
        let repository = try SpriteRepository(bundle: .main)
        let ids = Array(repository.communityActions.prefix(3).map(\.clipID))
        var first: NSObject? = NSObject()
        let second = NSObject()
        XCTAssertEqual(repository.claimStationaryAction(ids[0], candidates: [], owner: first!), ids[0])
        XCTAssertEqual(repository.claimStationaryAction(ids[1], candidates: [], owner: first!), ids[1])
        XCTAssertNil(repository.claimStationaryAction(ids[0], candidates: [ids[1]], owner: second))
        repository.retainStationaryAction(ids[1], owner: first!)
        XCTAssertEqual(repository.claimStationaryAction(ids[0], candidates: [], owner: second), ids[0])
        first = nil
        XCTAssertEqual(repository.claimStationaryAction(ids[1], candidates: [], owner: second), ids[1])
        let idleOwner = NSObject(), returnOwner = NSObject()
        let idle = repository.resolvedClipID("full.idle")
        XCTAssertEqual(repository.claimStationaryAction(idle, candidates: [], owner: idleOwner), idle)
        XCTAssertNil(repository.claimStationaryAction("full.community.return", candidates: [], owner: returnOwner))
    }

    func testOnlyTheRetainedWalkingAssetsAreBundled() throws {
        let repository = try SpriteRepository(bundle: .main)
        XCTAssertEqual(repository.walkingActions.count, 2)
        let side = try XCTUnwrap(repository.clip("full.walk.side"))
        let source = try XCTUnwrap(repository.clip("full.community.10e8815c6fa8"))
        XCTAssertEqual(side.frames, Array(source.frames[24..<88]))
        XCTAssertNil(repository.clip("full.walk.yunyue"))
        XCTAssertNil(Bundle.main.url(forResource: "yunyue-walk", withExtension: "webp", subdirectory: "CommunityActions"))
    }

    func testCompactAtlasesKeepTheOriginalLogicalCanvasSize() throws {
        let repository = try SpriteRepository(bundle: .main)
        let idle = try XCTUnwrap(repository.clip("full.idle"))
        let layout = try XCTUnwrap(repository.renderLayout(for: idle.id))
        XCTAssertEqual(layout.canvasWidth, 384)
        XCTAssertEqual(layout.canvasHeight, 216)
        XCTAssertEqual(repository.canvasAspect(for: idle.id), 384.0 / 216.0)
        XCTAssertLessThan(layout.width * layout.height, 384 * 216)
        XCTAssertEqual(idle.frames.first?.rect.width, layout.width)
        XCTAssertEqual(idle.frames.first?.rect.height, layout.height)
        XCTAssertGreaterThanOrEqual(layout.normalized.minX, 0)
        XCTAssertGreaterThanOrEqual(layout.normalized.minY, 0)
        XCTAssertLessThanOrEqual(layout.normalized.maxX, 1)
        XCTAssertLessThanOrEqual(layout.normalized.maxY, 1)
    }

    func testSpeechBubbleFitsShortTextAndWrapsLongText() throws {
        let repository = try SpriteRepository(bundle: .main)
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 360, height: 220), repository: repository)
        view.say("你好")
        let bubble = try XCTUnwrap(view.subviews.first { $0.identifier?.rawValue == "character.speech-bubble" })
        let short = bubble.frame.size
        XCTAssertLessThan(short.width, 100)
        view.say("在看什么？")
        XCTAssertGreaterThan(bubble.frame.width, short.width)
        view.say(String(repeating: "鲸鱼娘陪你工作，", count: 8))
        XCTAssertLessThanOrEqual(bubble.frame.width, 240)
        XCTAssertGreaterThan(bubble.frame.height, short.height)
        XCTAssertEqual(bubble.frame.midX, view.bounds.midX, accuracy: 0.5)
    }

    func testVisibleDialogueWindowsAcrossBothSkinsWithRenderedEvidence() async throws {
        let domain = "io.whalegirl.tests.visible-dialogue.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let repository = try SpriteRepository(bundle: .main, defaults: defaults)
        let screen = try XCTUnwrap(NSScreen.main)
        let pets = (0..<2).map { _ in RoamPanelController(repository: repository,
            autonomy: .init(drawActionCount: { 3 }, idleDelay: 60...60)) }
        defer { pets.forEach { $0.hide() } }
        for (index, pet) in pets.enumerated() {
            pet.show(centeredAt: CGPoint(x: screen.visibleFrame.midX + Double(index * 320 - 160),
                                        y: screen.visibleFrame.midY), screen: screen, scale: 1, clipID: "full.idle")
            pet.petView?.beginUserInteraction()
        }
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        func label(_ view: PetView) throws -> NSTextView {
            let bubble = try XCTUnwrap(view.subviews.first { $0.identifier?.rawValue == "character.speech-bubble" })
            return try XCTUnwrap(bubble.subviews.compactMap { $0 as? NSTextView }.first)
        }
        func capture(_ view: PetView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            view.window?.displayIfNeeded()
            CATransaction.flush()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for skin in SpriteRepository.Skin.allCases {
            if repository.selectSkin(skin) { pets.forEach { $0.petView?.refreshSkin() } }
            let views = try pets.map { try XCTUnwrap($0.petView) }
            let expected = try XCTUnwrap(repository.clip("full.idle"))
            let ready = await repository.prepareClip(expected.id)
            XCTAssertTrue(ready)
            let texture = try XCTUnwrap(repository.cgImage(atlasID: expected.atlasID))
            try await waitForWanderingCondition(timeout: 15) {
                pets.allSatisfy(\.isVisible) && views.allSatisfy {
                    ($0.layer?.sublayers?.first?.contents as AnyObject?) === texture
                }
            }
            for round in 0..<3 {
                views.forEach { $0.mouseEntered(with: event) }
                let lines = try views.map { try label($0).string }
                XCTAssertNotEqual(lines[0], lines[1])
                XCTAssertTrue(lines.allSatisfy { DeepSeekChanDialog.lines.contains($0) })
                for (index, view) in views.enumerated() {
                    try capture(view, name: "\(skin.rawValue)-random-\(round)-pet-\(index)")
                }
                views.forEach { $0.mouseExited(with: event) }
            }
            views[0].say("在看什么？")
            views[1].say("事情可以慢慢想，饭要趁热吃。主人放心，尾巴摇着，脑子也没停。")
            for (index, view) in views.enumerated() {
                try capture(view, name: "\(skin.rawValue)-regression-pet-\(index)")
            }
        }
    }

    func testSpeechBubbleLaysOutEveryCharacterAtSmallAndNormalSizes() throws {
        let repository = try SpriteRepository(bundle: .main)
        let lines = ["在看什么？", "你好", "你好🐋，Token 余额还有多少？"] + DeepSeekChanDialog.lines
        for width in [80.0, 150, 266, 360] {
            let view = PetView(frame: CGRect(x: 0, y: 0, width: width, height: 220), repository: repository)
            for line in lines {
                view.say(line)
                let bubble = try XCTUnwrap(view.subviews.first { $0.identifier?.rawValue == "character.speech-bubble" })
                let text = try XCTUnwrap(bubble.subviews.compactMap { $0 as? NSTextView }.first)
                let manager = try XCTUnwrap(text.layoutManager)
                let container = try XCTUnwrap(text.textContainer)
                manager.ensureLayout(for: container)
                let laidOut = manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil)
                XCTAssertEqual(laidOut, NSRange(location: 0, length: (line as NSString).length), line)
                XCTAssertLessThanOrEqual(manager.usedRect(for: container).maxY, text.bounds.height, line)
                XCTAssertLessThanOrEqual(manager.usedRect(for: container).maxX, text.bounds.width + 0.5, line)
                XCTAssertTrue(bubble.bounds.contains(text.frame), line)
                XCTAssertLessThanOrEqual(bubble.frame.maxY, view.bounds.height)
            }
        }
    }

    func testDesktopHoverUsesRandomDialogueWithoutConsecutiveRepeats() throws {
        let repository = try SpriteRepository(bundle: .main)
        let views = (0..<2).map { _ in PetView(frame: CGRect(x: 0, y: 0, width: 266, height: 150), repository: repository) }
        defer { views.forEach { $0.pauseAnimation(); $0.releaseStationaryAction() } }
        views.forEach { $0.play("full.idle"); $0.beginUserInteraction() }
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        var previous: String?
        for index in 0..<20 {
            let view = views[index % 2]
            view.mouseEntered(with: event)
            let bubble = try XCTUnwrap(view.subviews.first { $0.identifier?.rawValue == "character.speech-bubble" })
            let text = try XCTUnwrap(bubble.subviews.compactMap { $0 as? NSTextView }.first)
            XCTAssertTrue(DeepSeekChanDialog.lines.contains(text.string))
            XCTAssertNotEqual(text.string, previous)
            XCTAssertFalse(bubble.isHidden)
            previous = text.string
            view.mouseExited(with: event)
            XCTAssertTrue(bubble.isHidden)
        }
    }

    func testFullscreenGeometryRespectsFrontAppDialogsAndDisplayCoordinates() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let other = CGRect(x: -1280, y: 200, width: 1280, height: 720)
        func window(_ rect: CGRect, pid: Int32) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: 0,
             kCGWindowAlpha as String: 1, kCGWindowBounds as String: rect.dictionaryRepresentation]
        }
        let full = window(main, pid: 42)
        let normal = window(CGRect(x: 100, y: 40, width: 900, height: 700), pid: 77)
        let dialog = window(CGRect(x: 400, y: 300, width: 400, height: 200), pid: 42)
        XCTAssertEqual(FullScreenAvoidance.coveredDisplays([main], windows: [full], primaryTop: 900, ownPID: 1), [main])
        XCTAssertTrue(FullScreenAvoidance.coveredDisplays([main], windows: [normal, full], primaryTop: 900, ownPID: 1).isEmpty)
        XCTAssertEqual(FullScreenAvoidance.coveredDisplays([main], windows: [dialog, full], primaryTop: 900, ownPID: 1), [main])
        let otherFull = window(CGRect(x: -1280, y: -20, width: 1280, height: 720), pid: 52)
        XCTAssertEqual(FullScreenAvoidance.coveredDisplays([main, other], windows: [normal, otherFull], primaryTop: 900, ownPID: 1), [other])
    }

}

private final class NetworkDownloadFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { ["network-fixture.invalid", "127.0.0.1"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.url?.path == "/forbidden" ? 403 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url?.path == "/stall" { return }
        if status == 200 { client?.urlProtocol(self, didLoad: Data(repeating: 42, count: 8192)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class NetworkLineTimingFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var first: TimeInterval?, second: TimeInterval?
    func record(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if line == "first" { first = ProcessInfo.processInfo.systemUptime }
        if line == "second" { second = ProcessInfo.processInfo.systemUptime }
    }
    var gap: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return (second ?? 0) - (first ?? 0)
    }
}
