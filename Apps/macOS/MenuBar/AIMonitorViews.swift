import AppKit
import WhaleCore

/// No permanent scrollbar gutter; show a scroll indicator only for actual vertical overflow.
@MainActor
final class ContentOverflowScrollView: NSScrollView {
    private var updatingOverflow = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = false; hasHorizontalScroller = false
        scrollerStyle = .overlay; autohidesScrollers = true
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        guard !updatingOverflow, let documentView else { return }
        updatingOverflow = true
        defer { updatingOverflow = false }
        documentView.layoutSubtreeIfNeeded()
        let overflow = ceil(documentView.fittingSize.height) > floor(contentView.bounds.height) + 1
        if hasVerticalScroller != overflow { hasVerticalScroller = overflow }
    }
}

/// Miniature remaining-quota rings: inner/hour above, outer/week below.
@MainActor
private final class AIQuotaRingView: NSView {
    private let reading: AIQuotaReading
    private let isBalance: Bool
    private let maximum: Double
    static func windows(_ reading: AIQuotaReading) -> (hour: AIQuotaWindow?, week: AIQuotaWindow?) {
        (reading.windows.filter { (3600..<86400).contains($0.durationSeconds) }.min { $0.durationSeconds < $1.durationSeconds },
         reading.windows.first { $0.durationSeconds == 604800 })
    }
    static func supports(_ provider: AIQuotaProvider, reading: AIQuotaReading) -> Bool {
        let windows = windows(reading)
        return provider.id == "dsh" || ["codex", "claudecc"].contains(provider.id) || windows.hour != nil || windows.week != nil
    }
    static func cnyText(_ reading: AIQuotaReading) -> String? {
        guard let balance = reading.balances.first(where: { $0.currency == "CNY" }) else { return nil }
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 4
        return formatter.string(from: NSDecimalNumber(string: balance.amount, locale: Locale(identifier: "en_US_POSIX")))
    }
    static func fitsBalance(_ text: String) -> Bool { (text as NSString).size(withAttributes: [.font: InformationDataStyle.font]).width <= 49 }
    init(provider: AIQuotaProvider, reading: AIQuotaReading, maximum: Double) {
        self.reading = reading; self.isBalance = provider.id == "dsh"; self.maximum = maximum
        super.init(frame: .zero)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 64), heightAnchor.constraint(equalToConstant: 62)])
        let description = isBalance ? "DSH 剩余额度，人民币满量程 " + maximum.formatted() + " 元"
            : "内圈与上方数字：小时剩余额度；外圈与下方数字：周剩余额度。"
        toolTip = description + "\n" + AIQuotaSectionView.compactSummary(reading)
        setAccessibilityRole(.image); setAccessibilityLabel(description)
        setAccessibilityValue(AIQuotaSectionView.compactSummary(reading))
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: 30)
        let usable = reading.state == "ready" && reading.isValid && !reading.isStale(at: Date())
        let windows = Self.windows(reading)
        func ring(radius: CGFloat, value: Double?, color: NSColor) {
            let base = NSBezierPath(); base.appendArc(withCenter: center, radius: radius, startAngle: 225, endAngle: -45, clockwise: true)
            base.lineWidth = 4.5; base.lineCapStyle = .round
            InformationPalette.border.withAlphaComponent(0.5).setStroke(); base.stroke()
            guard let value, value > 0 else { return }
            let progress = NSBezierPath()
            progress.appendArc(withCenter: center, radius: radius, startAngle: 225, endAngle: 225 - CGFloat(270 * min(1, max(0, value))), clockwise: true)
            progress.lineWidth = 4.5; progress.lineCapStyle = .round; color.setStroke(); progress.stroke()
        }
        func text(_ value: String, y: CGFloat, color: NSColor) {
            let attrs: [NSAttributedString.Key: Any] = [.font: InformationDataStyle.font, .foregroundColor: color]
            let width = (value as NSString).size(withAttributes: attrs).width
            (value as NSString).draw(at: NSPoint(x: bounds.midX - width / 2, y: y), withAttributes: attrs)
        }
        if isBalance {
            let amount = usable ? reading.balances.first { $0.currency == "CNY" }.flatMap { Double($0.amount) }.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } : nil
            let fraction = amount.map { $0 / maximum }
            let color = fraction.map { $0 <= 0.2 ? InformationPalette.warning : InformationPalette.blue } ?? InformationPalette.secondary
            ring(radius: 28, value: fraction, color: color)
            let label = amount == nil ? "—" : Self.cnyText(reading) ?? "—"
            text(Self.fitsBalance(label) ? label : "余额", y: 26, color: color)
            if amount != nil { text("元", y: 12, color: InformationPalette.secondary) }
        } else {
            let hour = usable ? windows.hour?.remainingPercent : nil
            let week = usable ? windows.week?.remainingPercent : nil
            let hourColor = (hour ?? 100) <= 10 ? InformationPalette.warning : InformationPalette.blue
            let weekColor = (week ?? 100) <= 10 ? InformationPalette.warning : InformationPalette.teal
            ring(radius: 28, value: week.map { $0 / 100 }, color: weekColor)
            ring(radius: 21, value: hour.map { $0 / 100 }, color: hourColor)
            text(hour.map { String(format: "%.0f%%", $0) } ?? "—", y: 29, color: hour == nil ? InformationPalette.secondary : hourColor)
            text(week.map { String(format: "%.0f%%", $0) } ?? "—", y: 14, color: week == nil ? InformationPalette.secondary : weekColor)
        }
    }
}

@MainActor
final class AIQuotaSectionView: NSView {
    private let store: AIMonitorStore
    private let rows = NSStackView()
    private var lastCountdownRefresh = Date.distantPast
    init(store: AIMonitorStore) {
        self.store = store
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "AI 余量")
        title.font = .systemFont(ofSize: 12, weight: .semibold); title.textColor = InformationPalette.ink
        let settings = NSButton(title: "管理", target: self, action: #selector(showSettings))
        settings.bezelStyle = .inline; settings.font = .systemFont(ofSize: 10); settings.contentTintColor = InformationPalette.blue; settings.toolTip = "选择显示的 AI 工具"
        settings.attributedTitle = NSAttributedString(string: "管理", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: InformationPalette.blue])
        let header = NSStackView(views: [title, NSView(), settings])
        header.spacing = 6
        header.orientation = .horizontal
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 3
        for view in [header, rows] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 22),
            rows.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor), rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor)
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
    static func compactSummary(_ value: AIQuotaReading, now: Date = Date()) -> String {
        guard value.state == "ready", value.isValid else { return value.statusTitle }
        var parts: [String] = []
        for window in value.windows {
            parts.append(window.periodTitle + (window.bucket.map { " · " + $0 } ?? "") + String(format: " %.0f%%", window.remainingPercent) + (window.resetsAt == nil ? "" : " · " + window.resetDescription(at: now)))
        }
        if !value.balances.isEmpty {
            var balance = value; balance.windows = []
            parts.append(summary(balance).replacingOccurrences(of: "余额 ", with: ""))
        }
        if let cost = value.dshCostStatus, cost.isValid, let next = cost.nextSwitchAt,
           next > now, ["peak", "offPeak"].contains(cost.pricePhase) {
            parts.append((cost.pricePhase == "peak" ? "峰价" : "谷价") + " · 还有"
                + QuotaTimeText.remaining(until: next, now: now) + (cost.pricePhase == "peak" ? "转谷" : "转峰"))
        }
        if parts.isEmpty { parts.append("暂无额度") }
        if value.isStale(at: now) { parts.append("已过期") }
        return parts.joined(separator: "\n")
    }
    private static func shortCountdown(_ date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite, interval < Double(Int.max / 2) else { return "—" }
        guard interval > 0 else { return "待更新" }
        let seconds = Int(interval), days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return "\(days)天\(hours)时" }
        if hours > 0 { return "\(hours)时\(minutes)分" }
        if minutes > 0 { return "\(minutes)分" }
        return "\(max(1, seconds))秒"
    }
    private static func tileDetails(_ provider: AIQuotaProvider, reading: AIQuotaReading, now: Date = Date()) -> String {
        guard reading.state == "ready", reading.isValid else { return reading.statusTitle }
        guard !reading.isStale(at: now) else { return "已过期" }
        guard AIQuotaRingView.supports(provider, reading: reading) else { return compactSummary(reading, now: now) }
        var lines: [String] = []
        if provider.id == "dsh" {
            if let amount = AIQuotaRingView.cnyText(reading) {
                if !AIQuotaRingView.fitsBalance(amount) { lines.append("¥" + amount) }
            } else if !reading.balances.isEmpty {
                lines.append(summary(reading))
            }
            if let cost = reading.dshCostStatus, cost.isValid, let next = cost.nextSwitchAt,
               ["peak", "offPeak"].contains(cost.pricePhase) {
                lines.append(cost.pricePhase == "peak" ? "峰价 → 谷价" : "谷价 → 峰价")
                lines.append(shortCountdown(next, now: now))
            }
        } else {
            let windows = AIQuotaRingView.windows(reading)
            if let reset = windows.week?.resetsAt { lines.append("周重置 " + shortCountdown(reset, now: now)) }
            if let reset = windows.hour?.resetsAt { lines.append("小时重置 " + shortCountdown(reset, now: now)) }
            // Do not hide extra buckets or other quota units not represented by the two rings.
            var extra = reading
            extra.windows = reading.windows.filter { $0 != windows.hour && $0 != windows.week }
            if !extra.windows.isEmpty || !extra.balances.isEmpty { lines.append(compactSummary(extra, now: now)) }
        }
        return lines.joined(separator: "\n")
    }
    private static func measuredHeight(_ text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: InformationDataStyle.font]).height)
    }
    static func preferredHeight(store: AIMonitorStore) -> CGFloat {
        let providers = store.visibleProviders
        guard !providers.isEmpty else { return 0 }
        if store.quotaGaugesEnabled {
            let heights = providers.map { provider -> CGFloat in
                let reading = store.reading(for: provider)
                let details = measuredHeight(tileDetails(provider, reading: reading), width: 110)
                let ring: CGFloat = AIQuotaRingView.supports(provider, reading: reading) ? 64 : 0
                return 14 + ring + (details > 0 ? 2 + details : 0)
            }
            return 24 + stride(from: 0, to: heights.count, by: 2).reduce(CGFloat.zero) { height, index in
                height + max(heights[index], index + 1 < heights.count ? heights[index + 1] : 0) + 6
            }
        }
        return 24 + providers.reduce(CGFloat.zero) { height, provider in
            height + max(20, measuredHeight(compactSummary(store.reading(for: provider)), width: 168) + 4) + 3
        }
    }
    @discardableResult
    func refreshCountdownIfNeeded() -> Bool {
        guard Date().timeIntervalSince(lastCountdownRefresh) >= 30 else { return false }
        reload(); return true
    }
    private func providerNotes(_ provider: AIQuotaProvider, value: AIQuotaReading) -> String {
        var notes = [provider.displayName, value.statusTitle, value.fetchedAt.formatted() + " 更新", Self.compactSummary(value)]
        for window in value.windows {
            if let reset = window.resetsAt { notes.append(window.periodTitle + " · " + reset.formatted() + " 重置") }
        }
        if let activity = store.activityTitle(provider.id) { notes.append(activity) }
        notes.append(AIMonitorStore.integrationDescription(provider))
        return notes.joined(separator: "\n")
    }
    private func tile(_ provider: AIQuotaProvider) -> NSView {
        let value = store.reading(for: provider)
        let name = NSTextField(labelWithString: provider.displayName)
        name.font = .systemFont(ofSize: 10, weight: .medium); name.textColor = InformationPalette.ink
        name.lineBreakMode = .byTruncatingTail; name.alignment = .center
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tile = NSStackView(views: [name]); tile.orientation = .vertical; tile.alignment = .centerX; tile.spacing = 2
        name.widthAnchor.constraint(equalTo: tile.widthAnchor).isActive = true
        name.heightAnchor.constraint(equalToConstant: 14).isActive = true
        if AIQuotaRingView.supports(provider, reading: value) {
            tile.addArrangedSubview(AIQuotaRingView(provider: provider, reading: value, maximum: store.dshGaugeMaximum))
        }
        let text = Self.tileDetails(provider, reading: value)
        if !text.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: text)
            detail.font = InformationDataStyle.font; detail.alignment = .center
            detail.textColor = value.state != "ready" || value.isStale(at: Date()) ? InformationPalette.secondary : InformationPalette.blue
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            tile.addArrangedSubview(detail); detail.widthAnchor.constraint(equalTo: tile.widthAnchor).isActive = true
        }
        tile.toolTip = providerNotes(provider, value: value)
        return tile
    }
    func reload() {
        lastCountdownRefresh = Date()
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        rows.spacing = store.quotaGaugesEnabled ? 6 : 3
        let providers = store.visibleProviders
        if store.quotaGaugesEnabled {
            for index in stride(from: 0, to: providers.count, by: 2) {
                let second = index + 1 < providers.count ? tile(providers[index + 1]) : NSView()
                let pair = NSStackView(views: [tile(providers[index]), second])
                pair.orientation = .horizontal; pair.distribution = .fillEqually; pair.alignment = .top; pair.spacing = 8
                rows.addArrangedSubview(pair); pair.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        } else {
            for provider in providers {
                let value = store.reading(for: provider)
                let name = NSTextField(labelWithString: provider.displayName)
                name.font = .systemFont(ofSize: 10, weight: .medium); name.textColor = InformationPalette.ink
                name.lineBreakMode = .byTruncatingTail; name.widthAnchor.constraint(equalToConstant: 60).isActive = true
                let detail = NSTextField(wrappingLabelWithString: Self.compactSummary(value))
                detail.font = InformationDataStyle.font; detail.alignment = .right
                detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
                detail.textColor = value.state != "ready" || value.isStale(at: Date()) ? InformationPalette.secondary : InformationPalette.blue
                let row = NSView()
                for field in [name, detail] { field.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(field) }
                NSLayoutConstraint.activate([
                    name.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                    name.firstBaselineAnchor.constraint(equalTo: detail.firstBaselineAnchor),
                    detail.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
                    detail.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                    detail.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
                    detail.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2),
                    row.heightAnchor.constraint(greaterThanOrEqualToConstant: 20)
                ])
                row.toolTip = providerNotes(provider, value: value)
                rows.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }
        invalidateIntrinsicContentSize(); needsLayout = true
    }

}

@MainActor
final class AIMonitorSettingsWindow: NSWindowController, NSTextFieldDelegate {
    private let store: AIMonitorStore
    private let stack = NSStackView()
    private var integrationExpanded = false
    private var observation: AIMonitorObservation?
    init(store: AIMonitorStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AI 额度与鲸鱼娘"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 480)
        super.init(window: window)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        window.contentView = scroll
        WhalePanelStyle.surface(scroll)
        let document = AIListDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
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
        button.font = .systemFont(ofSize: 12)
        button.state = state ? .on : .off; button.identifier = id.map { NSUserInterfaceItemIdentifier($0) }
        return button
    }
    private func reload() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        func add(_ view: NSView) { stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        add(WhalePanelStyle.label("AI 与桌宠", size: 20, weight: .semibold))
        let quota = check("显示 AI 额度", state: store.preferences.showQuotas, action: #selector(toggleQuotas(_:)))
        let pets = check("Agent 桌宠", state: store.preferences.autoAgentPets, action: #selector(togglePets(_:)))
        pets.toolTip = "根据真实 Agent 工作事件自动生成桌宠，完成后自动离开。"
        let recovery = check("Codex 额度恢复提醒", state: store.recoveryNotificationsEnabled, action: #selector(toggleRecovery(_:)))
        recovery.toolTip = "独立监测 Codex 额度恢复，即使隐藏额度卡片也可提醒；只根据真实读数，不按时间猜测。"
        let gauges = check("显示额度仪表", state: store.quotaGaugesEnabled, action: #selector(toggleGauges(_:)))
        let maximum = NSTextField(string: store.dshGaugeMaximum.formatted(.number.precision(.fractionLength(0...2))))
        maximum.identifier = NSUserInterfaceItemIdentifier("dsh-gauge-maximum")
        maximum.font = InformationDataStyle.font
        maximum.alignment = .right; maximum.widthAnchor.constraint(equalToConstant: 90).isActive = true
        maximum.target = self; maximum.action = #selector(setGaugeMaximum(_:)); maximum.delegate = self
        maximum.toolTip = "人民币满量程，默认50元；0.01至1,000,000元"
        let limit = WhalePanelStyle.row([WhalePanelStyle.label("DSH 满量程", size: 12), NSView(), maximum, WhalePanelStyle.label("元", size: 12, secondary: true)])
        add(WhalePanelStyle.card(WhalePanelStyle.column([quota, gauges, limit, pets, recovery])))
        let all = NSButton(title: "全选", target: self, action: #selector(selectAllProviders))
        let none = NSButton(title: "清空", target: self, action: #selector(selectNone))
        for button in [all, none] { button.isBordered = false; button.font = .systemFont(ofSize: 11); button.contentTintColor = WhalePanelStyle.accent }
        add(WhalePanelStyle.row([WhalePanelStyle.label("显示的软件", size: 13, weight: .semibold), NSView(), all, none]))
        var providerViews: [NSView] = []
        for provider in store.preferences.providers {
            let reading = store.reading(for: provider)
            let button = check(provider.displayName, state: provider.enabled, action: #selector(toggleProvider(_:)), id: provider.id)
            button.toolTip = AIMonitorStore.integrationDescription(provider)
            let state = WhalePanelStyle.label(reading.statusTitle, size: 11, secondary: true)
            state.setContentCompressionResistancePriority(.required, for: .horizontal)
            var controls: [NSView] = [button, NSView(), state]
            if provider.adapter == "nativeApp" {
                let open = NSButton(title: "打开软件", target: self, action: #selector(openNativeApp(_:)))
                open.identifier = NSUserInterfaceItemIdentifier(provider.id); WhalePanelStyle.button(open); controls.append(open)
            } else if provider.adapter == "codexbar" && provider.backendProvider != "claude" && !["gemini-cli", "grok-cli"].contains(provider.id) {
                let connect = NSButton(title: store.connectingProvider == provider.id ? "连接中…" : "连接", target: self, action: #selector(connectBrowser(_:)))
                connect.identifier = NSUserInterfaceItemIdentifier(provider.id); connect.isEnabled = store.connectingProvider == nil
                connect.toolTip = "读取本机浏览器登录信息，可能出现钥匙串授权。"; WhalePanelStyle.button(connect); controls.append(connect)
            }
            let row = WhalePanelStyle.row(controls)
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
            providerViews.append(row)
            if let activity = store.activityTitle(provider.id) { providerViews.append(WhalePanelStyle.label(activity, size: 11, secondary: true)) }
        }
        add(WhalePanelStyle.card(WhalePanelStyle.column(providerViews, spacing: 10)))
        let integration = NSButton(title: integrationExpanded ? "收起接入设置" : "接入设置", target: self, action: #selector(toggleIntegration))
        integration.isBordered = false; integration.contentTintColor = WhalePanelStyle.accent; integration.font = .systemFont(ofSize: 12)
        add(integration)
        let native = NSButton(title: "授权读取软件用量页面…", target: self, action: #selector(authorizeNative))
        let events = NSButton(title: store.installingEventBridges ? "配置中…" : "安装／修复官方事件接入", target: self, action: #selector(installEvents))
        events.isEnabled = !store.installingEventBridges
        let files = NSButton(title: "打开额度数据文件夹", target: self, action: #selector(openFiles))
        for button in [native, events, files] { WhalePanelStyle.button(button) }
        let advanced = WhalePanelStyle.card(WhalePanelStyle.column([native, events, files], spacing: 10))
        advanced.isHidden = !integrationExpanded; add(advanced)
        if let message = store.bridgeInstallationMessage {
            let line = NSTextField(wrappingLabelWithString: message); line.font = .systemFont(ofSize: 12); add(line)
        }
        let addButton = NSButton(title: "添加工具", target: self, action: #selector(addProvider))
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshNow))
        let guide = NSButton(title: "接入说明", target: self, action: #selector(openGuide))
        for button in [addButton, refresh, guide] { WhalePanelStyle.button(button) }
        add(WhalePanelStyle.row([addButton, refresh, NSView(), guide]))
        if store.configurationError { add(WhalePanelStyle.label("设置无法保存，请检查文件权限", secondary: true)) }
    }
    @objc private func toggleGauges(_ sender: NSButton) { store.setQuotaGaugesEnabled(sender.state == .on) }
    @objc private func setGaugeMaximum(_ sender: NSTextField) {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        guard let number = formatter.number(from: sender.stringValue), number.doubleValue.isFinite,
              (0.01...1_000_000).contains(number.doubleValue) else {
            NSSound.beep(); sender.stringValue = store.dshGaugeMaximum.formatted(.number.precision(.fractionLength(0...2))); return
        }
        store.setDSHGaugeMaximum(number.doubleValue)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field.identifier?.rawValue == "dsh-gauge-maximum" { setGaugeMaximum(field) }
    }
    @objc private func toggleIntegration() { integrationExpanded.toggle(); reload() }
    @objc private func toggleRecovery(_ sender: NSButton) { store.setRecoveryNotifications(sender.state == .on) }
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
    private var chartButtons: [SystemMetric: NSButton] = [:]
    private let addressButton = NSButton(checkboxWithTitle: "显示出网 / 内网 IP", target: nil, action: nil)
    static func show() {
        if current == nil { current = SystemMetricSettingsWindow() }
        current?.showWindow(nil); current?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "选择电脑信息"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let title = WhalePanelStyle.label("电脑信息", size: 20, weight: .semibold)
        var rows: [NSView] = []
        for offset in stride(from: 0, to: SystemMetric.allCases.count, by: 2) {
            let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 12
            for metric in SystemMetric.allCases[offset..<min(offset + 2, SystemMetric.allCases.count)] {
                let button = NSButton(checkboxWithTitle: metric.title, target: self, action: #selector(toggle(_:)))
                button.font = .systemFont(ofSize: 12)
                button.identifier = NSUserInterfaceItemIdentifier(metric.rawValue)
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
                button.toolTip = "修改后立即生效；硬件不支持的项目会显示不可用。"
                buttons[metric] = button; row.addArrangedSubview(button)
            }
            rows.append(row)
        }
        let all = NSButton(title: "全部显示", target: self, action: #selector(selectAllMetrics))
        let none = NSButton(title: "全部隐藏", target: self, action: #selector(selectNone))
        for button in [all, none] { WhalePanelStyle.button(button) }
        var chartRows: [NSView] = []
        for offset in stride(from: 0, to: SystemMetricPreferences.chartMetrics.count, by: 2) {
            let metrics = SystemMetricPreferences.chartMetrics
            let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 12
            for metric in metrics[offset..<min(offset + 2, metrics.count)] {
                let button = NSButton(checkboxWithTitle: metric == .network ? "网络" : metric.title, target: self, action: #selector(toggleChart(_:)))
                button.font = .systemFont(ofSize: 12); button.identifier = .init(metric.rawValue)
                chartButtons[metric] = button; row.addArrangedSubview(button)
            }
            chartRows.append(row)
        }
        addressButton.target = self; addressButton.action = #selector(toggleAddresses(_:)); addressButton.font = .systemFont(ofSize: 12)
        let stack = WhalePanelStyle.column([title, WhalePanelStyle.label("显示项目", size: 13, weight: .semibold), WhalePanelStyle.card(WhalePanelStyle.column(rows)), WhalePanelStyle.row([all, none, NSView()]), WhalePanelStyle.label("折线图 · 最近5分钟", size: 13, weight: .semibold), WhalePanelStyle.card(WhalePanelStyle.column(chartRows)), WhalePanelStyle.card(addressButton)], spacing: 16)
        let view = NSView(); window.contentView = view; WhalePanelStyle.surface(view)
        WhalePanelStyle.pin(stack, in: view, bottom: false)
        observation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: SystemMetricPreferences.changed,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } })
        reload(); window.center()
    }
    required init?(coder: NSCoder) { nil }
    private func reload() {
        for (metric, button) in buttons { button.state = SystemMetricPreferences.shared.enabled.contains(metric) ? .on : .off }
        for (metric, button) in chartButtons { button.state = SystemMetricPreferences.shared.chartEnabled.contains(metric) ? .on : .off }
        addressButton.state = SystemMetricPreferences.shared.showAddresses ? .on : .off
    }
    @objc private func toggleChart(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let metric = SystemMetric(rawValue: key) else { return }
        SystemMetricPreferences.shared.setChart(metric, enabled: sender.state == .on)
    }
    @objc private func toggleAddresses(_ sender: NSButton) { SystemMetricPreferences.shared.setShowAddresses(sender.state == .on) }
    @objc private func toggle(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let metric = SystemMetric(rawValue: key) else { return }
        SystemMetricPreferences.shared.set(metric, enabled: sender.state == .on)
    }
    @objc private func selectAllMetrics() { SystemMetricPreferences.shared.setAll(true) }
    @objc private func selectNone() { SystemMetricPreferences.shared.setAll(false) }
}

/// Shared hierarchy for the information card, utility windows and quick panels.
@MainActor
enum WhalePanelStyle {
    static let gap: CGFloat = 12
    static let inset: CGFloat = 20
    static let accent = InformationPalette.blue
    static let background = InformationPalette.background
    static let radius: CGFloat = 14
    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? InformationPalette.secondary : InformationPalette.ink
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    static func button(_ button: NSButton, primary: Bool = false) {
        button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 12, weight: primary ? .semibold : .regular)
        if primary {
            button.bezelColor = accent; button.contentTintColor = .white
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
        }
    }
    static func surface(_ view: NSView) {
        view.wantsLayer = true; view.layer?.backgroundColor = background.cgColor
    }
    static func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = spacing
        return stack
    }
    static func card(_ content: NSView, inset: CGFloat = 14) -> NSView {
        let box = NSView(); box.wantsLayer = true
        box.layer?.backgroundColor = InformationPalette.surface.cgColor
        box.layer?.cornerRadius = radius
        box.layer?.borderWidth = 0.5; box.layer?.borderColor = InformationPalette.border.withAlphaComponent(0.55).cgColor
        content.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset)
        ])
        return box
    }
    static func pin(_ stack: NSView, in root: NSView, inset: CGFloat = 20, bottom: Bool = true) {
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            bottom ? stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset)
                   : stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -inset)
        ])
    }
}

@MainActor
final class WhaleMetricTile: NSView {
    private let title: NSTextField
    private let number = WhalePanelStyle.label("—", size: 23, weight: .semibold)
    private let caption = WhalePanelStyle.label("", size: 11, secondary: true)
    init(_ name: String, compact: Bool = false) {
        title = WhalePanelStyle.label(name, size: 11, weight: .medium, secondary: true)
        super.init(frame: .zero)
        number.font = .monospacedDigitSystemFont(ofSize: compact ? 18 : 23, weight: .semibold)
        number.textColor = WhalePanelStyle.accent
        caption.maximumNumberOfLines = 2; caption.cell?.usesSingleLineMode = false; caption.cell?.wraps = true
        let content = WhalePanelStyle.column([title, number, caption], spacing: 5)
        let card = WhalePanelStyle.card(content, inset: compact ? 10 : 14)
        card.translatesAutoresizingMaskIntoConstraints = false; addSubview(card)
        NSLayoutConstraint.activate([card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor), card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { nil }
    func update(_ value: String, caption text: String = "", title name: String? = nil) {
        if let name { title.stringValue = name }
        number.stringValue = value; caption.stringValue = text.isEmpty ? " " : text
        caption.toolTip = text; number.toolTip = value
        setAccessibilityLabel(title.stringValue + " " + value + " " + text)
    }
}
