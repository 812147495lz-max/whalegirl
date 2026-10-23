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
    private var dshCompanionActive = false
    private var recovery = CodexQuotaRecoveryTracker()
    var onQuotaRecovered: ((String) -> Void)?
    var recoveryNotificationsEnabled: Bool { UserDefaults.standard.object(forKey: "notifyCodexQuotaRecovery.v1") as? Bool ?? true }
    var quotaGaugesEnabled: Bool { UserDefaults.standard.object(forKey: "quotaGauges.enabled.v1") as? Bool ?? true }
    var dshGaugeMaximum: Double {
        let value = UserDefaults.standard.object(forKey: "quotaGauges.dshMaximum.v1") as? Double ?? 50
        return value.isFinite && (0.01...1_000_000).contains(value) ? value : 50
    }
    func setQuotaGaugesEnabled(_ value: Bool) {
        guard value != quotaGaugesEnabled else { return }
        UserDefaults.standard.set(value, forKey: "quotaGauges.enabled.v1")
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    func setDSHGaugeMaximum(_ value: Double) {
        guard value.isFinite, (0.01...1_000_000).contains(value), value != dshGaugeMaximum else { return }
        UserDefaults.standard.set(value, forKey: "quotaGauges.dshMaximum.v1")
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    private var settingsWindow: AIMonitorSettingsWindow?
    private(set) var installingEventBridges = false
    private(set) var bridgeInstallationMessage: String?

    init(directory: URL? = nil) {
        self.directory = directory ?? WhaleGirlUserFiles.directory
        preferences = .defaults
        reloadPreferences()
        let state = self.directory.appendingPathComponent("codex-quota-recovery-state.json")
        if let data = try? Data(contentsOf: state), data.count < 32768, let tracker = try? JSONDecoder().decode(CodexQuotaRecoveryTracker.self, from: data) { recovery = tracker }
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
    func setShowQuotas(_ enabled: Bool) { preferences.showQuotas = enabled; persistAndNotify(); if enabled || recoveryNotificationsEnabled { refresh(force: true) } }
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
        if !preferences.showQuotas && !dshCompanionActive && !recoveryNotificationsEnabled { refreshTask?.cancel(); refreshTask = nil; nativeRefreshTask?.cancel(); nativeRefreshTask = nil }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    var visibleProviders: [AIQuotaProvider] { preferences.showQuotas ? preferences.providers.filter(\.enabled) : [] }
    var sectionHeight: CGFloat { AIQuotaSectionView.preferredHeight(store: self) }
    func reading(for provider: AIQuotaProvider) -> AIQuotaReading {
        readings[provider.id] ?? .init(providerId: provider.id, state: "awaitingConnection")
    }
    func setRecoveryNotifications(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "notifyCodexQuotaRecovery.v1")
        if value { refresh(force: true) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    private func accept(_ value: AIQuotaReading) {
        readings[value.providerId] = value
        guard value.providerId == "codex", value.state == "ready", value.isValid, !value.isStale(at: Date()) else { return }
        let recovered = recovery.ingest(value)
        if let data = try? JSONEncoder().encode(recovery) { try? data.write(to: directory.appendingPathComponent("codex-quota-recovery-state.json"), options: .atomic) }
        if !recovered.isEmpty, recoveryNotificationsEnabled {
            let windows = recovered.map { $0.periodTitle + String(format: " %.0f%%", $0.remainingPercent) }.joined(separator: " · ")
            onQuotaRecovered?("Codex 额度已恢复\n" + windows)
        }
    }
    func quotaForCompletion(_ event: WhaleEvent) async -> String {
        refresh(force: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while refreshTask != nil, ContinuousClock.now < deadline, !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        let id: String
        switch event.source {
        case .codex: id = "codex"
        case .dsh: id = "dsh"
        default:
            let raw = event.metadata?["provider"]?.lowercased() ?? ""
            id = ["claude": "claudecc", "claude-code": "claudecc", "gemini": "gemini", "grok": "grok" ][raw] ?? raw
        }
        guard let value = readings[id], !value.isStale(at: Date()), let summary = value.remainingSummary else { return "额度暂不可用" }
        return (value.fetchedAt < event.occurredAt ? "上次剩余 " : "剩余 ") + summary
    }
    func setDSHCompanionActive(_ active: Bool) {
        guard dshCompanionActive != active else { return }
        dshCompanionActive = active
        if active { refresh(force: true) }
    }
    func refreshDSHPriceIfNeeded() {
        if dshCompanionActive, let next = readings["dsh"]?.dshCostStatus?.nextSwitchAt,
           next <= Date(), Date().timeIntervalSince(lastRefresh) >= 10 { refresh(force: true) }
    }
    var dshCompanionText: String {
        let now = Date()
        guard let reading = readings["dsh"], !reading.isStale(at: now) else {
            return "余额读取中…\n今日已用 —\n峰谷价 —"
        }
        let balance = reading.remainingSummary.map { "余额 " + $0 } ?? "余额暂不可用"
        guard let cost = reading.dshCostStatus, cost.isValid else { return balance + "\n今日已用 —\n峰谷价 —" }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"; day.timeZone = TimeZone(identifier: "Asia/Shanghai")
        var spent = "今日已用 —"
        if cost.day == day.string(from: now), cost.usageSource == "balance-observed", let amount = cost.todayAmount {
            let number = NumberFormatter(); number.numberStyle = .decimal; number.minimumFractionDigits = 2; number.maximumFractionDigits = 2
            let symbol = cost.currency == "CNY" ? "¥" : cost.currency == "USD" ? "$" : "€"
            spent = "今日已用 " + symbol + (number.string(from: NSDecimalNumber(string: amount, locale: Locale(identifier: "en_US_POSIX"))) ?? amount)
            if cost.partialDay == true { spent += "（部分）" }
            if cost.needsReview == true { spent += " · 待核对" }
        }
        var price: String
        switch cost.pricePhase {
        case "peak": price = "当前峰价"
        case "offPeak": price = "当前谷价"
        case "disabled": price = "峰谷计价未启用"
        default: price = "峰谷价暂不可用"
        }
        if let next = cost.nextSwitchAt, ["peak", "offPeak"].contains(cost.pricePhase) {
            if next <= now { price = "峰谷价更新中…" }
            else {
                price += " · 还有" + QuotaTimeText.remaining(until: next, now: now) + (cost.pricePhase == "peak" ? "转谷" : "转峰")
            }
        }
        return [balance, spent, price].joined(separator: "\n")
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
        guard preferences.showQuotas || recoveryNotificationsEnabled || dshCompanionActive, refreshTask == nil, force || Date().timeIntervalSince(lastRefresh) >= 5 else { return }
        lastRefresh = Date()
        let enabled = preferences.providers.filter { (preferences.showQuotas && $0.enabled) || (recoveryNotificationsEnabled && $0.id == "codex") || (dshCompanionActive && $0.id == "dsh") }
        for provider in enabled where provider.adapter == "snapshot" {
            let url = provider.snapshotPath.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
                ?? directory.appendingPathComponent("AI额度").appendingPathComponent(provider.id + ".json")
            if let data = try? Data(contentsOf: url), data.count <= 1_048_576,
               let value = try? Self.decoder().decode(AIQuotaReading.self, from: data), value.providerId == provider.id, value.isValid {
                accept(value)
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
        let accountingPath = directory.appendingPathComponent("dsh-balance-observations-v1.json")
        refreshTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { Self.runHelper(script: script, providers: adapters, accountingPath: accountingPath) }.value
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            struct Response: Decodable { let readings: [AIQuotaReading] }
            var received = Set<String>()
            if let data {
                for line in data.split(separator: 0x0A) {
                    guard let result = try? Self.decoder().decode(Response.self, from: Data(line)) else { continue }
                    for value in result.readings where value.isValid && adapters.contains(where: { $0.id == value.providerId }) {
                        self.accept(value); received.insert(value.providerId)
                    }
                }
            }
            for provider in adapters where !received.contains(provider.id) {
                self.readings[provider.id] = .init(providerId: provider.id, state: "timeout")
            }
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
    nonisolated private static func runHelper(script: URL, providers: [AIQuotaProvider], accountingPath: URL) -> Data? {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard let request = try? JSONSerialization.data(withJSONObject: ["providers": providers.map { ["id": $0.id, "adapter": $0.adapter, "backendProvider": $0.backendProvider ?? $0.id] }, "dshAccountingPath": accountingPath.path]) else { return nil }
        do { try process.run() } catch { return nil }
        input.fileHandleForWriting.write(request); try? input.fileHandleForWriting.close()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); watchdog.cancel()
        return !data.isEmpty && data.count <= 131072 ? data : nil
    }
}
