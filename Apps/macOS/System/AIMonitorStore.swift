import AppKit
import WhaleCore

final class AIMonitorObservation: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor
final class AIMonitorStore {
    static let shared = AIMonitorStore()
    static let changed = Notification.Name("WhaleGirl.AIMonitorChanged")
    let directory: URL
    var preferencesURL: URL { directory.appendingPathComponent("AI工具设置.json") }
    private(set) var preferences: AIMonitorPreferences
    private(set) var readings: [String: AIQuotaReading] = [:]
    private(set) var configurationError = false
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var nativeRefreshTask: Task<Void, Never>?
    private var activity = AIActivityTracker()
    private var lastRefresh = Date.distantPast
    private var settingsWindow: AIMonitorSettingsWindow?
    private(set) var installingEventBridges = false
    private(set) var bridgeInstallationMessage: String?

    init(directory: URL? = nil) {
        self.directory = directory ?? WhaleGirlUserFiles.directory
        preferences = .defaults
        reloadPreferences()
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { input in
            let value = try input.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try input.singleValueContainer(), debugDescription: "Invalid timestamp")
        }
        return decoder
    }
    func start() {
        prepareFiles()
        refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 5
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil; refreshTask?.cancel(); refreshTask = nil; nativeRefreshTask?.cancel(); nativeRefreshTask = nil; settingsWindow?.close() }
    func prepareFiles() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("AI额度", isDirectory: true), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: preferencesURL.path) { try savePreferences() }
        } catch { configurationError = true }
    }
    private func reloadPreferences() {
        guard let data = try? Data(contentsOf: preferencesURL), data.count <= 262144 else { return }
        guard var loaded = try? Self.decoder().decode(AIMonitorPreferences.self, from: data), loaded.isValid else { configurationError = true; return }
        let migrated = loaded.migrateDesktopSources()
        preferences = loaded; configurationError = false
        if migrated {
            do {
                let backup = preferencesURL.appendingPathExtension("before-native-sources.bak")
                if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
                try savePreferences()
            } catch { configurationError = true }
        }
    }
    private func savePreferences() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(preferences).write(to: preferencesURL, options: .atomic)
        configurationError = false
    }
    func setShowQuotas(_ enabled: Bool) { preferences.showQuotas = enabled; persistAndNotify(); if enabled { refresh(force: true) } }
    func setAutoAgentPets(_ enabled: Bool) { preferences.autoAgentPets = enabled; persistAndNotify() }
    func setProvider(_ id: String, enabled: Bool) {
        guard let index = preferences.providers.firstIndex(where: { $0.id == id }) else { return }
        preferences.providers[index].enabled = enabled; persistAndNotify(); if enabled { refresh(force: true) }
    }
    func setAllProviders(_ enabled: Bool) {
        for index in preferences.providers.indices { preferences.providers[index].enabled = enabled }
        persistAndNotify(); if enabled { refresh(force: true) }
    }
    func addProvider(name: String, backendProvider: String? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, preferences.providers.count < 100 else { return }
        preferences.providers.append(.init(id: "custom-" + UUID().uuidString.lowercased(), name: name, adapter: backendProvider == nil ? "snapshot" : "codexbar", backendProvider: backendProvider))
        persistAndNotify()
    }
    private func persistAndNotify() {
        do { try savePreferences() } catch { configurationError = true }
        if !preferences.showQuotas { refreshTask?.cancel(); refreshTask = nil; nativeRefreshTask?.cancel(); nativeRefreshTask = nil }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    var visibleProviders: [AIQuotaProvider] { preferences.showQuotas ? preferences.providers.filter(\.enabled) : [] }
    var sectionHeight: CGFloat {
        let providers = visibleProviders
        guard !providers.isEmpty else { return 0 }
        let content = providers.reduce(CGFloat.zero) { height, provider in
            let value = reading(for: provider)
            let activityHeight: CGFloat = activityTitle(provider.id) == nil ? 0 : 18
            guard value.state == "ready", value.isValid else { return height + 36 + activityHeight }
            let periods = CGFloat((value.windows.count + 1) / 2)
            let balance = value.balances.isEmpty ? CGFloat.zero : 32
            return height + 40 + periods * 36 + balance + activityHeight
        }
        return min(286, 34 + content + CGFloat(providers.count - 1) * 14)
    }
    func reading(for provider: AIQuotaProvider) -> AIQuotaReading {
        readings[provider.id] ?? .init(providerId: provider.id, state: "awaitingConnection")
    }
    func recordActivity(_ event: WhaleEvent) {
        if activity.ingest(event) { NotificationCenter.default.post(name: Self.changed, object: self) }
    }
    func activityTitle(_ id: String) -> String? { activity.title(for: id) }
    static func integrationDescription(_ provider: AIQuotaProvider) -> String {
        switch provider.adapter {
        case "nativeApp":
            if provider.id == "grok" { return "额度：当前 Grok Bot 未暴露可读取的用量数据，暂无法自动读取。桌面版完成事件尚未接通。" }
            return "额度：打开软件的用量限额页面后读取；关闭页面最多保留5分钟。桌面版完成事件尚未接通。"
        case "opencode": return "额度：OpenCode Go 官方接口；通知：OpenCode官方插件事件。其他提供商额度独立计算。"
        case "codex": return "额度：本机Codex app-server；通知：Codex原生Hook。"
        case "dsh": return "余额：本机DSH账号；通知与子代理：既有元数据观察桥。"
        case "snapshot": return "额度：自定义本地快照；通知：WhaleEvent接入。"
        default:
            if provider.id == "gemini-cli" { return "额度：Gemini CLI本机登录；通知：CLI官方事件，与Gemini桌面版分开。" }
            if provider.id == "grok-cli" { return "额度：Grok Build CLI账单状态；通知：CLI官方事件，与Grok Bot分开。" }
            return "额度：本机登录状态兼容读取，并非全部为公开API；通知：软件支持的官方事件。"
        }
    }
    func openNativeApp(_ id: String) {
        guard let url = NativeAppQuotaReader.applicationURL(id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
    func authorizeNativeReading() { NativeAppQuotaReader.requestAccess() }
    func installEventBridges() {
        guard !installingEventBridges, let script = Bundle.main.resourceURL?.appendingPathComponent("AIMonitor/ReplyHooks/install.py") else { return }
        installingEventBridges = true
        NotificationCenter.default.post(name: Self.changed, object: self)
        Task { [weak self] in
            let success = await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = [script.path]
                process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { return false }
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
                process.waitUntilExit(); timeout.cancel()
                return process.terminationStatus == 0
            }.value
            guard let self else { return }
            self.installingEventBridges = false
            self.bridgeInstallationMessage = success ? "已配置本机可用工具；请重载工具并确认其原生Hook许可。" : "部分设置未写入，请查看接入说明；未覆盖原有配置。"
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
    func showSettings() {
        if settingsWindow == nil { settingsWindow = AIMonitorSettingsWindow(store: self) }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private(set) var connectingProvider: String?
    func connectBrowser(_ id: String) {
        guard connectingProvider == nil, let provider = preferences.providers.first(where: { $0.id == id }),
              provider.adapter == "codexbar", let executable = Bundle.main.resourceURL?.appendingPathComponent("AIMonitor/CodexBarCLI") else { return }
        connectingProvider = id
        NotificationCenter.default.post(name: Self.changed, object: self)
        let backend = provider.backendProvider ?? provider.id
        Task { [weak self] in
            await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = executable
                process.arguments = ["cookie", "refresh", "--provider", backend, "--allow-keychain-prompt", "--json"]
                process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return }
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: watchdog)
                process.waitUntilExit(); watchdog.cancel()
            }.value
            guard let self else { return }
            self.connectingProvider = nil
            self.refresh(force: true)
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
    func refresh(force: Bool = false) {
        reloadPreferences()
        guard preferences.showQuotas, refreshTask == nil, force || Date().timeIntervalSince(lastRefresh) >= 5 else { return }
        lastRefresh = Date()
        let enabled = preferences.providers.filter(\.enabled)
        for provider in enabled where provider.adapter == "snapshot" {
            let url = provider.snapshotPath.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
                ?? directory.appendingPathComponent("AI额度").appendingPathComponent(provider.id + ".json")
            if let data = try? Data(contentsOf: url), data.count <= 1_048_576,
               let value = try? Self.decoder().decode(AIQuotaReading.self, from: data), value.providerId == provider.id, value.isValid {
                readings[provider.id] = value
            } else { readings[provider.id] = .init(providerId: provider.id, state: "awaitingConnection") }
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
        if nativeRefreshTask == nil {
            let native = enabled.filter { $0.adapter == "nativeApp" }
            nativeRefreshTask = Task { [weak self] in
                for provider in native {
                    let value = await NativeAppQuotaReader.read(provider.id)
                    guard !Task.isCancelled, let self else { return }
                    if value.state != "ready", var old = self.readings[provider.id], old.state == "ready" {
                        // Keep original timestamp: a closed pane must not make cached data look fresh.
                        if old.isStale(at: Date()) { old.state = value.state }
                        self.readings[provider.id] = old
                    } else { self.readings[provider.id] = value }
                }
                guard !Task.isCancelled, let self else { return }
                self.nativeRefreshTask = nil
                NotificationCenter.default.post(name: Self.changed, object: self)
            }
        }
        let adapters = enabled.filter { !["snapshot", "nativeApp"].contains($0.adapter) }
        guard !adapters.isEmpty, let script = Bundle.main.resourceURL?.appendingPathComponent("AIMonitor/whale_ai_usage.py") else { return }
        refreshTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { Self.runHelper(script: script, providers: adapters) }.value
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            struct Response: Decodable { let readings: [AIQuotaReading] }
            var received = Set<String>()
            if let data {
                for line in data.split(separator: 0x0A) {
                    guard let result = try? Self.decoder().decode(Response.self, from: Data(line)) else { continue }
                    for value in result.readings where value.isValid && adapters.contains(where: { $0.id == value.providerId }) {
                        self.readings[value.providerId] = value; received.insert(value.providerId)
                    }
                }
            }
            for provider in adapters where !received.contains(provider.id) {
                self.readings[provider.id] = .init(providerId: provider.id, state: "timeout")
            }
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
    nonisolated private static func runHelper(script: URL, providers: [AIQuotaProvider]) -> Data? {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard let request = try? JSONSerialization.data(withJSONObject: ["providers": providers.map { ["id": $0.id, "adapter": $0.adapter, "backendProvider": $0.backendProvider ?? $0.id] }]) else { return nil }
        do { try process.run() } catch { return nil }
        input.fileHandleForWriting.write(request); try? input.fileHandleForWriting.close()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); watchdog.cancel()
        return !data.isEmpty && data.count <= 131072 ? data : nil
    }
}
