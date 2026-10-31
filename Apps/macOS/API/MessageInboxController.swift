import AppKit
import Security
import WhaleCore

@MainActor
final class MessageInboxController {
    static let shared = MessageInboxController()
    let configurationURL: URL
    let mediaDirectory: URL
    let conversations: MessageConversationStore
    private var conversationWindow: MessageConversationWindow?
    private(set) var settings = MessageAPISettings(token: "")
    private(set) var status = "未启动"
    var onStatusChanged: (() -> Void)?
    private var server: MessageHTTPServer?
    private var service: MessageAPIService?
    private var watcher: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    private var messages: [IncomingMessage] = []
    private var lastConfiguration = Data()
    private var configurationFailed = false
    private var settingsWindow: MessageAPISettingsWindow?
    private var generation = UUID()
    private var isQuiet: @MainActor () -> Bool = { false }
    private var present: (@MainActor (IncomingMessage, MessageAPISettings) async -> MessageDelivery)?
    init(configurationURL: URL? = nil, mediaDirectory: URL? = nil) {
        let fm = FileManager.default
        self.configurationURL = configurationURL ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhaleGirl/UserData/消息API.json")
        self.mediaDirectory = mediaDirectory ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhaleGirl/MessageInbox", isDirectory: true)
        self.conversations = MessageConversationStore(file: self.configurationURL.deletingLastPathComponent().appendingPathComponent("消息对话.json"))
    }
    func start(isQuiet: @escaping @MainActor () -> Bool,
               present: @escaping @MainActor (IncomingMessage, MessageAPISettings) async -> MessageDelivery) {
        guard watcher == nil else { return }
        self.isQuiet = isQuiet; self.present = present
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reload()
                await self?.service?.maintenance()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func stop() {
        generation = UUID(); watcher?.cancel(); watcher = nil
        displayTask?.cancel(); displayTask = nil
        let pending = messages; messages.removeAll()
        let service = service, server = server
        self.server = nil; self.present = nil; lastConfiguration = Data()
        Task {
            for item in pending { await service?.delivered(item, status: "cancelled") }
            await server?.stop()
        }
        status = "已停止"; onStatusChanged?()
    }
    var documentationURL: URL { configurationURL.deletingLastPathComponent().appendingPathComponent("消息API-2.1.1说明.md") }
    private func ensureDocumentation() {
        guard !FileManager.default.fileExists(atPath: documentationURL.path),
              let source = Bundle.main.url(forResource: "MESSAGE_API", withExtension: "md") else { return }
        try? FileManager.default.createDirectory(at: documentationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: source, to: documentationURL)
        if let client = Bundle.main.url(forResource: "send_whale_message", withExtension: "py") {
            let target = configurationURL.deletingLastPathComponent().appendingPathComponent("消息API客户端-2.1.1.py")
            if !FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.copyItem(at: client, to: target) }
        }
    }
    func openDocumentation() { ensureDocumentation(); NSWorkspace.shared.open(documentationURL) }
    func showSettings() {
        ensureDocumentation()
        if settingsWindow == nil { settingsWindow = MessageAPISettingsWindow(inbox: self) }
        settingsWindow?.show()
    }
    func showConversations(id: String = "default") {
        if conversationWindow == nil { conversationWindow = MessageConversationWindow(store: conversations) }
        conversationWindow?.show(conversationID: id)
    }
    static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MessageAPIError.invalidSettings }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    func save(_ value: MessageAPISettings) async throws {
        try write(value)
        await reload(force: true)
    }
    private func write(_ value: MessageAPISettings) throws {
        try value.validate()
        let fm = FileManager.default
        guard configurationURL.resolvingSymlinksInPath().standardizedFileURL.path == configurationURL.standardizedFileURL.path else { throw MessageAPIError.invalidSettings }
        try fm.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: configurationURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
    }
    private func reload(force: Bool = false) async {
        do {
            if !FileManager.default.fileExists(atPath: configurationURL.path) {
                try write(MessageAPISettings(token: Self.newToken()))
            }
            guard let size = try configurationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
                  configurationURL.resolvingSymlinksInPath().standardizedFileURL.path == configurationURL.standardizedFileURL.path else { throw MessageAPIError.invalidSettings }
            let bytes = try Data(contentsOf: configurationURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
            guard force || configurationFailed || bytes != lastConfiguration else { return }
            let value = try JSONDecoder().decode(MessageAPISettings.self, from: bytes); try value.validate()
            ensureDocumentation()
            let restart = force || service == nil || value.requiresRestart(comparedTo: settings) || (value.enabled && server == nil)
            settings = value; lastConfiguration = bytes; configurationFailed = false
            if service == nil {
                service = MessageAPIService(settings: value, directory: mediaDirectory, conversations: conversations,
                    receive: { [weak self] item in await self?.enqueue(item) ?? false },
                    patchSettings: { [weak self] data in await self?.patchPresentation(data) })
            }
            await service?.update(value)
            if restart {
                generation = UUID(); let request = generation
                let previous = server; server = nil; await previous?.stop()
                guard !Task.isCancelled, generation == request else { return }
                if value.enabled, let service {
                    let newServer = try MessageHTTPServer(settings: value, handler: { await service.handle($0) }, onState: { [weak self] line in
                        Task { @MainActor in
                            guard let self, self.generation == request else { return }
                            self.status = line; self.onStatusChanged?()
                        }
                    })
                    server = newServer; status = "正在启动"; newServer.start()
                } else {
                    status = "已关闭"; displayTask?.cancel()
                    let pending = messages; messages.removeAll()
                    for item in pending { await service?.delivered(item, status: "cancelled") }
                }
            }
            if value.enabled, !messages.isEmpty, displayTask == nil { runQueue() }
            if !restart { status = value.enabled ? "正在监听" : "已关闭" }
            onStatusChanged?()
        } catch { configurationFailed = true; status = "配置无效或监听失败；请检查外置配置文件"; onStatusChanged?() }
    }
    func patchPresentation(_ data: Data) -> MessageAPISettings? {
        let allowed: Set<String> = ["textSeconds", "imageSeconds", "maxPlaybackSeconds", "volume", "bubbleWidth", "maxWaitSeconds", "respectQuietMode"]
        do {
            guard let patch = try JSONSerialization.jsonObject(with: data) as? [String: Any], !patch.isEmpty,
                  Set(patch.keys).isSubset(of: allowed),
                  var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any] else { return nil }
            object.merge(patch) { _, new in new }
            let value = try JSONDecoder().decode(MessageAPISettings.self, from: JSONSerialization.data(withJSONObject: object))
            try write(value); settings = value; lastConfiguration = try Data(contentsOf: configurationURL)
            onStatusChanged?(); return value
        } catch { return nil }
    }
    private func enqueue(_ item: IncomingMessage) -> Bool {
        guard settings.enabled, present != nil, messages.count < settings.maxQueue else { return false }
        do { try conversations.recordIncoming(item) }
        catch { status = "对话记录无法保存，消息未接收"; onStatusChanged?(); return false }
        messages.append(item)
        if displayTask == nil { runQueue() }
        return true
    }
    private func runQueue() {
        displayTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.displayTask = nil
                if !self.messages.isEmpty, self.settings.enabled, self.present != nil { self.runQueue() }
            }
            while !Task.isCancelled, !self.messages.isEmpty {
                let item = self.messages[0]
                if Date().timeIntervalSince(item.receivedAt) > self.settings.maxWaitSeconds {
                    self.messages.removeFirst(); await self.service?.delivered(item, status: "expired"); continue
                }
                if !self.settings.enabled { self.messages.removeFirst(); await self.service?.delivered(item, status: "cancelled"); continue }
                if self.settings.respectQuietMode && self.isQuiet() {
                    await self.service?.delivered(item, status: "deferred")
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }; continue
                }
                guard let present = self.present else { return }
                let result = await present(item, self.settings)
                if result == .deferred {
                    await self.service?.delivered(item, status: "deferred")
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                } else {
                    guard self.messages.first?.id == item.id else { return }
                    self.messages.removeFirst(); await self.service?.delivered(item, status: result.rawValue)
                }
            }
        }
    }
    func beganPlaying(_ item: IncomingMessage) { Task { await service?.delivered(item, status: "playing") } }
}
