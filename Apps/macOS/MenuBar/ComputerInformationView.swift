import AppKit
import WhaleCore

@MainActor
private final class FullWidthIPAddressField: NSTextField {
    override func layout() {
        super.layout()
        let base = InformationDataStyle.font
        let natural = (stringValue as NSString).size(withAttributes: [.font: base]).width
        guard bounds.width > 0, natural > 0 else { return }
        let size = min(11, 11 * max(1, bounds.width - 4) / natural)
        if abs((font?.pointSize ?? 0) - size) > 0.05 {
            font = .monospacedSystemFont(ofSize: size, weight: .medium)
        }
    }
}

@MainActor
final class ComputerInformationView: NSView {
    private let aiStore: AIMonitorStore?
    private(set) var networkTestButton: NSButton?
    private let preferences: SystemMetricPreferences
    private let content = NSStackView()
    private let scroll = ContentOverflowScrollView()
    private var fields: [SystemMetric: NSTextField] = [:]
    private var lastMetrics = SystemMetricsSnapshot.unavailable
    private var aiSection: AIQuotaSectionView?
    private var glassBackground: NSVisualEffectView?
    private var tintBackground: NSView?
    private var lastOpaqueFallback: Bool?
    private var addressObservation: AIMonitorObservation?
    private var metricsObservation: AIMonitorObservation?
    private var quotaObservation: AIMonitorObservation?
    private var publicAddressRows: NSStackView?
    private var publicAddressLabels: [NSTextField] = []
    private var displayedPublicAddresses: [String] = []
    private var addressRefreshButton: NSButton?
    private var internalAddressRows: NSStackView?
    private var displayedInternalAddresses: [String] = []
    private var addedChart = false

    override convenience init(frame: NSRect) { self.init(frame: frame, aiStore: nil) }

    init(frame: NSRect, aiStore: AIMonitorStore?, preferences: SystemMetricPreferences = .shared) {
        self.aiStore = aiStore; self.preferences = preferences
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 20; layer?.masksToBounds = true
        let glass = NSVisualEffectView(frame: bounds)
        glass.material = .popover; glass.blendingMode = .behindWindow; glass.state = .active
        glass.autoresizingMask = [.width, .height]; addSubview(glass); glassBackground = glass
        let tint = InformationGlassTint(frame: bounds)
        tint.autoresizingMask = [.width, .height]; addSubview(tint); tintBackground = tint
        let title = Self.label("运行概览", size: 14, weight: .semibold)
        let gear = NSButton(image: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "选择电脑信息") ?? NSImage(), target: self, action: #selector(showMetricSettings))
        gear.bezelStyle = .inline; gear.isBordered = false; gear.contentTintColor = InformationPalette.blue
        gear.toolTip = "自定义显示的电脑信息"
        let header = NSStackView(views: [title, NSView(), gear])
        header.orientation = .horizontal; header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false; addSubview(header)
        scroll.drawsBackground = false
        let document = InformationDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content)
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: 22),
            gear.widthAnchor.constraint(equalToConstant: 22), gear.heightAnchor.constraint(equalToConstant: 22),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4)
        ])
        metricsObservation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: SystemMetricPreferences.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadMetrics() }
        })
        if let aiStore {
            quotaObservation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: AIMonitorStore.changed, object: aiStore, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadAI() }
            })
        }
        addressObservation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: NetworkAddressStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAddresses() }
        })
        reloadMetrics()
        setAccessibilityLabel("电脑实时状态")
    }
    required init?(coder: NSCoder) { nil }
    @objc private func showMetricSettings() { SystemMetricSettingsWindow.show() }
    @objc private func showNetworkDiagnostics() { NetworkDiagnosticsWindow.show() }
    @objc private func showQuickNetworkTest(_ sender: NSButton) { NetworkQuickTestController.show(relativeTo: sender, card: self) }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                              color: NSColor = InformationPalette.ink) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color
        return label
    }
    private static func addressLabel(_ address: String) -> NSTextField {
        let field: NSTextField = address.contains(":") ? FullWidthIPAddressField(labelWithString: address) : NSTextField(wrappingLabelWithString: address)
        field.isSelectable = true
        field.font = InformationDataStyle.font
        field.textColor = InformationPalette.ink
        field.lineBreakMode = .byCharWrapping
        field.cell?.usesSingleLineMode = false; field.cell?.wraps = true
        field.maximumNumberOfLines = address.contains(":") ? 1 : 0
        if address.contains(":") {
            field.cell?.usesSingleLineMode = true; field.cell?.wraps = false
            field.lineBreakMode = .byClipping
        }
        return field
    }
    private func addRow(_ row: NSView) {
        content.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    func reloadMetrics() {
        addedChart = false
        for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }
        fields.removeAll(); publicAddressRows = nil; publicAddressLabels = []; displayedPublicAddresses = []; addressRefreshButton = nil; internalAddressRows = nil; displayedInternalAddresses = []; aiSection = nil; networkTestButton = nil
        let enabled = preferences.enabled
        if enabled.contains(.model) {
            let model = Self.label(MacHardwareIdentity.name + " · " + MacHardwareIdentity.chip, size: 10, color: InformationPalette.secondary)
            model.lineBreakMode = .byTruncatingTail
            model.toolTip = MacHardwareIdentity.name + " · " + MacHardwareIdentity.chip + " · " + MacHardwareIdentity.identifier
            addRow(model)
        }
        for metric in [SystemMetric.cpu, .gpu, .memory, .storage] where enabled.contains(metric) {
            addRow(metricRow(metric))
        }
        if enabled.contains(.network) {
            let value = Self.label("—", size: 12, weight: .medium)
            value.cell?.usesSingleLineMode = false; value.cell?.wraps = true; value.maximumNumberOfLines = 2
            fields[.network] = value
            let speed = NSButton(title: "测速", target: self, action: #selector(showQuickNetworkTest(_:)))
            networkTestButton = speed
            speed.bezelStyle = .inline; speed.isBordered = false; speed.font = .systemFont(ofSize: 11, weight: .medium)
            speed.contentTintColor = InformationPalette.blue; speed.setAccessibilityLabel("打开快捷测速选项")
            let name = Self.label("网络", size: 11, color: InformationPalette.secondary)
            name.setContentHuggingPriority(.required, for: .horizontal)
            value.alignment = .right; value.font = InformationDataStyle.font
            value.setContentHuggingPriority(.defaultLow, for: .horizontal)
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            speed.widthAnchor.constraint(equalToConstant: 26).isActive = true
            let network = NSStackView(views: [name, speed, value])
            network.orientation = .horizontal; network.spacing = 6; network.alignment = .firstBaseline; network.distribution = .fill
            network.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
            addRow(network)
            if preferences.chartEnabled.contains(.network) { addRow(chart(.network)) }
            if preferences.showAddresses {
                let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新 IP") ?? NSImage(), target: self, action: #selector(refreshAddresses))
                refresh.isBordered = false; refresh.contentTintColor = InformationPalette.blue
                addressRefreshButton = refresh
                let publicRows = NSStackView(); publicRows.orientation = .vertical; publicRows.alignment = .leading; publicRows.spacing = 4
                publicAddressRows = publicRows; addRow(publicRows)
                let addresses = NSStackView(); addresses.orientation = .vertical; addresses.alignment = .leading; addresses.spacing = 4
                internalAddressRows = addresses; addRow(addresses)
                updateAddresses(); NetworkAddressStore.shared.refresh()
            }
        }
        for metric in [SystemMetric.battery, .temperature] where enabled.contains(metric) {
            let value = Self.label("—", size: 12, weight: .medium)
            value.cell?.usesSingleLineMode = false; value.cell?.wraps = true; value.maximumNumberOfLines = 2
            fields[metric] = value
            addRow(alignedRow(metric == .battery ? "电池" : "温度", value: value))
            if preferences.chartEnabled.contains(metric) { addRow(chart(metric)) }
        }
        if enabled.isEmpty {
            let hint = Self.label("电脑信息已隐藏", size: 10, color: InformationPalette.secondary)
            addRow(hint)
        }
        if let aiStore, aiStore.sectionHeight > 0 {
            let line = NSBox(); line.boxType = .separator; addRow(line)
            let section = AIQuotaSectionView(store: aiStore); aiSection = section
            addRow(section)
        }
        update(lastMetrics)
        scroll.needsLayout = true
    }
    private func chart(_ metric: SystemMetric) -> MetricTrendView {
        let chart = MetricTrendView(metric: metric, showsTimeWindow: !addedChart)
        addedChart = true
        return chart
    }
    private func alignedRow(_ title: String, value: NSTextField, action: NSView? = nil) -> NSView {
        // Pin the value field itself to both edges of its available area. A stack's
        // content hugging can otherwise leave a right-aligned cell at intrinsic width.
        let row = NSView()
        let name = Self.label(title, size: 11, color: InformationPalette.secondary)
        value.alignment = .right; value.font = InformationDataStyle.font
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [name, value] { view.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(view) }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor), name.widthAnchor.constraint(equalToConstant: 38),
            name.firstBaselineAnchor.constraint(equalTo: value.firstBaselineAnchor),
            value.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            value.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            value.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
        if let action {
            action.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(action)
            NSLayoutConstraint.activate([
                action.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
                action.widthAnchor.constraint(equalToConstant: 18), action.heightAnchor.constraint(equalToConstant: 18),
                action.centerYAnchor.constraint(equalTo: name.centerYAnchor),
                value.leadingAnchor.constraint(equalTo: action.trailingAnchor, constant: 6)
            ])
        } else { value.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6).isActive = true }
        return row
    }
    private func appendAddress(_ address: String, index: Int, title: String, to stack: NSStackView, action: NSView? = nil) -> NSTextField {
        let label = Self.addressLabel(address)
        func add(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if address.contains(":") {
            if index == 0 {
                let name = Self.label(title, size: 11, color: InformationPalette.secondary)
                name.widthAnchor.constraint(equalToConstant: 38).isActive = true
                let header = NSStackView(views: [name] + (action.map { [$0] } ?? []) + [NSView()])
                header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 6
                header.heightAnchor.constraint(equalToConstant: 20).isActive = true
                if let action { action.widthAnchor.constraint(equalToConstant: 18).isActive = true }
                add(header)
            }
            label.alignment = .right
            label.heightAnchor.constraint(equalToConstant: 20).isActive = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            add(label)
        } else { add(alignedRow(index == 0 ? title : "", value: label, action: action)) }
        return label
    }
    @objc private func refreshAddresses() { NetworkAddressStore.shared.refresh(force: true) }
    private func updateAddresses() {
        let store = NetworkAddressStore.shared
        let publicLines = store.publicAddressLines
        if let publicAddressRows, displayedPublicAddresses != publicLines {
            displayedPublicAddresses = publicLines; publicAddressLabels = []
            for row in publicAddressRows.arrangedSubviews { publicAddressRows.removeArrangedSubview(row); row.removeFromSuperview() }
            for (index, address) in publicLines.enumerated() {
                let label = appendAddress(address, index: index, title: "出网 IP", to: publicAddressRows, action: index == 0 ? addressRefreshButton : nil)
                publicAddressLabels.append(label)
            }
        }
        scroll.needsLayout = true
        let lines = store.internalAddressLines
        if let internalAddressRows, displayedInternalAddresses != lines {
            displayedInternalAddresses = lines
            for row in internalAddressRows.arrangedSubviews { internalAddressRows.removeArrangedSubview(row); row.removeFromSuperview() }
            for (index, address) in lines.enumerated() {
                let label = appendAddress(address, index: index, title: "内网 IP", to: internalAddressRows)
                label.toolTip = address
            }
            scroll.needsLayout = true
        }
        for label in publicAddressLabels {
            label.toolTip = "HTTPS 出口查询 · ipify；代理/VPN 可能改变出口\n" + label.stringValue + (store.fetchedAt.map { "\n" + $0.formatted(date: .omitted, time: .shortened) + " 更新" } ?? "")
        }
    }
    func reloadAI() {
        if let aiStore, aiStore.sectionHeight > 0, let aiSection {
            aiSection.reload(); scroll.needsLayout = true
        } else { reloadMetrics() }
    }
    private func metricRow(_ metric: SystemMetric) -> NSView {
        let name: String = switch metric { case .cpu: "CPU"; case .gpu: "GPU"; case .memory: "内存"; default: "储存" }
        let value = Self.label("—", size: 11, weight: .medium)
        value.lineBreakMode = .byTruncatingMiddle
        fields[metric] = value
        let row = alignedRow(name, value: value)
        guard preferences.chartEnabled.contains(metric), SystemMetricPreferences.chartMetrics.contains(metric) else { return row }
        let chart = chart(metric)
        let stack = NSStackView(views: [row, chart])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        chart.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    static func formattedValues(_ metrics: SystemMetricsSnapshot) -> [String] {
        func bytes(_ value: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
        }
        func rate(_ value: Double?) -> String {
            guard let value, value.isFinite, value >= 0 else { return "—" }
            if value == 0 { return "0 KB/s" }
            return ByteCountFormatter.string(fromByteCount: Int64(min(value, Double(Int64.max / 2))), countStyle: .file) + "/s"
        }
        let cpu = metrics.cpuPercent.flatMap { $0.isFinite ? String(format: "%.0f%%", min(100, max(0, $0))) : nil } ?? "—"
        let memory = metrics.memoryReadingAvailable && metrics.memoryTotalBytes > 0 ? "\(bytes(metrics.memoryUsedBytes)) / \(bytes(metrics.memoryTotalBytes))" : "—"
        let battery = metrics.batteryPercent.map { "\(min(100, max(0, $0)))%" + (metrics.batteryCharging == true ? " · 充电" : "") } ?? "—"
        return [cpu, memory, rate(metrics.downloadBytesPerSecond), rate(metrics.uploadBytesPerSecond), battery]
    }

    func update(_ metrics: SystemMetricsSnapshot) {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if lastOpaqueFallback != opaque {
            glassBackground?.isHidden = opaque
            tintBackground?.needsDisplay = true
            lastOpaqueFallback = opaque
        }
        lastMetrics = metrics
        let values = Self.formattedValues(metrics)
        func percent(_ metric: SystemMetric, _ value: Double?, caption: String) {
            let valid = value.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
            fields[metric]?.stringValue = valid.map { String(format: "%.0f%%", $0) + (caption.isEmpty ? "" : " · " + caption) } ?? (caption.isEmpty ? "—" : caption)
            fields[metric]?.toolTip = caption
            let alert = metric == .storage ? (valid ?? 0) >= 90 : (valid ?? 0) >= 85
            fields[metric]?.textColor = alert ? InformationPalette.warning : InformationPalette.ink
        }
        percent(.cpu, metrics.cpuPercent, caption: "")
        percent(.memory, metrics.memoryReadingAvailable && metrics.memoryTotalBytes > 0 ? Double(metrics.memoryUsedBytes) / Double(metrics.memoryTotalBytes) * 100 : nil, caption: metrics.memoryReadingAvailable && metrics.memoryTotalBytes > 0 ? String(format: "%.1f/%.0f GB", Double(metrics.memoryUsedBytes) / 1_073_741_824, Double(metrics.memoryTotalBytes) / 1_073_741_824) : "不可用")
        fields[.memory]?.toolTip = values[1]
        percent(.gpu, metrics.hardware.gpuPercent, caption: metrics.hardware.gpuPercent == nil ? (metrics.hardware.fetchedAt == nil ? "读取中…" : "不可用") : "")
        fields[.gpu]?.toolTip = metrics.hardware.gpuName
        if let used = metrics.hardware.storageUsedBytes, let total = metrics.hardware.storageTotalBytes, total > 0 {
            let bytes: (UInt64) -> String = { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) }
            percent(.storage, Double(used) / Double(total) * 100, caption: String(format: "%.1f/%.1f GB", Double(used) / 1_000_000_000, Double(total) / 1_000_000_000))
            fields[.storage]?.toolTip = bytes(used) + " / " + bytes(total) + " · 启动磁盘已用 / 总容量；APFS 共享空间。"
        } else { percent(.storage, nil, caption: metrics.hardware.fetchedAt == nil ? "正在读取…" : "暂未取得容量") }
        fields[.network]?.stringValue = "↓ " + values[2] + "  ↑ " + values[3]
        fields[.network]?.toolTip = "物理网络接口汇总，不重复累加 VPN 隧道"
        fields[.battery]?.stringValue = metrics.batteryPresent == false ? "无内置电池" : values[4]
        var temperatures: [String] = []
        if let value = metrics.hardware.cpuTemperature { temperatures.append(String(format: "CPU %.0f°C", value)) }
        if let value = metrics.hardware.gpuTemperature { temperatures.append(String(format: "GPU %.0f°C", value)) }
        fields[.temperature]?.stringValue = temperatures.isEmpty ? (metrics.hardware.fetchedAt == nil ? "正在读取…" : "传感器不可用\n热状态 · " + Self.thermalTitle) : temperatures.joined(separator: " · ")
        fields[.temperature]?.toolTip = "只读 CPU/GPU 传感器中的最高温；传感器可用性随机型与系统变化。热状态不是摄氏温度。"
        if aiSection?.refreshCountdownIfNeeded() == true { scroll.needsLayout = true }
    }
    static var thermalTitle: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "正常"
        case .fair: "温热"
        case .serious: "偏热"
        case .critical: "过热"
        @unknown default: "未知"
        }
    }

}

/// Shared numeric typography, matching the full-row LAN IPv6 baseline.
@MainActor
enum InformationDataStyle {
    static var font: NSFont { .monospacedSystemFont(ofSize: 11, weight: .medium) }
}

@MainActor
enum InformationPalette {
    static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
        }
    }
    static let background = color(0xE8F0FF, 0x0B1427)
    static let surface = color(0xF5F9FF, 0x1E2B43)
    static let ink = color(0x162943, 0xF0F7FF)
    static let secondary = color(0x436077, 0xBDD2E8)
    static let border = color(0xB5CAE5, 0x526987)
    static let blue = color(0x3578D4, 0x9CDCFB)
    static let teal = color(0x167D8D, 0x6ED8CB)
    static let warning = color(0x995100, 0xFFCD79)
    static let rose = color(0x9D4F72, 0xF2A9CD)
}

@MainActor
private final class InformationGlassTint: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 20, yRadius: 20)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            InformationPalette.surface.setFill(); path.fill()
            InformationPalette.border.setStroke(); path.stroke()
            return
        }
        NSGradient(starting: InformationPalette.surface.withAlphaComponent(0.94),
                   ending: InformationPalette.background.withAlphaComponent(0.86))?.draw(in: path, angle: -70)
        InformationPalette.border.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1; path.stroke()
    }
}

@MainActor
private final class InformationDocumentView: NSView { override var isFlipped: Bool { true } }
