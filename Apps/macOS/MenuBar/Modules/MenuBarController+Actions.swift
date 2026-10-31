import AppKit
import QuartzCore
import WhaleCore

@MainActor
extension MenuBarController {
    func showContextMenu(event explicitEvent: NSEvent? = nil) {
        guard let button = statusItem?.button, let event = explicitEvent ?? NSApp.currentEvent else { return }
        let menu = NSMenu()
        menu.addItem(item("打开 Dashboard", action: #selector(showDashboard)))
        menu.addItem(item("探头 / 收回", action: #selector(togglePeek)))
        menu.addItem(item("拖出全身", action: #selector(showFull)))
        menu.addItem(item("一键关闭所有鲸鱼娘", action: #selector(closeAllCharacters)))
        menu.addItem(item("选择电脑信息…", action: #selector(showSystemMetricSettings)))
        menu.addItem(item("网络诊断与测速…", action: #selector(showNetworkDiagnostics)))
        menu.addItem(item("Token 用量与费用报表…", action: #selector(showUsageReport)))
        menu.addItem(item("消息与对话…", action: #selector(showMessageConversations)))
        menu.addItem(item("消息 API 设置…", action: #selector(showMessageAPISettings)))
        menu.addItem(item("编辑气泡文案 CSV", action: #selector(editSpeechCSV)))
        if let aiStore {
            let quota = item("显示 AI 额度", action: #selector(toggleAIQuotas))
            quota.state = aiStore.preferences.showQuotas ? .on : .off; menu.addItem(quota)
            let agents = item("子 Agent 自动生成鲸鱼娘", action: #selector(toggleAgentCompanions))
            agents.state = aiStore.preferences.autoAgentPets ? .on : .off; menu.addItem(agents)
            menu.addItem(item("选择 AI 工具…", action: #selector(showAISettings)))
        }
        let skinItem = NSMenuItem(title: "桌宠皮肤", action: nil, keyEquivalent: "")
        let skinMenu = NSMenu()
        for skin in SpriteRepository.Skin.allCases {
            let entry = item(skin.title, action: #selector(selectSkin(_:)))
            entry.representedObject = skin.rawValue
            entry.state = repository.selectedSkin == skin ? .on : .off
            skinMenu.addItem(entry)
        }
        skinItem.submenu = skinMenu
        menu.addItem(skinItem)
        if !repository.communityActions.isEmpty {
            let actionItem = NSMenuItem(title: "桌面动作", action: nil, keyEquivalent: "")
            let actionMenu = NSMenu()
            actionMenu.addItem(item("随机播放全部动作", action: #selector(showFull)))
            actionMenu.addItem(.separator())
            let categories = Dictionary(grouping: repository.communityActions, by: \.category)
            for category in categories.keys.sorted() {
                let categoryItem = NSMenuItem(title: category, action: nil, keyEquivalent: "")
                let categoryMenu = NSMenu()
                for action in categories[category] ?? [] {
                    let entry = item(action.title, action: #selector(playCommunityAction(_:)))
                    entry.representedObject = action.clipID
                    categoryMenu.addItem(entry)
                }
                actionMenu.setSubmenu(categoryMenu, for: categoryItem)
                actionMenu.addItem(categoryItem)
            }
            menu.setSubmenu(actionMenu, for: actionItem)
            menu.addItem(actionItem)
        }
        menu.addItem(.separator())

        let scaleItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let scaleMenu = NSMenu()
        let scaleControlItem = NSMenuItem()
        let scaleControl = makeScaleControl()
        scaleControlItem.view = scaleControl
        scaleMenu.addItem(scaleControlItem)
        menu.setSubmenu(scaleMenu, for: scaleItem)
        menu.addItem(scaleItem)
        let sound = NSMenuItem(title: "声音", action: nil, keyEquivalent: "")
        sound.state = .off
        sound.isEnabled = false
        menu.addItem(sound)
        menu.addItem(.separator())
        menu.addItem(item("检查软件更新…", action: #selector(showSoftwareUpdate)))
        let automaticUpdate = item("自动更新鲸鱼娘", action: #selector(toggleSoftwareUpdate))
        automaticUpdate.state = SoftwareUpdateController.shared.automatic ? .on : .off
        menu.addItem(automaticUpdate)
        menu.addItem(.separator())
        menu.addItem(item("退出 WhaleGirl", action: #selector(quit)))
        contextMenuPresenter(menu, event, button)
    }

    @objc func selectSkin(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let skin = SpriteRepository.Skin(rawValue: raw) else { return }
        delegate?.menuBarDidSelectSkin(skin)
    }

    func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func makeScaleControl() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 54))
        let valueLabel = NSTextField(labelWithString: "\(Int((currentScale * 100).rounded()))%")
        valueLabel.font = .systemFont(ofSize: 13, weight: .medium)
        valueLabel.alignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider(value: currentScale * 100,
                              minValue: 80,
                              maxValue: 150,
                              target: self,
                              action: #selector(changeScale(_:)))
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(valueLabel)
        container.addSubview(slider)
        NSLayoutConstraint.activate([
            valueLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            valueLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            slider.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 1),
            slider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            slider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            slider.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5)
        ])
        scaleValueLabel = valueLabel
        return container
    }

    @objc func toggleAIQuotas() { if let aiStore { aiStore.setShowQuotas(!aiStore.preferences.showQuotas) } }
    @objc func toggleAgentCompanions() { if let aiStore { aiStore.setAutoAgentPets(!aiStore.preferences.autoAgentPets) } }
    @objc func showSystemMetricSettings() { SystemMetricSettingsWindow.show() }
    @objc func showMessageConversations() { MessageInboxController.shared.showConversations() }
    @objc func showMessageAPISettings() { MessageInboxController.shared.showSettings() }
    @objc func showUsageReport() { UsageReportStore.shared.showReport() }

    @objc func showNetworkDiagnostics() { NetworkDiagnosticsWindow.show() }
    @objc func showAISettings() { aiStore?.showSettings() }

    @objc func editSpeechCSV() {
        do {
            try DeepSeekChanDialog.prepareFile()
            let url = DeepSeekChanDialog.fileURL
            if let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
                NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
            } else { NSWorkspace.shared.open(url) }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法打开气泡文案 CSV"
            alert.runModal()
        }
    }

    @objc func togglePeek() { delegate?.menuBarDidRequestTogglePeek() }
    @objc func showDashboard() { delegate?.menuBarDidRequestDashboard() }
    @objc func closeAllCharacters() { delegate?.menuBarDidRequestCloseAllCharacters() }
    @objc func showFull() { delegate?.menuBarDidRequestFull() }
    @objc func playCommunityAction(_ sender: NSMenuItem) {
        guard let clipID = sender.representedObject as? String else { return }
        delegate?.menuBarDidRequestAction(clipID)
    }
    @objc func showSoftwareUpdate() { SoftwareUpdateController.shared.showAndCheck() }
    @objc func toggleSoftwareUpdate() {
        SoftwareUpdateController.shared.automatic.toggle()
    }
    @objc func quit() { delegate?.menuBarDidRequestQuit() }

    @objc func changeScale(_ sender: NSSlider) {
        let value = sender.doubleValue / 100
        currentScale = value
        scaleValueLabel?.stringValue = "\(Int(sender.doubleValue.rounded()))%"
        delegate?.menuBarDidChangeScale(value)
    }
}
