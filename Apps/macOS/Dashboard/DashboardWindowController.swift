import AppKit
import WhaleCore

@MainActor
protocol DashboardWindowControllerDelegate: AnyObject {
    func dashboardDidRequestActivityMonitor()
    func dashboardDidChangeQuietMode(_ enabled: Bool)
    func dashboardDidChangeNotifications(_ enabled: Bool)
    func dashboardDidChangeLaunchAtLogin(_ enabled: Bool)
}

@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    weak var dashboardDelegate: DashboardWindowControllerDelegate?
    private let cpuLabel = WhaleMetricTile("CPU")
    private let memoryLabel = WhaleMetricTile("内存")
    private let networkLabel = WhaleMetricTile("网络")
    private let batteryLabel = WhaleMetricTile("电池")
    private let sessionsStack = NSStackView()
    private let emptySessionsLabel = NSTextField(labelWithString: "暂无 Agent 事件")
    private let diagnosticsLabel = NSTextField(wrappingLabelWithString: "")
    private let quietButton = NSButton(checkboxWithTitle: "静音模式", target: nil, action: nil)
    private let notificationsButton = NSButton(checkboxWithTitle: "系统通知", target: nil, action: nil)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private var refreshTimer: Timer?
    var onRefresh: (() -> Void)?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 590),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "WhaleGirl Dashboard"
        panel.minSize = NSSize(width: 480, height: 480)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildUI(in: panel)
    }

    required init?(coder: NSCoder) { nil }

    func show(quietMode: Bool, notificationsEnabled: Bool) {
        quietButton.state = quietMode ? .on : .off
        notificationsButton.state = notificationsEnabled ? .on : .off
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onRefresh?() }
        }
        onRefresh?()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func update(
        metrics: SystemMetricsSnapshot,
        eventState: EventHubSnapshot,
        socketStatus: String,
        launchAtLoginStatus: String
    ) {
        cpuLabel.update(formatPercent(metrics.cpuPercent))
        memoryLabel.update(formatBytes(metrics.memoryUsedBytes), caption: "共 " + formatBytes(metrics.memoryTotalBytes))
        networkLabel.update("↓ " + formatRate(metrics.downloadBytesPerSecond), caption: "↑ " + formatRate(metrics.uploadBytesPerSecond))
        batteryLabel.update(metrics.batteryPercent.map { "\($0)%" } ?? "—", caption: metrics.batteryCharging == true ? "充电中" : "")
        renderSessions(eventState.sessions)
        diagnosticsLabel.stringValue = "事件连接：\(socketStatus)\n登录启动：\(launchAtLoginStatus)\n未识别事件：\(eventState.decodeFailureCount)"
    }

    func updateSettings(quietMode: Bool, notificationsEnabled: Bool, launchAtLogin: Bool) {
        quietButton.state = quietMode ? .on : .off
        notificationsButton.state = notificationsEnabled ? .on : .off
        launchAtLoginButton.state = launchAtLogin ? .on : .off
    }

    private func buildUI(in panel: NSPanel) {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        panel.contentView = scroll; WhalePanelStyle.surface(scroll)
        let document = DashboardDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let activity = NSButton(title: "活动监视器", target: self, action: #selector(openActivityMonitor))
        WhalePanelStyle.button(activity)
        let header = WhalePanelStyle.row([WhalePanelStyle.label("运行概览", size: 20, weight: .semibold), NSView(), activity])
        let first = WhalePanelStyle.row([cpuLabel, memoryLabel]); first.distribution = .fillEqually
        let second = WhalePanelStyle.row([networkLabel, batteryLabel]); second.distribution = .fillEqually
        sessionsStack.orientation = .vertical; sessionsStack.alignment = .leading; sessionsStack.spacing = 12
        emptySessionsLabel.font = .systemFont(ofSize: 12); emptySessionsLabel.textColor = InformationPalette.secondary
        sessionsStack.addArrangedSubview(emptySessionsLabel)
        quietButton.target = self; quietButton.action = #selector(toggleQuietMode)
        notificationsButton.target = self; notificationsButton.action = #selector(toggleNotifications)
        launchAtLoginButton.target = self; launchAtLoginButton.action = #selector(toggleLaunchAtLogin)
        for button in [quietButton, notificationsButton, launchAtLoginButton] { button.font = .systemFont(ofSize: 12) }
        let preferences = WhalePanelStyle.card(WhalePanelStyle.row([quietButton, notificationsButton, launchAtLoginButton, NSView()], spacing: 14))
        diagnosticsLabel.font = .systemFont(ofSize: 12); diagnosticsLabel.textColor = InformationPalette.secondary
        let diagnostic = NSButton(title: "连接详情", target: self, action: #selector(toggleDiagnostics(_:)))
        diagnostic.isBordered = false; diagnostic.contentTintColor = WhalePanelStyle.accent; diagnostic.font = .systemFont(ofSize: 12)
        diagnosticsLabel.isHidden = true
        let root = WhalePanelStyle.column([header, first, second, WhalePanelStyle.label("Agent 会话", size: 13, weight: .semibold), WhalePanelStyle.card(sessionsStack), preferences, diagnostic, diagnosticsLabel], spacing: 16)
        root.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: document.topAnchor, constant: 20), root.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
    }
    @objc private func toggleDiagnostics(_ sender: NSButton) {
        diagnosticsLabel.isHidden.toggle(); sender.title = diagnosticsLabel.isHidden ? "连接详情" : "收起详情"
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func renderSessions(_ sessions: [SessionSnapshot]) {
        for view in sessionsStack.arrangedSubviews {
            sessionsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !sessions.isEmpty else {
            sessionsStack.addArrangedSubview(emptySessionsLabel)
            return
        }
        for session in sessions.prefix(6) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fill
            row.spacing = 8
            let source = NSTextField(labelWithString: session.key.source.rawValue.uppercased())
            source.font = .systemFont(ofSize: 12, weight: .semibold)
            source.widthAnchor.constraint(equalToConstant: 54).isActive = true
            let project = NSTextField(labelWithString: session.projectKey ?? "未命名项目")
            project.lineBreakMode = .byTruncatingMiddle
            let status = NSTextField(labelWithString: statusText(session.status))
            status.textColor = session.needsAttention ? .systemOrange : .secondaryLabelColor
            status.alignment = .right
            row.addArrangedSubview(source)
            row.addArrangedSubview(project)
            row.addArrangedSubview(status)
            sessionsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sessionsStack.widthAnchor).isActive = true
        }
    }

    private func statusText(_ status: AgentSessionStatus) -> String {
        switch status {
        case .working: "工作中"
        case .waitingInput: "等待输入"
        case .waitingApproval: "等待授权"
        case .turnCompleted: "完成一轮回复"
        case .sessionCompleted: "会话已完成"
        case .failed: "失败"
        case .interrupted: "已中断"
        case .disconnected: "连接中断"
        }
    }

    private func formatPercent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f%%", value)
    }

    private func formatBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private func formatRate(_ value: Double?) -> String {
        guard let value else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s"
    }

    @objc private func openActivityMonitor() { dashboardDelegate?.dashboardDidRequestActivityMonitor() }
    @objc private func toggleQuietMode() { dashboardDelegate?.dashboardDidChangeQuietMode(quietButton.state == .on) }
    @objc private func toggleNotifications() { dashboardDelegate?.dashboardDidChangeNotifications(notificationsButton.state == .on) }
    @objc private func toggleLaunchAtLogin() { dashboardDelegate?.dashboardDidChangeLaunchAtLogin(launchAtLoginButton.state == .on) }
}

private final class DashboardDocumentView: NSView { override var isFlipped: Bool { true } }
