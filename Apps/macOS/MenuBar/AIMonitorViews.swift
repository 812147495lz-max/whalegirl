import AppKit
import WhaleCore

@MainActor
final class AIQuotaSectionView: NSView {
    private let store: AIMonitorStore
    private let scroll = NSScrollView()
    private let rows = NSStackView()
    init(store: AIMonitorStore) {
        self.store = store
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "AI 余量")
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.textColor = InformationPalette.ink
        let settings = NSButton(title: "管理", target: self, action: #selector(showSettings))
        settings.bezelStyle = .inline; settings.font = .systemFont(ofSize: 10); settings.contentTintColor = InformationPalette.blue; settings.toolTip = "选择显示的 AI 工具"
        settings.attributedTitle = NSAttributedString(string: "管理", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: InformationPalette.blue])
        let header = NSStackView(views: [title, NSView(), settings])
        header.orientation = .horizontal
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false
        let document = AIListDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows); scroll.documentView = document
        for view in [header, scroll] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor), rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -5),
            rows.topAnchor.constraint(equalTo: document.topAnchor), rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        reload()
    }
    required init?(coder: NSCoder) { nil }
    @objc private func showSettings() { store.showSettings() }
    static func summary(_ value: AIQuotaReading, now: Date = Date()) -> String {
        guard value.state == "ready", value.isValid else { return "周 —  ·  小时 —" }
        let windows = value.windows.map { window in
            window.periodTitle + " " + String(format: "%.0f%%", window.remainingPercent)
                + (window.bucket.map { " (\($0))" } ?? "")
        }
        if !windows.isEmpty { return windows.joined(separator: "  ·  ") }
        if !value.balances.isEmpty {
            return value.balances.map { balance in
                let decimal = NSDecimalNumber(string: balance.amount, locale: Locale(identifier: "en_US_POSIX"))
                let formatter = NumberFormatter(); formatter.numberStyle = .decimal
                formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 4
                let prefix = balance.currency == "CNY" ? "¥" : balance.currency == "USD" ? "$" : balance.currency + " "
                return "余额 " + prefix + (formatter.string(from: decimal) ?? balance.amount)
            }.joined(separator: "  ")
        }
        return "周 —  ·  小时 —"
    }
    func reload() {
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        for provider in store.visibleProviders {
            let value = store.reading(for: provider)
            let name = NSTextField(labelWithString: provider.name)
            name.font = .systemFont(ofSize: 11, weight: .semibold)
            name.textColor = InformationPalette.ink
            name.lineBreakMode = .byTruncatingTail
            name.toolTip = provider.name
            let ready = value.state == "ready" && value.isValid
            let status = NSTextField(labelWithString: ready ? "剩余" : value.statusTitle)
            status.font = .systemFont(ofSize: 10)
            status.textColor = InformationPalette.secondary
            status.setContentCompressionResistancePriority(.required, for: .horizontal)
            let heading = NSStackView(views: [name, NSView(), status])
            heading.orientation = .horizontal
            let row = NSStackView(views: [heading])
            row.orientation = .vertical; row.alignment = .leading; row.spacing = 5
            if ready && !value.windows.isEmpty {
                // Preserve every bucket, including providers with more than two quota periods.
                for offset in stride(from: 0, to: value.windows.count, by: 2) {
                    let pair = NSStackView(); pair.orientation = .horizontal
                    pair.distribution = .fillEqually; pair.spacing = 8
                    for window in value.windows[offset..<min(offset + 2, value.windows.count)] {
                        let number = NSTextField(labelWithString: String(format: "%.0f%%", window.remainingPercent))
                        number.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
                        number.textColor = value.isStale(at: Date()) ? InformationPalette.secondary : (window.remainingPercent <= 10 ? InformationPalette.warning : InformationPalette.blue)
                        let period = NSTextField(labelWithString: window.periodTitle + (window.bucket.map { " · " + $0 } ?? ""))
                        period.font = .systemFont(ofSize: 10); period.textColor = InformationPalette.secondary
                        period.lineBreakMode = .byTruncatingTail
                        period.toolTip = period.stringValue
                        if let reset = window.resetsAt {
                            period.toolTip = period.stringValue + " · " + reset.formatted() + " 恢复"
                        }
                        let column = NSStackView(views: [number, period])
                        column.orientation = .vertical; column.alignment = .leading; column.spacing = 1
                        pair.addArrangedSubview(column)
                        period.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
                    }
                    if pair.arrangedSubviews.count == 1 { pair.addArrangedSubview(NSView()) }
                    row.addArrangedSubview(pair)
                    pair.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
                }
            }
            if ready && (!value.balances.isEmpty || value.windows.isEmpty) {
                // Some providers supply both balances and quota windows; retain both.
                var balances = value; balances.windows = []
                let detail = NSTextField(wrappingLabelWithString: value.balances.isEmpty ? "暂无可用额度" : Self.summary(balances))
                detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
                detail.textColor = InformationPalette.blue
                row.addArrangedSubview(detail)
                detail.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            }
            let noteText: String
            if ready {
                if value.isStale(at: Date()) { noteText = "上次数据 · 已过期" }
                else {
                    let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
                    noteText = formatter.string(from: value.fetchedAt) + " 更新"
                }
            } else {
                switch value.state {
                case "signInRequired": noteText = "登录后自动更新"
                case "notInstalled": noteText = "安装并登录后可读取"
                case "unsupported": noteText = "此工具未开放额度数据"
                case "awaitingConnection": noteText = "连接后显示实际额度"
                case "authenticationFailed": noteText = "软件中更新登录或密钥后重试"
                case "accessibilityRequired": noteText = "管理中授权读取软件用量页面"
                case "usageViewRequired": noteText = "软件设置 → 用量，打开后刷新"
                case "appNotRunning": noteText = "打开软件后刷新"
                case "nativeUnavailable": noteText = "用量页面未暴露可读取的数字"
                case "browserConnectionRequired": noteText = "管理中连接对应浏览器会话"
                default: noteText = "暂未取得数据 · 稍后重试"
                }
            }
            let note = NSTextField(labelWithString: noteText)
            note.font = .systemFont(ofSize: 10); note.textColor = InformationPalette.secondary
            row.addArrangedSubview(note)
            if let activity = store.activityTitle(provider.id) {
                let label = NSTextField(labelWithString: activity)
                label.font = .systemFont(ofSize: 10); label.textColor = InformationPalette.secondary
                row.addArrangedSubview(label)
            }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            heading.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            if provider.id != store.visibleProviders.last?.id {
                let separator = NSBox(); separator.boxType = .separator
                rows.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }
    }
}

@MainActor
final class AIMonitorSettingsWindow: NSWindowController {
    private let store: AIMonitorStore
    private let stack = NSStackView()
    private var observation: AIMonitorObservation?
    init(store: AIMonitorStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 570),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AI 额度与鲸鱼娘"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        window.contentView = scroll
        let document = AIListDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack); scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        observation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: AIMonitorStore.changed,
            object: store, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } })
        reload(); window.center()
    }
    required init?(coder: NSCoder) { nil }
    private func check(_ title: String, state: Bool, action: Selector, id: String? = nil) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = state ? .on : .off; button.identifier = id.map { NSUserInterfaceItemIdentifier($0) }
        return button
    }
    private func reload() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        stack.addArrangedSubview(check("显示 AI 剩余额度", state: store.preferences.showQuotas, action: #selector(toggleQuotas(_:))))
        stack.addArrangedSubview(check("按子 Agent 数量自动生成鲸鱼娘", state: store.preferences.autoAgentPets, action: #selector(togglePets(_:))))
        let help = NSTextField(wrappingLabelWithString: "子 Agent 出生报到，2秒后开始动作；结束后10–20秒挥手离开。Gemini与Grok Bot使用桌面软件用量页面；OpenCode Go使用本机密钥。额度和回复通知分别接入，不以余额变化判断完成。")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        stack.addArrangedSubview(help); help.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let all = NSButton(title: "全部显示", target: self, action: #selector(selectAllProviders))
        let none = NSButton(title: "全部隐藏", target: self, action: #selector(selectNone))
        let buttons = NSStackView(views: [all, none]); buttons.orientation = .horizontal; stack.addArrangedSubview(buttons)
        for provider in store.preferences.providers {
            let button = check(provider.name + " · " + store.reading(for: provider).statusTitle,
                state: provider.enabled, action: #selector(toggleProvider(_:)), id: provider.id)
            if provider.adapter == "nativeApp" {
                let open = NSButton(title: "打开软件", target: self, action: #selector(openNativeApp(_:)))
                open.identifier = NSUserInterfaceItemIdentifier(provider.id)
                stack.addArrangedSubview(NSStackView(views: [button, open]))
            } else if provider.adapter == "codexbar" && provider.backendProvider != "claude" && !["gemini-cli", "grok-cli"].contains(provider.id) {
                let connect = NSButton(title: store.connectingProvider == provider.id ? "连接中…" : "连接浏览器", target: self, action: #selector(connectBrowser(_:)))
                connect.identifier = NSUserInterfaceItemIdentifier(provider.id)
                connect.isEnabled = store.connectingProvider == nil
                connect.toolTip = "读取本机浏览器登录信息，可能出现 macOS 钥匙串授权提示。"
                stack.addArrangedSubview(NSStackView(views: [button, connect]))
            } else { stack.addArrangedSubview(button) }
            var explanation = AIMonitorStore.integrationDescription(provider)
            if let activity = store.activityTitle(provider.id) { explanation += "\n" + activity }
            let detail = NSTextField(wrappingLabelWithString: explanation)
            detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
            stack.addArrangedSubview(detail); detail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let native = NSButton(title: "授权读取软件用量页面…", target: self, action: #selector(authorizeNative))
        let events = NSButton(title: store.installingEventBridges ? "配置中…" : "安装／修复官方事件接入", target: self, action: #selector(installEvents))
        events.isEnabled = !store.installingEventBridges
        stack.addArrangedSubview(native); stack.addArrangedSubview(events)
        if let message = store.bridgeInstallationMessage {
            let line = NSTextField(wrappingLabelWithString: message); stack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let add = NSButton(title: "添加其他 AI 工具…", target: self, action: #selector(addProvider))
        let refresh = NSButton(title: "立即刷新", target: self, action: #selector(refreshNow))
        let files = NSButton(title: "打开额度数据文件夹", target: self, action: #selector(openFiles))
        let guide = NSButton(title: "查看各软件接入说明", target: self, action: #selector(openGuide))
        stack.addArrangedSubview(NSStackView(views: [add, refresh]))
        stack.addArrangedSubview(files)
        stack.addArrangedSubview(guide)
        if store.configurationError { stack.addArrangedSubview(NSTextField(labelWithString: "设置文件无法读取或保存，请检查文件格式与权限。")) }
    }
    @objc private func toggleQuotas(_ sender: NSButton) { store.setShowQuotas(sender.state == .on) }
    @objc private func togglePets(_ sender: NSButton) { store.setAutoAgentPets(sender.state == .on) }
    @objc private func toggleProvider(_ sender: NSButton) { if let id = sender.identifier?.rawValue { store.setProvider(id, enabled: sender.state == .on) } }
    @objc private func selectAllProviders() { store.setAllProviders(true) }
    @objc private func selectNone() { store.setAllProviders(false) }
    @objc private func connectBrowser(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { store.connectBrowser(id) }
    }
    @objc private func refreshNow() { store.refresh(force: true) }
    @objc private func authorizeNative() {
        let alert = NSAlert(); alert.messageText = "读取桌面软件的用量页面"
        alert.informativeText = "使用macOS辅助功能授权，只读取Gemini或Grok Bot明确命名的用量窗口。不读取聊天、不自动切换页面，也不获取账号密钥。授权后请在软件设置打开“用量限额”或“Usage & Billing”，再点立即刷新。Grok Bot若未暴露可访问界面，会显示不可读取。"
        alert.addButton(withTitle: "前往授权"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { store.authorizeNativeReading() }
    }
    @objc private func installEvents() { store.installEventBridges() }
    @objc private func openNativeApp(_ sender: NSButton) { if let id = sender.identifier?.rawValue { store.openNativeApp(id) } }
    @objc private func openFiles() { store.prepareFiles(); NSWorkspace.shared.open(store.directory) }
    @objc private func openGuide() {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AIMonitor/接入说明.md") { NSWorkspace.shared.open(url) }
    }
    @objc private func addProvider() {
        let alert = NSAlert(); alert.messageText = "添加 AI 工具"; alert.informativeText = "输入 CodexBar 支持的服务标识（如 antigravity、windsurf、zai），即可读取本机账号。留空则使用自定义快照。"
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); name.placeholderString = "工具名称"
        let backend = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); backend.placeholderString = "服务标识，可留空"
        let fields = NSStackView(views: [name, backend]); fields.orientation = .vertical
        fields.frame = NSRect(x: 0, y: 0, width: 280, height: 56)
        alert.accessoryView = fields; alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { let key = backend.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key.isEmpty || (key.range(of: #"^[a-z0-9-]{1,60}$"#, options: .regularExpression) != nil && !["all", "both"].contains(key)) else { NSSound.beep(); return }
            store.addProvider(name: name.stringValue, backendProvider: key.isEmpty ? nil : key) }
    }
}

@MainActor
private final class AIListDocumentView: NSView { override var isFlipped: Bool { true } }

@MainActor
final class SystemMetricSettingsWindow: NSWindowController {
    private static var current: SystemMetricSettingsWindow?
    private var observation: AIMonitorObservation?
    private var buttons: [SystemMetric: NSButton] = [:]
    static func show() {
        if current == nil { current = SystemMetricSettingsWindow() }
        current?.showWindow(nil); current?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 390),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "选择电脑信息"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let title = NSTextField(labelWithString: "让你关心的数据留在眼前")
        title.font = .systemFont(ofSize: 15, weight: .semibold); stack.addArrangedSubview(title)
        let subtitle = NSTextField(labelWithString: "按需显示，修改后即时生效")
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)
        for offset in stride(from: 0, to: SystemMetric.allCases.count, by: 2) {
            let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 8
            for metric in SystemMetric.allCases[offset..<min(offset + 2, SystemMetric.allCases.count)] {
                let button = NSButton(checkboxWithTitle: metric.title, target: self, action: #selector(toggle(_:)))
                button.font = .systemFont(ofSize: 12)
                button.identifier = NSUserInterfaceItemIdentifier(metric.rawValue)
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
                buttons[metric] = button; row.addArrangedSubview(button)
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let all = NSButton(title: "全部显示", target: self, action: #selector(selectAllMetrics))
        let none = NSButton(title: "全部隐藏", target: self, action: #selector(selectNone))
        stack.addArrangedSubview(NSStackView(views: [all, none]))
        let help = NSTextField(wrappingLabelWithString: "保存后立即生效。GPU 与温度取决于硬件支持；台式机通常没有内置电池。无法读取时显示原因，不估算数值。")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        stack.addArrangedSubview(help)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView(); window.contentView = view; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        observation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: SystemMetricPreferences.changed,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } })
        reload(); window.center()
    }
    required init?(coder: NSCoder) { nil }
    private func reload() { for (metric, button) in buttons { button.state = SystemMetricPreferences.shared.enabled.contains(metric) ? .on : .off } }
    @objc private func toggle(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let metric = SystemMetric(rawValue: key) else { return }
        SystemMetricPreferences.shared.set(metric, enabled: sender.state == .on)
    }
    @objc private func selectAllMetrics() { SystemMetricPreferences.shared.setAll(true) }
    @objc private func selectNone() { SystemMetricPreferences.shared.setAll(false) }
}
