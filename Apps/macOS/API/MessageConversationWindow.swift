import AppKit

@MainActor
final class MessageConversationWindow: NSObject, NSComboBoxDelegate {
    private let store: MessageConversationStore
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private let conversation = NSComboBox()
    private let transcript = NSTextView()
    private let composer = NSTextField(string: "")
    private let status = NSTextField(labelWithString: "")
    private var observation: AIMonitorObservation?
    private var refreshing = false
    private var cachedIDs: [String] = []
    init(store: MessageConversationStore) {
        self.store = store; super.init()
        window.title = "鲸鱼娘 · 对话"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 450, height: 360)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)])
        conversation.delegate = self; conversation.placeholderString = "会话 ID，也可输入新会话主动发送"; conversation.completes = true
        stack.addArrangedSubview(conversation); conversation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        transcript.isEditable = false; transcript.isSelectable = true; transcript.isRichText = false
        transcript.font = .systemFont(ofSize: 13); transcript.textContainerInset = NSSize(width: 12, height: 12)
        transcript.autoresizingMask = [.width]; transcript.isVerticallyResizable = true; transcript.textContainer?.widthTracksTextView = true
        scroll.documentView = transcript; stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        composer.placeholderString = "输入回复或主动发送的消息"; composer.target = self; composer.action = #selector(send)
        let sendButton = NSButton(title: "发送", target: self, action: #selector(send))
        let row = NSStackView(views: [composer, sendButton]); row.spacing = 10; stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; composer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        stack.addArrangedSubview(status)
        observation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: MessageConversationStore.changed, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }
    func show(conversationID: String) {
        conversation.stringValue = conversationID; refresh()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard !refreshing else { return }
        if let selected = conversation.objectValueOfSelectedItem as? String { conversation.stringValue = selected }
        refresh()
    }
    func controlTextDidEndEditing(_ obj: Notification) { if obj.object as? NSComboBox === conversation { refresh() } }
    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let id = conversation.stringValue.isEmpty ? "default" : conversation.stringValue
        let ids = store.conversationIDs
        if cachedIDs != ids {
            cachedIDs = ids
            conversation.removeAllItems(); conversation.addItems(withObjectValues: ids)
        }
        conversation.stringValue = id
        let date = DateFormatter(); date.dateFormat = "MM-dd HH:mm:ss"
        transcript.string = store.entries.filter { $0.conversationID == id }.map { item in
            let name = item.direction == "outgoing" ? "我" : (item.sender ?? "对方")
            let delivery = item.direction == "outgoing" ? (item.acknowledged ? " · 已接收" : " · 待对方接收") : ""
            let media = item.kind == "text" ? "" : "[\(item.kind)] "
            return "\(name) · \(date.string(from: item.createdAt))\(delivery)\n\(media)\(item.text)\n"
        }.joined(separator: "\n")
        transcript.scrollToEndOfDocument(nil)
        status.stringValue = store.loadFailed ? "对话记录读取失败，原文件已保留，暂不能发送" : "回复保存在本机发件箱，对方通过 API 拉取并确认接收。"
    }
    @objc private func send() {
        do {
            try store.send(text: composer.stringValue, conversationID: conversation.stringValue)
            composer.stringValue = ""; refresh()
        } catch { status.stringValue = "未发送：请检查会话 ID、消息长度或发件箱容量" }
    }
}
