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
    private let cpuLabel = NSTextField(labelWithString: "CPU  --")
    private let memoryLabel = NSTextField(labelWithString: "内存  --")
    private let networkLabel = NSTextField(labelWithString: "网络  --")
    private let batteryLabel = NSTextField(labelWithString: "电池  --")
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
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 510),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "WhaleGirl Dashboard"
        panel.minSize = NSSize(width: 460, height: 420)
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
        cpuLabel.stringValue = "CPU  " + formatPercent(metrics.cpuPercent)
        memoryLabel.stringValue = "内存  \(formatBytes(metrics.memoryUsedBytes)) / \(formatBytes(metrics.memoryTotalBytes))"
        networkLabel.stringValue = "网络  ↓\(formatRate(metrics.downloadBytesPerSecond))  ↑\(formatRate(metrics.uploadBytesPerSecond))"
        if let percent = metrics.batteryPercent {
            batteryLabel.stringValue = "电池  \(percent)%" + (metrics.batteryCharging == true ? " · 充电中" : "")
        } else {
            batteryLabel.stringValue = "电池  此设备不支持"
        }
        renderSessions(eventState.sessions)
        diagnosticsLabel.stringValue = "本地事件入口：\(socketStatus)\nCodex 审批监控：暂不可用（尚未安装并实测 Hook）\nDSH 审批监控：暂不可用（尚无已核实事件源）\n登录项：\(launchAtLoginStatus) · 拒绝的事件：\(eventState.decodeFailureCount)"
    }

    func updateSettings(quietMode: Bool, notificationsEnabled: Bool, launchAtLogin: Bool) {
        quietButton.state = quietMode ? .on : .off
        notificationsButton.state = notificationsEnabled ? .on : .off
        launchAtLoginButton.state = launchAtLogin ? .on : .off
    }

    private func buildUI(in panel: NSPanel) {
        guard let content = panel.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])

        let title = NSTextField(labelWithString: "今日概览")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        root.addArrangedSubview(title)

        let metrics = NSStackView(views: [cpuLabel, memoryLabel, networkLabel, batteryLabel])
        metrics.orientation = .horizontal
        metrics.distribution = .fillEqually
        metrics.spacing = 10
        for label in [cpuLabel, memoryLabel, networkLabel, batteryLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
        }
        root.addArrangedSubview(metrics)
        metrics.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let metricsSeparator = separator()
        root.addArrangedSubview(metricsSeparator)
        metricsSeparator.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let agentTitle = NSTextField(labelWithString: "Agents")
        agentTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        root.addArrangedSubview(agentTitle)
        sessionsStack.orientation = .vertical
        sessionsStack.alignment = .leading
        sessionsStack.spacing = 8
        emptySessionsLabel.textColor = .secondaryLabelColor
        sessionsStack.addArrangedSubview(emptySessionsLabel)
        root.addArrangedSubview(sessionsStack)
        sessionsStack.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let agentSeparator = separator()
        root.addArrangedSubview(agentSeparator)
        agentSeparator.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let diagnosticTitle = NSTextField(labelWithString: "连接与诊断")
        diagnosticTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        root.addArrangedSubview(diagnosticTitle)
        diagnosticsLabel.textColor = .secondaryLabelColor
        diagnosticsLabel.font = .systemFont(ofSize: 12)
        diagnosticsLabel.maximumNumberOfLines = 5
        root.addArrangedSubview(diagnosticsLabel)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 14
        let activity = NSButton(title: "打开活动监视器", target: self, action: #selector(openActivityMonitor))
        quietButton.target = self
        quietButton.action = #selector(toggleQuietMode)
        notificationsButton.target = self
        notificationsButton.action = #selector(toggleNotifications)
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(toggleLaunchAtLogin)
        actions.addArrangedSubview(activity)
        actions.addArrangedSubview(quietButton)
        actions.addArrangedSubview(notificationsButton)
        actions.addArrangedSubview(launchAtLoginButton)
        root.addArrangedSubview(actions)
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
