import AppKit
import WhaleCore

@MainActor
final class MessageAPISettingsWindow: NSObject {
    private let inbox: MessageInboxController
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let enabled = NSButton(checkboxWithTitle: "启用消息接收 API", target: nil, action: nil)
    private let host = NSTextField(string: "")
    private let port = NSTextField(string: "")
    private let seconds = NSTextField(string: "")
    private let volume = NSTextField(string: "")
    private let token = NSSecureTextField(string: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    init(inbox: MessageInboxController) {
        self.inbox = inbox; super.init()
        window.title = "消息接收与 API"; window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        stack.addArrangedSubview(enabled)
        for (label, field) in [("监听地址", host), ("端口", port), ("文字停留（秒）", seconds), ("播放音量（0–1）", volume), ("接入密钥", token as NSTextField)] {
            let row = NSStackView(views: [NSTextField(labelWithString: label), field]); row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false; field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            stack.addArrangedSubview(row)
        }
        let actions = NSStackView(views: [button("保存设置", #selector(save)), button("复制密钥", #selector(copyToken)), button("更换密钥", #selector(rotateToken))]); actions.spacing = 10
        stack.addArrangedSubview(actions)
        let files = NSStackView(views: [button("打开外置配置", #selector(openConfiguration)), button("打开对话", #selector(openConversations)), button("接口说明", #selector(openDocumentation))]); files.spacing = 10
        stack.addArrangedSubview(files)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.widthAnchor.constraint(equalToConstant: 460).isActive = true; stack.addArrangedSubview(status)
        let hint = NSTextField(wrappingLabelWithString: "默认仅接收本机请求。公网接入可通过 HTTPS 反向代理转发到此接口。图片、音频、视频先上传，再发送消息。更多播放设置可在外置 JSON 中修改，保存后自动载入。")
        hint.font = .systemFont(ofSize: 12); hint.widthAnchor.constraint(equalToConstant: 460).isActive = true; stack.addArrangedSubview(hint)
        inbox.onStatusChanged = { [weak self] in self?.updateStatus() }
    }
    func show() {
        let value = inbox.settings
        enabled.state = value.enabled ? .on : .off; host.stringValue = value.listenHost; port.stringValue = String(value.port)
        seconds.stringValue = String(value.textSeconds); volume.stringValue = String(value.volume); token.stringValue = value.token
        updateStatus(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func updateStatus() {
        let value = inbox.settings
        status.stringValue = "\(inbox.status) · http://\(value.listenHost == "::1" ? "[::1]" : value.listenHost):\(value.port)/v1\n配置：\(inbox.configurationURL.path)"
    }
    @objc private func save() {
        var value = inbox.settings
        guard let p = UInt16(port.stringValue), let duration = Double(seconds.stringValue), let level = Double(volume.stringValue) else { status.stringValue = "请填写正确的端口、秒数和音量"; return }
        value.enabled = enabled.state == .on; value.listenHost = host.stringValue; value.port = p; value.textSeconds = duration; value.volume = level; value.token = token.stringValue
        Task { [weak self] in
            guard let self else { return }
            do { try await self.inbox.save(value); self.updateStatus() }
            catch { self.status.stringValue = "设置未保存：请检查地址、端口、密钥及数值范围" }
        }
    }
    @objc private func copyToken() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(inbox.settings.token, forType: .string) }
    @objc private func rotateToken() { token.stringValue = (try? MessageInboxController.newToken()) ?? token.stringValue; status.stringValue = "点击“保存设置”后，新密钥生效，旧密钥失效" }
    @objc private func openConfiguration() { NSWorkspace.shared.open(inbox.configurationURL) }
    @objc private func openDocumentation() { inbox.openDocumentation() }
    @objc private func openConversations() { inbox.showConversations() }
}
