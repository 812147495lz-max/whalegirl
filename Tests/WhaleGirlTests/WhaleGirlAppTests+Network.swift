import AppKit
import QuartzCore
import WhaleCore
import XCTest
@testable import WhaleGirl

extension WhaleGirlAppTests {
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
        XCTAssertTrue(descendants(of: view).compactMap { $0 as? NSButton }.contains { $0.title == "测速" })
        let speedButton = try XCTUnwrap(view.networkTestButton)
        speedButton.performClick(nil)
        let options = try XCTUnwrap(NetworkQuickTestController.visibleWindow)
        XCTAssertTrue(options.isVisible)
        XCTAssertGreaterThanOrEqual(options.frame.minX, try XCTUnwrap(controller.informationPanel).frame.maxX - 30)
        XCTAssertTrue(screen.visibleFrame.contains(options.frame))
        let optionsView = try XCTUnwrap(options.contentView)
        optionsView.layoutSubtreeIfNeeded(); optionsView.displayIfNeeded()
        try attachSnapshot(of: optionsView, named: "network-quick-options")
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
        let buttons = descendants(of: content).compactMap { $0 as? NSButton }
        for title in ["开始检测", "测试设置"] {
            XCTAssertTrue(buttons.contains { $0.title == title && $0.isEnabled })
        }
        XCTAssertTrue(buttons.contains { $0.title == "停止" && !$0.isEnabled })
        let popup = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Google") })
        XCTAssertEqual(popup.itemTitles, ["Google", "GitHub", "百度", "哔哩哔哩", "自定义网址 / IP"])
        let address = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "networkTarget" })
        XCTAssertFalse(address.isEnabled)
        popup.selectItem(at: 4)
        _ = popup.target?.perform(popup.action, with: popup)
        XCTAssertTrue(address.isEnabled)
        XCTAssertFalse(store.busy)
        let table = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 1)
        content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
        try attachSnapshot(of: content, named: "network-diagnostics-fixture")
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
