import AppKit
import UniformTypeIdentifiers

@MainActor
final class UsageReportWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: UsageReportStore
    private let source = NSPopUpButton()
    private let period = NSPopUpButton()
    private let table = NSTableView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "选择一条记录查看明细")
    private let exportButton = NSButton(title: "导出 CSV…", target: nil, action: nil)
    private let broadcastButton = NSButton(checkboxWithTitle: "自动播报", target: nil, action: nil)
    private var displayed: [UsageReportRecord] = []
    private var observation: NSObjectProtocol?
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()

    init(store: UsageReportStore) {
        self.store = store
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "WhaleGirl · 用量报表"; panel.minSize = NSSize(width: 900, height: 580)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        build(in: panel)
        // Keep every primary usage and fee column visible when the window opens.
        panel.setContentSize(NSSize(width: 1000, height: 650)); panel.center()
        observation = NotificationCenter.default.addObserver(forName: UsageReportStore.changed, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }
    required init?(coder: NSCoder) { nil }
    // The store retains this controller for its lifetime; the observer captures it weakly.
    private func build(in panel: NSWindow) {
        let content = NSView(); panel.contentView = content; WhalePanelStyle.surface(content)
        let title = WhalePanelStyle.label("用量报表", size: 21, weight: .semibold)
        source.addItems(withTitles: ["全部来源", "DSH", "Codex"])
        period.addItems(withTitles: ["全部日期", "今天", "最近 7 天", "最近 30 天"])
        for popup in [source, period] { popup.target = self; popup.action = #selector(filtersChanged) }
        exportButton.target = self; exportButton.action = #selector(exportCSV); WhalePanelStyle.button(exportButton)
        broadcastButton.target = self; broadcastButton.action = #selector(toggleBroadcasts)
        broadcastButton.font = .systemFont(ofSize: 11)
        broadcastButton.toolTip = "新用量以文字气泡自动播报；关闭后仍继续记入报表。"
        let header = WhalePanelStyle.row([title, NSView(), broadcastButton, source, period, exportButton], spacing: 10)
        summary.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        summary.textColor = InformationPalette.ink; summary.maximumNumberOfLines = 5
        status.font = .systemFont(ofSize: 11); status.textColor = InformationPalette.secondary
        let note = WhalePanelStyle.label("输入已含缓存，输出已含推理；“—”表示未提供。费用按币种分别合计。时间为本机时区。", size: 11, secondary: true)
        note.cell?.wraps = true; note.maximumNumberOfLines = 2
        let columns: [(String, String, CGFloat)] = [
            ("time", "时间", 108), ("source", "来源", 55), ("model", "模型", 145),
            ("input", "输入", 75), ("output", "输出", 70), ("hit", "缓存命中", 75),
            ("miss", "缓存未命中", 80), ("cost", "费用 / 口径", 190)
        ]
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = 45
            column.resizingMask = .userResizingMask
            table.addTableColumn(column)
        }
        // AppKit may distribute widths while columns are being inserted.
        for (column, spec) in zip(table.tableColumns, columns) { column.width = spec.2 }
        table.delegate = self; table.dataSource = self
        table.rowHeight = 29; table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = false; table.backgroundColor = InformationPalette.surface
        table.setAccessibilityLabel("DSH 与 Codex 用量记录")
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        detail.font = .systemFont(ofSize: 11); detail.textColor = InformationPalette.secondary
        detail.maximumNumberOfLines = 4; detail.isSelectable = true
        detail.heightAnchor.constraint(equalToConstant: 66).isActive = true
        let stack = WhalePanelStyle.column([header, WhalePanelStyle.card(summary), status, note, scroll, WhalePanelStyle.card(detail, inset: 10)], spacing: 12)
        WhalePanelStyle.pin(stack, in: content)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
    @objc private func filtersChanged() { reload() }
    @objc private func toggleBroadcasts() { store.broadcastsEnabled = broadcastButton.state == .on }
    private func reload() {
        broadcastButton.state = store.broadcastsEnabled ? .on : .off
        let selectedID = displayed.indices.contains(table.selectedRow) ? displayed[table.selectedRow].id : nil
        let calendar = Calendar.current, now = Date()
        let start: Date?
        switch period.indexOfSelectedItem {
        case 1: start = calendar.startOfDay(for: now)
        case 2: start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case 3: start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        default: start = nil
        }
        let selectedSource = source.indexOfSelectedItem == 1 ? "dsh" : source.indexOfSelectedItem == 2 ? "codex" : nil
        displayed = store.records.filter { r in
            (selectedSource == nil || r.source == selectedSource) && (start == nil || (r.occurredAt >= start! && r.occurredAt <= now))
        }
        let s = UsageReportSummary(displayed), count = displayed.count
        let turns = displayed.filter { $0.granularity == "turn" }.count
        summary.stringValue = "\(count) 条记录" + (turns > 0 ? "（含 \(turns) 条轮次汇总）" : "")
            + "   输入 \(s.input.text(count: count)) · 输出 \(s.output.text(count: count))\n"
            + "缓存命中 \(s.cached.text(count: count)) · 未命中 \(s.uncached.text(count: count))\n"
            + "实报费用：\(UsageReportSummary.money(s.reported))\n估算费用：\(UsageReportSummary.money(s.estimated)) · 未提供费用 \(s.missingCosts) 条"
        status.stringValue = store.statusText + (count == 0 ? " · 当前筛选暂无记录" : "")
        status.toolTip = status.stringValue; exportButton.isEnabled = !displayed.isEmpty
        table.reloadData()
        if let selectedID, let row = displayed.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateDetail()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayed.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let r = displayed[row], value: String
        switch id {
        case "time": value = dateFormatter.string(from: r.occurredAt)
        case "source": value = r.sourceTitle
        case "model": value = r.model ?? "—"
        case "input": value = UsageReportRecord.token(r.inputTokens)
        case "output": value = UsageReportRecord.token(r.outputTokens)
        case "hit": value = UsageReportRecord.token(r.cachedInputTokens)
        case "miss": value = UsageReportRecord.token(r.uncachedInputTokens)
        default: value = r.costText.count > 18 ? String(r.costText.prefix(12)) + "…" : r.costText
        }
        let label = NSTextField(labelWithString: value)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        if ["input", "output", "hit", "miss"].contains(id) { label.alignment = .right }
        label.lineBreakMode = .byTruncatingTail; label.toolTip = id == "cost" ? r.costText + (r.costBasis.map { "\n" + $0 } ?? "") : value
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }
    private func updateDetail() {
        guard displayed.indices.contains(table.selectedRow) else { detail.stringValue = "选择一条记录查看明细"; return }
        let r = displayed[table.selectedRow]
        let date = DateFormatter.localizedString(from: r.occurredAt, dateStyle: .medium, timeStyle: .medium)
        detail.stringValue = "\(r.sourceTitle) · \(r.model ?? "模型未提供") · \(date) · \(r.granularity == "turn" ? "轮次汇总" : "单次请求")\n"
            + "缓存写入 \(UsageReportRecord.token(r.cacheWriteTokens)) · 推理 \(UsageReportRecord.token(r.reasoningTokens)) · \(r.costText)\n"
            + "会话 \(r.session) · 记录 \(r.id)"
            + (r.costBasis.map { "\n" + $0 } ?? "")
        detail.toolTip = detail.stringValue
    }
    @objc private func exportCSV() {
        guard let window else { return }
        let records = displayed
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "WhaleGirl-用量报表.csv"
        panel.message = "导出当前来源与日期筛选的 \(records.count) 条用量记录。未知数值留空，费用口径单列。"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try UsageReportCSV.data(records).write(to: url, options: .atomic) }
            catch {
                let alert = NSAlert(); alert.messageText = "无法导出 CSV"; alert.informativeText = "请检查目标文件夹的写入权限后重试。"
                alert.beginSheetModal(for: window)
            }
        }
    }
}
