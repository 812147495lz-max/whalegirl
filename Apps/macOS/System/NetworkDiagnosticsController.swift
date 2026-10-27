import AppKit
import Foundation
import Darwin
import WhaleCore

/// One owned child process, no shell, bounded output and wall time. All I/O runs off the main actor.
final class NetworkDiagnosticProcess: Sendable {
    struct Result: Sendable { let output: String; let exitCode: Int32; let cancelled: Bool; let timedOut: Bool }
    private let process = BoundedProcess()
    func cancel() { process.cancel() }
    func run(executable: String, arguments: [String], timeout: TimeInterval,
             onLine: @escaping @Sendable (String) -> Void = { _ in }) throws -> Result {
        var command = BoundedProcess.Command(URL(fileURLWithPath: executable), arguments, timeout: timeout, outputLimit: 262_144)
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["LANG"] = "C"
        command.environment = environment; command.mergeStandardError = true
        let result = try process.run(command, onLine: onLine)
        return Result(output: String(decoding: result.data, as: UTF8.self), exitCode: result.exitCode,
                      cancelled: result.cancelled, timedOut: result.timedOut || result.overflow)
    }
}

struct TargetDownloadReading: Sendable {
    let bytes: Int64
    let seconds: TimeInterval
    let limited: Bool
    var megabitsPerSecond: Double { Double(bytes) * 8 / max(0.001, seconds) / 1_000_000 }
}
enum NetworkProbeFailure: Error, LocalizedError {
    case http(Int), noData, redirects
    var errorDescription: String? {
        switch self {
        case .http(let code): "目标返回 HTTP \(code)，下载测试失败"
        case .noData: "目标未返回下载数据"
        case .redirects: "重定向异常，请检查网址"
        }
    }
}

/// Streams and discards bytes. No cookies, credentials, cache or files are retained.
final class NetworkTargetDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let byteLimit: Int64
    private let timeLimit: TimeInterval
    private var continuation: CheckedContinuation<TargetDownloadReading, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var watchdog: DispatchWorkItem?
    private var cancelled = false
    private var bytes: Int64 = 0
    private var started: TimeInterval = 0
    private var redirects = 0
    init(configuration: URLSessionConfiguration = .ephemeral, byteLimit: Int64 = 16 * 1024 * 1024, timeLimit: TimeInterval = 10) {
        self.configuration = configuration; self.byteLimit = max(1, byteLimit); self.timeLimit = max(0.1, timeLimit)
    }
    func run(url: URL) async throws -> TargetDownloadReading {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion in
                lock.lock()
                guard !cancelled else { lock.unlock(); completion.resume(throwing: CancellationError()); return }
                continuation = completion; started = ProcessInfo.processInfo.systemUptime
                configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil; configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = timeLimit; configuration.timeoutIntervalForResource = timeLimit + 2
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: url); request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                let task = session.dataTask(with: request); self.task = task
                let watchdog = DispatchWorkItem { [weak self] in self?.finish(error: nil, limited: true) }
                self.watchdog = watchdog; lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeLimit, execute: watchdog)
                task.resume()
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(error: CancellationError())
    }
    private func finish(error: Error?, limited: Bool = false) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let result = TargetDownloadReading(bytes: bytes, seconds: max(0.001, ProcessInfo.processInfo.systemUptime - started), limited: limited)
        let session = session; self.session = nil; task = nil
        watchdog?.cancel(); watchdog = nil
        lock.unlock()
        session?.invalidateAndCancel()
        if let error { continuation.resume(throwing: error) }
        else if result.bytes == 0 { continuation.resume(throwing: NetworkProbeFailure.noData) }
        else { continuation.resume(returning: result) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); finish(error: NetworkProbeFailure.noData); return }
        guard (200..<300).contains(http.statusCode) else { completionHandler(.cancel); finish(error: NetworkProbeFailure.http(http.statusCode)); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        bytes += min(Int64(data.count), max(0, byteLimit - bytes))
        let reached = bytes >= byteLimit; lock.unlock()
        if reached { finish(error: nil, limited: true) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as? URLError)?.code != .timedOut { finish(error: error) }
        else { finish(error: nil, limited: error != nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let count = redirects; lock.unlock()
        guard count <= 5, let url = request.url, (try? NetworkTestTarget(url.absoluteString)) != nil else {
            completionHandler(nil); finish(error: NetworkProbeFailure.redirects); return
        }
        completionHandler(request)
    }
}

private final class NetworkRouteProgress: @unchecked Sendable {
    struct Update: Sendable { let trace: RouteTrace; let revision: Int }
    private let lock = NSLock()
    private var trace = RouteTrace()
    private var revision = 0
    func ingest(_ line: String) -> Update? {
        lock.lock(); defer { lock.unlock() }
        guard trace.ingest(line) else { return nil }
        revision += 1
        return Update(trace: trace, revision: revision)
    }
}

@MainActor
final class NetworkDiagnosticsStore {
    static let shared = NetworkDiagnosticsStore()
    enum TestKind { case latency, route, targetDownload, capacity }
    enum QuickMode: Int, CaseIterable {
        case complete, route, download, capacity
        var title: String { ["综合检测", "延迟与路由", "下载测速", "公网带宽"][rawValue] }
        var stages: [TestKind] {
            switch self {
            case .complete: [.latency, .route, .targetDownload]
            case .route: [.latency, .route]
            case .download: [.targetDownload]
            case .capacity: [.capacity]
            }
        }
    }
    struct Settings {
        var maxHops = 30
        var downloadMiB = 16
        var downloadSeconds = 10
    }
    var settings = Settings()
    var targetIndex = 0
    var customAddress = ""
    var ipv6 = false
    var quickMode = QuickMode.complete
    var selectedInput: String { Self.presets.indices.contains(targetIndex) ? Self.presets[targetIndex] : customAddress }
    static let presets = ["www.google.com", "github.com", "www.baidu.com", "www.bilibili.com"]
    private(set) var quickRunning = false
    var isRunning: Bool { busy || quickRunning }
    var onQuickChange: (() -> Void)?
    var onQuickCompletion: ((String) -> Void)?
    private var quickTask: Task<Void, Never>?
    private var quickCancelled = false
    private(set) var lastSpeech: String?
    private(set) var lastTest: TestKind?
    private(set) var latencyHost: String?
    private(set) var downloadHost: String?
    private(set) var latency: Double?
    private(set) var latencyText = "目标延迟：—"
    private(set) var downloadReading: TargetDownloadReading?
    private(set) var capacityReading: NetworkCapacityReading?
    var onChange: (() -> Void)?
    private(set) var trace = RouteTrace()
    private(set) var routeTarget: String?
    private(set) var status = "准备就绪"
    private(set) var targetSpeed = "目标下载：—"
    private(set) var capacitySpeed = "公网带宽：—"
    private(set) var busy = false
    private var runID = UUID()
    private var traceRevision = 0
    private var process: NetworkDiagnosticProcess?
    private var download: NetworkTargetDownload?
    private var task: Task<Void, Never>?
    private let downloadConfiguration: URLSessionConfiguration
    init(trace: RouteTrace = .init(), downloadConfiguration: URLSessionConfiguration = .ephemeral) {
        self.trace = trace; self.downloadConfiguration = downloadConfiguration
    }
    private func changed() { onChange?(); onQuickChange?() }
    func startQuick() {
        guard !isRunning else { return }
        let target: NetworkTestTarget
        do { target = try NetworkTestTarget(quickMode == .capacity ? "www.apple.com" : selectedInput) }
        catch { status = error.localizedDescription; changed(); return }
        let mode = quickMode, family = ipv6
        quickRunning = true; quickCancelled = false; lastSpeech = nil
        latency = nil; latencyHost = nil; downloadHost = nil; downloadReading = nil; capacityReading = nil
        latencyText = "目标延迟：—"; targetSpeed = "目标下载：—"; capacitySpeed = "公网带宽：—"
        if mode == .complete || mode == .route { trace = RouteTrace(); routeTarget = nil }
        quickTask = Task { [weak self] in
            guard let self else { return }
            for stage in mode.stages {
                guard !self.quickCancelled, !Task.isCancelled else { break }
                self.begin(stage, input: target.downloadURL.absoluteString, ipv6: family)
                if let operation = self.task { await operation.value }
            }
            self.quickRunning = false; self.quickTask = nil
            guard !self.quickCancelled, !Task.isCancelled else { self.status = "检测已停止"; self.changed(); return }
            var report = NetworkQuickReport(host: mode == .capacity ? "Apple 公网带宽" : target.host)
            report.latency = self.latency
            if mode == .complete || mode == .route { report.trace = self.trace }
            report.downloadRequested = mode != .route
            report.publicBandwidth = mode == .capacity
            report.downloadMbps = mode == .capacity ? self.capacityReading?.downloadMbps : self.downloadReading?.megabitsPerSecond
            report.smallDownload = self.downloadReading.map { $0.bytes < 1_048_576 } ?? false
            self.lastSpeech = report.speech
            self.status = "检测完成"
            self.changed(); self.onQuickCompletion?(report.speech)
        }
        changed()
    }
    func start(_ kind: TestKind, input: String, ipv6: Bool = false) {
        guard !isRunning else { return }
        lastSpeech = nil
        begin(kind, input: input, ipv6: ipv6)
    }
    private func begin(_ kind: TestKind, input: String, ipv6: Bool) {
        guard !busy else { return }
        let target: NetworkTestTarget
        do { target = try NetworkTestTarget(input) }
        catch { status = error.localizedDescription; changed(); return }
        busy = true; lastTest = kind; let id = UUID(); runID = id
        switch kind {
        case .latency:
            latencyHost = target.host
            latency = nil; latencyText = "目标延迟（\(target.host)）：测量中…"
            status = "正在测量延迟…"
            let process = NetworkDiagnosticProcess(); self.process = process
            task = Task { [weak self] in
                do {
                    let result = try await Task.detached(priority: .utility) {
                        try process.run(executable: ipv6 ? "/sbin/ping6" : "/sbin/ping", arguments: ["-n", "-c", "3", target.host], timeout: 6)
                    }.value
                    guard let self, self.runID == id else { return }
                    guard !result.cancelled else { throw CancellationError() }
                    let reading = try NetworkLatencyReading(output: result.output)
                    self.latency = reading.averageMilliseconds
                    self.latencyText = String(format: "目标延迟（%@）：%.2f ms · ICMP 平均 RTT", target.host, reading.averageMilliseconds)
                    self.status = "延迟测试完成"
                } catch {
                    guard let self, self.runID == id else { return }
                    self.latencyText = "目标延迟（\(target.host)）：未测得"
                    self.status = error is CancellationError ? "延迟测试已停止。" : "目标未回复延迟探测"
                }
                self?.finish(id)
            }
        case .route:
            let maxHops = min(64, max(1, settings.maxHops))
            trace = RouteTrace(); routeTarget = target.host + (ipv6 ? " · IPv6" : " · IPv4")
            status = "正在追踪路由…"
            let process = NetworkDiagnosticProcess(); self.process = process
            let owner = self, progress = NetworkRouteProgress()
            traceRevision = 0
            task = Task { [weak self] in
                do {
                    let result = try await Task.detached(priority: .utility) {
                        try process.run(executable: ipv6 ? "/usr/sbin/traceroute6" : "/usr/sbin/traceroute",
                                        arguments: ["-n", "-q", "3", "-w", "1", "-m", String(maxHops), target.host], timeout: Double(maxHops * 3 + 10)) { line in
                            guard let update = progress.ingest(line) else { return }
                            Task { @MainActor [weak owner = owner] in
                                guard let self = owner, self.runID == id, self.busy, update.revision > self.traceRevision else { return }
                                self.trace = update.trace; self.traceRevision = update.revision; self.changed()
                            }
                        }
                    }.value
                    guard let self, self.runID == id else { return }
                    // Apply final complete output too, so queued progress cannot lose the last hop.
                    var complete = RouteTrace()
                    for line in result.output.split(separator: "\n") { complete.ingest(String(line)) }
                    self.trace = complete
                    if result.cancelled { self.status = "路由追踪已停止 · " + self.trace.summary }
                    else if result.timedOut { self.status = "路由追踪超时 · " + self.trace.summary }
                    else if result.exitCode != 0 { self.status = "路由测试未完成，请检查目标或 IP 协议" }
                    else { self.status = "路由追踪完成" }
                } catch { self?.status = error is CancellationError ? "测试已停止。" : "无法启动系统路由测试。" }
                self?.finish(id)
            }
        case .targetDownload:
            downloadHost = target.host
            let prefix = "目标下载（\(target.host)）"
            let mib = min(32, max(1, settings.downloadMiB)), seconds = min(20, max(2, settings.downloadSeconds))
            downloadReading = nil
            status = "正在测量下载速度…"; targetSpeed = prefix + "：测量中…"
            let download = NetworkTargetDownload(configuration: downloadConfiguration, byteLimit: Int64(mib) * 1024 * 1024, timeLimit: Double(seconds)); self.download = download
            task = Task { [weak self] in
                do {
                    let result = try await download.run(url: target.downloadURL)
                    guard let self, self.runID == id else { return }
                    self.downloadReading = result
                    let amount = ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .binary)
                    self.targetSpeed = prefix + String(format: "：%.2f Mbps · %@ · %.2f 秒", result.megabitsPerSecond, amount, result.seconds)
                    self.status = result.bytes < 1_048_576 ? "下载完成 · 页面速度仅供参考" : "下载测试完成"
                } catch {
                    guard let self, self.runID == id else { return }
                    self.targetSpeed = prefix + "：未取得有效结果"
                    self.status = error is CancellationError ? "下载测速已停止。" : (error as? NetworkProbeFailure)?.localizedDescription ?? "下载失败，请检查网址或连接"
                }
                self?.finish(id)
            }
        case .capacity:
            capacityReading = nil
            status = "正在测量公网带宽…"; capacitySpeed = "公网带宽：测量中…"
            let process = NetworkDiagnosticProcess(); self.process = process
            task = Task { [weak self] in
                do {
                    let result = try await Task.detached(priority: .utility) {
                        try process.run(executable: "/usr/bin/networkQuality", arguments: ["-c", "-M", "20"], timeout: 25)
                    }.value
                    guard let self, self.runID == id else { return }
                    guard !result.cancelled else { throw CancellationError() }
                    guard !result.timedOut, result.exitCode == 0, let start = result.output.firstIndex(of: "{"), let end = result.output.lastIndex(of: "}") else { throw NetworkDiagnosticError.invalidReading }
                    let reading = try NetworkCapacityReading(json: Data(result.output[start...end].utf8))
                    self.capacityReading = reading
                    func speed(_ n: Double?) -> String { n.map { String(format: "%.2f Mbps", $0) } ?? "不可用" }
                    self.capacitySpeed = "公网下载：\(speed(reading.downloadMbps))   上传：\(speed(reading.uploadMbps))"
                    if let latency = reading.idleMilliseconds { self.capacitySpeed += String(format: "\n空闲往返延迟：%.2f ms", latency) }
                    self.status = "公网带宽测试完成"
                } catch {
                    guard let self, self.runID == id else { return }
                    self.capacitySpeed = "公网带宽：未取得有效结果"
                    self.status = error is CancellationError ? "公网带宽测试已停止。" : "未取得有效测速结果，请稍后重试"
                }
                self?.finish(id)
            }
        }
        changed()
    }
    private func finish(_ id: UUID) {
        guard runID == id else { return }
        busy = false; process = nil; download = nil; task = nil; changed()
    }
    func cancel() {
        guard isRunning else { return }
        quickCancelled = true; quickTask?.cancel()
        status = "正在停止测试…"; process?.cancel(); download?.cancel(); task?.cancel(); changed()
    }
}

@MainActor
private final class NetworkResultTiles: NSStackView {
    private let latency: WhaleMetricTile
    private let hops: WhaleMetricTile
    private let download: WhaleMetricTile
    private let upload: WhaleMetricTile
    private let compact: Bool
    init(compact: Bool = false) {
        self.compact = compact
        latency = WhaleMetricTile("延迟", compact: compact); hops = WhaleMetricTile("跳数", compact: compact)
        download = WhaleMetricTile("下载", compact: compact); upload = WhaleMetricTile("上传", compact: compact)
        super.init(frame: .zero)
        orientation = .horizontal; distribution = .fillEqually; spacing = 8
        for tile in [latency, hops, download] { addArrangedSubview(tile) }
        if !compact { addArrangedSubview(upload) }
    }
    required init?(coder: NSCoder) { nil }
    func update(_ store: NetworkDiagnosticsStore) {
        func value(_ n: Double?, digits: Int = 1) -> String { n.map { String(format: "%.*f", digits, $0) } ?? "—" }
        if compact && store.quickMode == .capacity {
            latency.isHidden = false; hops.isHidden = false
            latency.update(value(store.capacityReading?.idleMilliseconds), caption: "ms", title: "延迟")
            hops.update(value(store.capacityReading?.uploadMbps), caption: "Mbps", title: "上传")
            download.update(value(store.capacityReading?.downloadMbps), caption: "Mbps", title: "下载")
            return
        }
        latency.isHidden = compact && store.quickMode == .download
        hops.isHidden = compact && store.quickMode == .download
        download.isHidden = compact && store.quickMode == .route
        latency.update(value(store.latency), caption: compact ? "ms" : (store.latencyHost ?? ""), title: compact ? "延迟" : "延迟 · ms")
        let count = store.trace.reachedHop ?? store.trace.hops.last?.number
        hops.update(count.map(String.init) ?? "—", caption: count == nil ? " " : (store.trace.reachedHop == nil ? "终点未确认" : "已到达"), title: "跳数")
        let reading = store.downloadReading
        let small = reading.map { $0.bytes < 1_048_576 } ?? false
        download.update(value(reading?.megabitsPerSecond), caption: small ? (compact ? "Mbps · 参考" : "页面参考") : (compact ? "Mbps" : (store.downloadHost ?? "")), title: compact ? "下载" : "下载 · Mbps")
        if !compact, let reading {
            let amount = ByteCountFormatter.string(fromByteCount: reading.bytes, countStyle: .binary)
            let detail = String(format: "%@ · %.1f s", amount, reading.seconds)
            download.update(value(reading.megabitsPerSecond), caption: (store.downloadHost ?? "") + "\n" + detail + (small ? " · 参考" : ""), title: "下载 · Mbps")
        }
        upload.update(value(store.capacityReading?.uploadMbps), caption: store.capacityReading == nil ? "" : "Apple 服务", title: "公网上传 · Mbps")
        if !compact, store.lastTest == .capacity, let reading = store.capacityReading {
            download.update(value(reading.downloadMbps), caption: "Apple 服务", title: "公网下载 · Mbps")
            latency.update(value(reading.idleMilliseconds), caption: "空闲往返", title: compact ? "延迟" : "延迟 · ms")
        }
    }
}

@MainActor
final class NetworkDiagnosticsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var instance: NetworkDiagnosticsWindow?
    static func show() {
        if instance == nil { instance = NetworkDiagnosticsWindow(store: .shared) }
        instance?.testChoice.selectItem(at: NetworkDiagnosticsStore.shared.quickMode.rawValue)
        instance?.refresh(); instance?.showWindow(nil); instance?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    static func stop() { NetworkDiagnosticsStore.shared.cancel(); NetworkQuickTestController.dismiss() }
    static func showHelp() {
        let alert = NSAlert(); alert.messageText = "关于网络测试"
        alert.informativeText = "延迟是本机到目标的往返时间。* 表示未响应，不一定断网；代理或 VPN 可能改变路径。\n\n目标下载测量所选网址，较小的页面不能代表带宽上限。公网带宽使用独立的 Apple 服务，与所选网站无关。测试会产生网络流量。"
        alert.addButton(withTitle: "知道了"); alert.runModal()
    }
    let store: NetworkDiagnosticsStore
    private let targetPopup = NSPopUpButton()
    private let address = NSTextField()
    private let family = NSPopUpButton()
    private let testChoice = NSPopUpButton()
    private let startButton = NSButton(title: "开始检测", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let maxHops = NSPopUpButton()
    private let byteLimit = NSPopUpButton()
    private let timeLimit = NSPopUpButton()
    private let status = WhalePanelStyle.label("", size: 12, secondary: true)
    private let routeSummary = WhalePanelStyle.label("", size: 12, secondary: true)
    private let results = NetworkResultTiles()
    private let spinner = NSProgressIndicator()
    private let table = NSTableView()
    private let settingsToggle = NSButton(title: "测试设置", target: nil, action: nil)
    private var settingsPanel = NSView()
    private let serviceNote = WhalePanelStyle.label("", size: 11, secondary: true)
    private let presets = NetworkDiagnosticsStore.presets
    init(store: NetworkDiagnosticsStore = .init()) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 700), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "网络诊断与测速"; window.minSize = NSSize(width: 780, height: 660)
        window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        build(); store.onChange = { [weak self] in self?.refresh() }; refresh()
    }
    required init?(coder: NSCoder) { nil }
    private func build() {
        guard let root = window?.contentView else { return }
        WhalePanelStyle.surface(root)
        let title = WhalePanelStyle.label("网络测速", size: 20, weight: .semibold)
        let help = NSButton(title: "?", target: self, action: #selector(helpClicked)); help.bezelStyle = .helpButton; help.setAccessibilityLabel("网络测试帮助")
        settingsToggle.target = self; settingsToggle.action = #selector(toggleSettings)
        settingsToggle.isBordered = false; settingsToggle.font = .systemFont(ofSize: 12); settingsToggle.contentTintColor = WhalePanelStyle.accent
        let header = WhalePanelStyle.row([title, NSView(), settingsToggle, help])
        targetPopup.addItems(withTitles: ["Google", "GitHub", "百度", "哔哩哔哩", "自定义网址 / IP"])
        targetPopup.target = self; targetPopup.action = #selector(targetChanged); targetPopup.setAccessibilityLabel("测试目标")
        targetPopup.widthAnchor.constraint(equalToConstant: 170).isActive = true
        testChoice.addItems(withTitles: NetworkDiagnosticsStore.QuickMode.allCases.map(\.title) + ["仅测延迟", "仅查路由"])
        testChoice.target = self; testChoice.action = #selector(targetChanged); testChoice.setAccessibilityLabel("检测项目")
        startButton.target = self; startButton.action = #selector(startSelection)
        stopButton.target = self; stopButton.action = #selector(stopTest)
        WhalePanelStyle.button(startButton, primary: true); WhalePanelStyle.button(stopButton)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let controls = WhalePanelStyle.row([WhalePanelStyle.label("目标", secondary: true), targetPopup, WhalePanelStyle.label("项目", secondary: true), testChoice, NSView(), spinner, startButton, stopButton], spacing: 10)
        address.placeholderString = "网址、域名或 IP"; address.identifier = .init("networkTarget"); address.setAccessibilityLabel("自定义测试地址")
        serviceNote.stringValue = "检测会产生网络流量"
        let targetCard = WhalePanelStyle.card(WhalePanelStyle.column([controls, address, serviceNote], spacing: 10))
        family.addItems(withTitles: ["IPv4", "IPv6"]); family.setAccessibilityLabel("IP 协议")
        family.target = self; family.action = #selector(targetChanged)
        maxHops.addItems(withTitles: ["15 跳", "30 跳", "45 跳", "64 跳"])
        byteLimit.addItems(withTitles: ["4 MiB", "16 MiB", "32 MiB"])
        timeLimit.addItems(withTitles: ["5 秒", "10 秒", "20 秒"])
        maxHops.setAccessibilityLabel("最大跳数"); byteLimit.setAccessibilityLabel("下载流量上限"); timeLimit.setAccessibilityLabel("下载时间上限")
        for popup in [maxHops, byteLimit, timeLimit] { popup.target = self; popup.action = #selector(settingsChanged) }
        settingsPanel = WhalePanelStyle.card(WhalePanelStyle.row([WhalePanelStyle.label("协议", secondary: true), family, WhalePanelStyle.label("路由上限", secondary: true), maxHops, WhalePanelStyle.label("下载上限", secondary: true), byteLimit, timeLimit, NSView()], spacing: 10))
        settingsPanel.isHidden = true
        let routeHeader = WhalePanelStyle.row([WhalePanelStyle.label("路由明细", size: 13, weight: .semibold), routeSummary, NSView()])
        routeSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.wantsLayer = true; scroll.layer?.cornerRadius = WhalePanelStyle.radius
        table.backgroundColor = InformationPalette.surface
        table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 50; table.dataSource = self; table.delegate = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("逐跳 IP 和往返延迟")
        for (id, title, width) in [("hop", "跳数", 48.0), ("ip", "响应 IP", 355.0), ("rtt", "三次往返延迟 · ms", 345.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.minWidth = id == "hop" ? 44 : 220; table.addTableColumn(column)
        }
        scroll.documentView = table; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let footnote = WhalePanelStyle.label("* 未响应 · 延迟为本机到该跳的往返时间", size: 11, secondary: true)
        footnote.toolTip = "一次探测可能经过不同路径；悬停单元格可查看每次探测对应的 IP。"
        let stack = WhalePanelStyle.column([header, targetCard, settingsPanel, results, status, routeHeader, scroll, footnote], spacing: 14)
        WhalePanelStyle.pin(stack, in: root)
    }
    private var input: String { presets.indices.contains(targetPopup.indexOfSelectedItem) ? presets[targetPopup.indexOfSelectedItem] : address.stringValue }
    private func saveTarget() {
        store.targetIndex = targetPopup.indexOfSelectedItem; store.customAddress = address.stringValue; store.ipv6 = family.indexOfSelectedItem == 1
        if let mode = NetworkDiagnosticsStore.QuickMode(rawValue: testChoice.indexOfSelectedItem) { store.quickMode = mode }
    }
    @objc private func targetChanged() { saveTarget(); refresh() }
    @objc private func settingsChanged() {
        store.settings.maxHops = [15, 30, 45, 64][max(0, maxHops.indexOfSelectedItem)]
        store.settings.downloadMiB = [4, 16, 32][max(0, byteLimit.indexOfSelectedItem)]
        store.settings.downloadSeconds = [5, 10, 20][max(0, timeLimit.indexOfSelectedItem)]
    }
    @objc private func startSelection() {
        saveTarget()
        switch testChoice.indexOfSelectedItem {
        case 4: store.start(.latency, input: input, ipv6: store.ipv6)
        case 5: store.start(.route, input: input, ipv6: store.ipv6)
        default: store.startQuick()
        }
    }
    @objc private func toggleSettings() {
        settingsPanel.isHidden.toggle()
        settingsToggle.title = settingsPanel.isHidden ? "测试设置" : "收起设置"
    }
    @objc private func helpClicked() { Self.showHelp() }
    @objc private func stopTest() { store.cancel() }
    private func refresh() {
        if !store.isRunning {
            targetPopup.selectItem(at: store.targetIndex)
            if address.currentEditor() == nil { address.stringValue = store.customAddress }
            family.selectItem(at: store.ipv6 ? 1 : 0)
            maxHops.selectItem(at: [15, 30, 45, 64].firstIndex(of: store.settings.maxHops) ?? 1)
            byteLimit.selectItem(at: [4, 16, 32].firstIndex(of: store.settings.downloadMiB) ?? 1)
            timeLimit.selectItem(at: [5, 10, 20].firstIndex(of: store.settings.downloadSeconds) ?? 1)
        }
        let capacity = testChoice.indexOfSelectedItem == 3
        serviceNote.stringValue = capacity ? "Apple 测试服务 · 将产生网络流量" : "检测会产生网络流量"
        status.stringValue = store.status; status.isHidden = store.status == "准备就绪"
        results.update(store)
        routeSummary.stringValue = (store.routeTarget.map { $0 + " · " } ?? "") + store.trace.summary
        routeSummary.toolTip = routeSummary.stringValue + (store.trace.destinationIP.map { " · " + $0 } ?? "")
        table.reloadData()
        for popup in [targetPopup, testChoice, family, maxHops, byteLimit, timeLimit] { popup.isEnabled = !store.isRunning }
        targetPopup.isEnabled = !store.isRunning && !capacity
        address.isHidden = targetPopup.indexOfSelectedItem != presets.count || capacity
        address.isEnabled = !store.isRunning && !address.isHidden
        startButton.isEnabled = !store.isRunning; stopButton.isEnabled = store.isRunning
        startButton.isHidden = store.isRunning; stopButton.isHidden = !store.isRunning
        if store.isRunning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    func windowWillClose(_ notification: Notification) { if !store.quickRunning { store.cancel() } }
    func numberOfRows(in tableView: NSTableView) -> Int { store.trace.hops.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.trace.hops.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let hop = store.trace.hops[row]
        let value: String
        switch column {
        case "hop": value = String(hop.number)
        case "ip": value = hop.addresses.isEmpty ? "*" : hop.addresses.joined(separator: "\n")
        default: value = hop.probes.map { probe in
            guard let ms = probe.milliseconds else { return "*" }
            return String(format: "%.2f", ms) + (probe.annotation.map { " " + $0 } ?? "")
        }.joined(separator: "   /   ")
        }
        let label = NSTextField(wrappingLabelWithString: value)
        label.textColor = InformationPalette.ink
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular); label.maximumNumberOfLines = 3
        label.toolTip = hop.probes.map { ($0.ip ?? "*") + " · " + ($0.milliseconds.map { String(format: "%.3f ms", $0) } ?? "未响应") + ($0.annotation.map { " " + $0 } ?? "") }.joined(separator: "\n")
        return label
    }
}

@MainActor
final class NetworkQuickTestController: NSViewController {
    private static var instance: NetworkQuickTestController?
    private let popover = NSPopover()
    let store: NetworkDiagnosticsStore
    let target = NSPopUpButton()
    let address = NSTextField()
    let mode = NSPopUpButton()
    private let start = NSButton(title: "开始检测", target: nil, action: nil)
    private let stop = NSButton(title: "停止", target: nil, action: nil)
    private let status = WhalePanelStyle.label("", size: 11, secondary: true)
    private let note = WhalePanelStyle.label("检测会产生网络流量", size: 11, secondary: true)
    private let result = NetworkResultTiles(compact: true)
    private let spinner = NSProgressIndicator()
    static func show(relativeTo button: NSView, card: NSView? = nil) {
        if instance == nil { instance = NetworkQuickTestController(store: .shared) }
        guard let controller = instance else { return }
        if controller.popover.isShown { controller.popover.close(); return }
        controller.loadViewIfNeeded(); controller.refresh()
        controller.popover.contentViewController = controller
        controller.popover.behavior = .semitransient; controller.popover.animates = true
        let anchor = card ?? button
        var rect = button.convert(button.bounds, to: anchor)
        if card != nil { rect.origin.x = anchor.bounds.maxX - 1; rect.size.width = 1 }
        controller.popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxX)
        controller.popover.contentViewController?.view.window?.level = .statusBar
    }
    static func dismiss() { instance?.popover.close() }
    static var visibleWindow: NSWindow? { instance?.popover.isShown == true ? instance?.view.window : nil }
    init(store: NetworkDiagnosticsStore) { self.store = store; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 246))
        let title = WhalePanelStyle.label("网络测速", size: 15, weight: .semibold)
        let help = NSButton(title: "?", target: self, action: #selector(showHelp)); help.bezelStyle = .helpButton; help.setAccessibilityLabel("网络测试帮助")
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let header = WhalePanelStyle.row([title, NSView(), spinner, help])
        target.addItems(withTitles: ["Google", "GitHub", "百度", "哔哩哔哩", "自定义网址 / IP"])
        target.setAccessibilityLabel("快捷测速目标"); target.target = self; target.action = #selector(selectionChanged)
        mode.addItems(withTitles: NetworkDiagnosticsStore.QuickMode.allCases.map(\.title)); mode.setAccessibilityLabel("快捷测速项目")
        mode.target = self; mode.action = #selector(selectionChanged)
        func field(_ name: String, _ control: NSView) -> NSView {
            let label = WhalePanelStyle.label(name, secondary: true); label.widthAnchor.constraint(equalToConstant: 30).isActive = true
            return WhalePanelStyle.row([label, control], spacing: 10)
        }
        address.placeholderString = "网址、域名或 IP"; address.setAccessibilityLabel("快捷测速自定义地址")
        WhalePanelStyle.button(start, primary: true); WhalePanelStyle.button(stop)
        start.target = self; start.action = #selector(startTest); stop.target = self; stop.action = #selector(stopTest)
        let details = NSButton(title: "详情与设置", target: self, action: #selector(showDetails))
        details.isBordered = false; details.contentTintColor = WhalePanelStyle.accent; details.font = .systemFont(ofSize: 12)
        let actions = WhalePanelStyle.row([details, NSView(), start, stop])
        let stack = WhalePanelStyle.column([header, field("目标", target), address, field("项目", mode), result, status, note, actions], spacing: 12)
        WhalePanelStyle.pin(stack, in: view, inset: 16, bottom: false)
        store.onQuickChange = { [weak self] in self?.refresh() }
        refresh()
    }
    private func save() {
        store.targetIndex = target.indexOfSelectedItem; store.customAddress = address.stringValue
        store.quickMode = .init(rawValue: mode.indexOfSelectedItem) ?? .complete
    }
    @objc private func selectionChanged() { save(); refresh() }
    @objc private func startTest() { save(); store.startQuick() }
    @objc private func stopTest() { store.cancel() }
    @objc private func showHelp() { NetworkDiagnosticsWindow.showHelp() }
    @objc private func showDetails() { save(); popover.close(); NetworkDiagnosticsWindow.show() }
    func refresh() {
        guard isViewLoaded else { return }
        target.selectItem(at: store.targetIndex); mode.selectItem(at: store.quickMode.rawValue)
        if !store.isRunning, address.currentEditor() == nil { address.stringValue = store.customAddress }
        let capacity = store.quickMode == .capacity
        target.isEnabled = !store.isRunning && !capacity; mode.isEnabled = !store.isRunning
        address.isHidden = capacity || store.targetIndex != NetworkDiagnosticsStore.presets.count
        address.isEnabled = !store.isRunning && !address.isHidden
        start.isEnabled = !store.isRunning; stop.isEnabled = store.isRunning
        start.isHidden = store.isRunning; stop.isHidden = !store.isRunning
        status.stringValue = store.status; status.isHidden = store.status == "准备就绪"
        result.isHidden = !store.isRunning && store.lastSpeech == nil
        result.update(store)
        note.stringValue = capacity ? "Apple 服务 · 将产生网络流量" : "检测会产生网络流量"
        if store.isRunning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let size = NSSize(width: 320, height: 228 + (address.isHidden ? 0 : 36) + (result.isHidden ? 0 : 100) + (status.isHidden ? 0 : 28))
        preferredContentSize = size; view.setFrameSize(size); popover.contentSize = size
    }
}
