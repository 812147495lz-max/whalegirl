import Foundation

public struct AIQuotaWindow: Codable, Equatable, Sendable {
    public var durationSeconds: Int
    public var remainingPercent: Double
    public var resetsAt: Date?
    public var bucket: String?
    public var periodLabel: String?
    public init(durationSeconds: Int, remainingPercent: Double, resetsAt: Date? = nil, bucket: String? = nil, periodLabel: String? = nil) {
        self.durationSeconds = durationSeconds; self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt; self.bucket = bucket; self.periodLabel = periodLabel
    }
    public var isValid: Bool { (durationSeconds > 0 || (durationSeconds == 0 && !(periodLabel ?? "").isEmpty)) && durationSeconds <= 366 * 86400 && (periodLabel?.count ?? 0) <= 60 && remainingPercent.isFinite && (0...100).contains(remainingPercent) }
    public var periodTitle: String {
        if durationSeconds == 0 { return periodLabel ?? "额度" }
        if durationSeconds == 604800 { return "周" }
        if durationSeconds % 86400 == 0 { return "\(durationSeconds / 86400)天" }
        if durationSeconds % 3600 == 0 { return "\(durationSeconds / 3600)小时" }
        return "\(durationSeconds / 60)分钟"
    }
}

public struct AIQuotaBalance: Codable, Equatable, Sendable {
    public var currency: String
    public var amount: String
    public var bonusAmount: String?
    public init(currency: String, amount: String, bonusAmount: String? = nil) {
        self.currency = currency; self.amount = amount; self.bonusAmount = bonusAmount
    }
    public var isValid: Bool {
        guard currency.count <= 12, !currency.isEmpty else { return false }
        return [amount, bonusAmount].compactMap { $0 }.allSatisfy {
            $0.count <= 64 && $0.range(of: #"^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil
                && Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) != nil
        }
    }
}

public struct AIQuotaReading: Codable, Equatable, Sendable {
    public var providerId: String
    public var state: String
    public var fetchedAt: Date
    public var windows: [AIQuotaWindow]
    public var balances: [AIQuotaBalance]
    public init(providerId: String, state: String, fetchedAt: Date = Date(), windows: [AIQuotaWindow] = [], balances: [AIQuotaBalance] = []) {
        self.providerId = providerId; self.state = state; self.fetchedAt = fetchedAt; self.windows = windows; self.balances = balances
    }
    public var isValid: Bool { windows.count <= 30 && balances.count <= 10 && windows.allSatisfy(\.isValid) && balances.allSatisfy(\.isValid) }
    public func isStale(at now: Date) -> Bool { now.timeIntervalSince(fetchedAt) > 300 || fetchedAt.timeIntervalSince(now) > 60 }
    public var statusTitle: String {
        switch state {
        case "ready": return "已更新"
        case "signInRequired": return "需要登录"
        case "notInstalled": return "未安装"
        case "unsupported": return "未提供此额度"
        case "invalidData": return "数据格式异常"
        case "timeout": return "读取超时"
        case "awaitingConnection": return "未接入"
        case "authenticationFailed": return "登录凭据未通过验证"
        case "accessibilityRequired": return "需辅助功能授权"
        case "usageViewRequired": return "请打开软件用量页面"
        case "appNotRunning": return "软件未运行"
        case "nativeUnavailable": return "软件未提供可读取数据"
        case "browserConnectionRequired": return "需连接浏览器会话"
        default: return "暂时无法读取"
        }
    }
}

public struct AIQuotaProvider: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var adapter: String
    public var snapshotPath: String?
    public var backendProvider: String?
    public init(id: String, name: String, enabled: Bool = true, adapter: String = "snapshot", snapshotPath: String? = nil, backendProvider: String? = nil) {
        self.id = id; self.name = name; self.enabled = enabled; self.adapter = adapter; self.snapshotPath = snapshotPath; self.backendProvider = backendProvider
    }
    public var isValid: Bool {
        !id.isEmpty && id.count <= 80 && id.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
            && !name.isEmpty && name.count <= 60 && ["codex", "dsh", "snapshot", "codexbar", "nativeApp", "opencode"].contains(adapter)
            && (backendProvider == nil || backendProvider!.range(of: #"^[a-z0-9-]{1,60}$"#, options: .regularExpression) != nil)
    }
}

public struct AIMonitorPreferences: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var showQuotas = true
    public var autoAgentPets = true
    public var providers: [AIQuotaProvider]
    public init(providers: [AIQuotaProvider]) { self.providers = providers }
    public static let defaults = AIMonitorPreferences(providers: [
        .init(id: "codex", name: "Codex", adapter: "codex"),
        .init(id: "dsh", name: "DeepSeek Harness", adapter: "dsh"),
        .init(id: "gemini", name: "Gemini 桌面版", adapter: "nativeApp"), .init(id: "grok", name: "Grok Bot", adapter: "nativeApp"),
        .init(id: "claudecc", name: "Claude Code", adapter: "codexbar", backendProvider: "claude"), .init(id: "cursor", name: "Cursor", adapter: "codexbar"),
        .init(id: "copilot", name: "GitHub Copilot", adapter: "codexbar"), .init(id: "opencode", name: "OpenCode Go", adapter: "opencode"),
        .init(id: "gemini-cli", name: "Gemini CLI", enabled: false, adapter: "codexbar", backendProvider: "gemini"),
        .init(id: "grok-cli", name: "Grok Build CLI", enabled: false, adapter: "codexbar", backendProvider: "grok")
    ])
    public var isValid: Bool { schemaVersion == 1 && providers.count <= 100 && providers.allSatisfy(\.isValid) && Set(providers.map(\.id)).count == providers.count }
    /// Migrate only known built-in sources; preserve switches, custom backends and explicit snapshots.
    public mutating func migrateDesktopSources() -> Bool {
        var changed = false
        for index in providers.indices where providers[index].adapter == "codexbar" && providers[index].snapshotPath == nil {
            let id = providers[index].id
            guard ["gemini", "grok", "opencode"].contains(id), providers[index].backendProvider == nil || providers[index].backendProvider == id else { continue }
            providers[index].adapter = id == "opencode" ? "opencode" : "nativeApp"
            providers[index].name = id == "gemini" ? "Gemini 桌面版" : id == "grok" ? "Grok Bot" : "OpenCode Go"
            providers[index].backendProvider = nil; changed = true
        }
        for provider in Self.defaults.providers where ["gemini-cli", "grok-cli"].contains(provider.id) && !providers.contains(where: { $0.id == provider.id }) && providers.count < 100 {
            providers.append(provider); changed = true
        }
        return changed
    }
}

/// Idempotent metadata-only subagent roster. Parent/root turns never create companions.
public struct AgentCompanionRoster: Sendable {
    public struct Entry: Sendable {
        public var lastSeen: Date
        public var retireAt: Date?
        public var lastOccurredAt: Date
        public var lastSequence: UInt64?
        public var expectsHeartbeat: Bool
        public var dismissed = false
    }
    public enum Effect: Equatable, Sendable { case spawn(String), finished(String), disconnected(String), close(String) }
    public private(set) var entries: [String: Entry] = [:]
    public let retirementSeconds: TimeInterval
    public let leaseSeconds: TimeInterval
    private let randomRetirement: Bool
    private let includeRoots: Bool
    public init(retirementSeconds: TimeInterval? = nil, leaseSeconds: TimeInterval = 900, includeRoots: Bool = false) {
        self.retirementSeconds = retirementSeconds ?? 20; self.leaseSeconds = leaseSeconds
        randomRetirement = retirementSeconds == nil
        self.includeRoots = includeRoots
    }
    private func retirementDelay() -> TimeInterval { randomRetirement ? Double.random(in: 10...20) : retirementSeconds }
    public static func key(for event: WhaleEvent) -> String? {
        guard let id = event.sessionId, !id.isEmpty, let parent = event.parentSessionId,
              !parent.isEmpty, parent != id else { return nil }
        return "\(event.source.rawValue)|\(event.sourceInstance)|\(id)"
    }
    public static func rootKey(for event: WhaleEvent) -> String? {
        guard let id = event.sessionId, !id.isEmpty,
              event.parentSessionId == nil || event.parentSessionId == "" || event.parentSessionId == id,
              event.source == .codex || event.source == .dsh ||
                (event.source == .remote && ReplyCompletionTracker.providerName(for: event) != nil) else { return nil }
        return "root|\(event.source.rawValue)|\(event.sourceInstance)|\(id)"
    }
    public mutating func ingest(_ event: WhaleEvent, now: Date) -> [Effect] {
        let childKey = Self.key(for: event)
        let isRoot = childKey == nil
        guard let key = childKey ?? (includeRoots ? Self.rootKey(for: event) : nil) else { return [] }
        if isRoot, entries[key] == nil {
            guard (["agent.working", "agent.tool_started"].contains(event.eventType) ||
                    (event.eventType == "agent.heartbeat" && event.source == .dsh && event.metadata?["client"] == "dsh-whale-status")),
                  (-5...60).contains(now.timeIntervalSince(event.occurredAt)) else { return [] }
        }
        if isRoot, entries[key]?.retireAt != nil, event.eventType == "agent.session_started" { return [] }
        let terminal = ["agent.session_completed", "agent.turn_completed", "agent.failed", "agent.interrupted", "agent.disconnected"].contains(event.eventType)
        let active = ["agent.session_started", "agent.working", "agent.tool_started", "agent.tool_finished", "agent.waiting_input", "agent.waiting_approval", "agent.heartbeat"].contains(event.eventType)
        guard terminal || active else { return [] }
        if let previous = entries[key] {
            if event.occurredAt < previous.lastOccurredAt { return [] }
            if let old = previous.lastSequence, let next = event.sequence, next <= old { return [] }
        }
        if terminal {
            if entries[key] == nil {
                // A short child may finish before the reconnect heartbeat after app startup.
                // Only our DSH observer may recover a fresh terminal event, never historical runs.
                let age = now.timeIntervalSince(event.occurredAt)
                guard event.source == .dsh, event.metadata?["client"] == "dsh-whale-status",
                      age >= -5, age < retirementSeconds else { return [] }
                let deadline = event.occurredAt.addingTimeInterval(retirementDelay())
                guard deadline > now else { return [] }
                entries[key] = Entry(lastSeen: now, retireAt: deadline,
                    lastOccurredAt: event.occurredAt, lastSequence: event.sequence, expectsHeartbeat: true)
                return [.spawn(key), event.eventType == "agent.disconnected" ? .disconnected(key) : .finished(key)]
            }
            guard var entry = entries[key], entry.retireAt == nil, !entry.dismissed else { return [] }
            entry.lastSeen = now; entry.lastOccurredAt = event.occurredAt; entry.lastSequence = event.sequence
            entry.retireAt = event.occurredAt.addingTimeInterval(retirementDelay())
            if entry.retireAt! <= now { entry.dismissed = true; entries[key] = entry; return [.close(key)] }
            entries[key] = entry
            return [event.eventType == "agent.disconnected" ? .disconnected(key) : .finished(key)]
        }
        if var entry = entries[key] {
            // Heartbeats arriving after completion cannot revive a finished child.
            if entry.retireAt != nil && event.eventType != "agent.working" && event.eventType != "agent.session_started" { return [] }
            if entry.dismissed {
                guard entry.retireAt != nil, ["agent.working", "agent.session_started"].contains(event.eventType),
                      event.occurredAt > entry.lastOccurredAt else { return [] }
                entries[key] = Entry(lastSeen: now, lastOccurredAt: event.occurredAt, lastSequence: event.sequence, expectsHeartbeat: event.source == .dsh)
                return [.spawn(key)]
            }
            entry.lastSeen = now; entry.lastOccurredAt = event.occurredAt; entry.lastSequence = event.sequence; entry.retireAt = nil
            entries[key] = entry
            return []
        }
        // Old terminal messages/late heartbeats cannot conjure historical agents.
        guard (event.eventType != "agent.heartbeat" || (event.source == .dsh && event.metadata?["client"] == "dsh-whale-status")),
              now.timeIntervalSince(event.occurredAt) <= leaseSeconds else { return [] }
        entries[key] = Entry(lastSeen: now, lastOccurredAt: event.occurredAt, lastSequence: event.sequence, expectsHeartbeat: event.source == .dsh)
        return [.spawn(key)]
    }
    public mutating func tick(now: Date) -> [Effect] {
        var effects: [Effect] = []
        for key in Array(entries.keys) {
            guard var entry = entries[key] else { continue }
            if entry.dismissed { continue }
            if let deadline = entry.retireAt {
                if now >= deadline { entry.dismissed = true; entries[key] = entry; effects.append(.close(key)) }
            } else if entry.expectsHeartbeat && now.timeIntervalSince(entry.lastSeen) >= leaseSeconds {
                entry.retireAt = now.addingTimeInterval(retirementDelay()); entries[key] = entry; effects.append(.disconnected(key))
            }
        }
        return effects
    }
    public mutating func dismiss(_ key: String) { entries[key]?.dismissed = true }
    public mutating func dismissAll() { for key in Array(entries.keys) { dismiss(key) } }
    public var hasPendingWork: Bool { entries.values.contains { !$0.dismissed } }
}

/// Root reply completion only. Child activity already has its own companion UI.
public struct ReplyCompletionTracker: Sendable {
    private struct Entry: Sendable {
        var occurredAt: Date
        var sequence: UInt64?
        var completed: Bool
    }
    private var entries: [String: Entry] = [:]
    public init() {}
    public static func providerName(for event: WhaleEvent) -> String? {
        if event.source == .codex { return "Codex" }
        if event.source == .dsh { return "DeepSeek Harness" }
        guard event.source == .remote else { return nil }
        let names = ["claude": "Claude Code", "claudecc": "Claude Code", "claude-code": "Claude Code",
                     "gemini-cli": "Gemini CLI", "grok-cli": "Grok Build CLI",
                     "gemini": "Gemini", "grok": "Grok", "cursor": "Cursor", "copilot": "GitHub Copilot",
                     "opencode": "OpenCode", "antigravity": "Antigravity", "windsurf": "Windsurf"]
        if let provider = event.metadata?["provider"]?.lowercased() {
            if let name = names[provider] { return name }
            if provider.range(of: #"^[a-z0-9][a-z0-9_.-]{0,39}$"#, options: .regularExpression) != nil { return provider }
        }
        if event.metadata?["client"] == "claude-code-hook" { return "Claude Code" }
        return nil
    }
    public mutating func ingest(_ event: WhaleEvent, now: Date = Date()) -> String? {
        guard event.parentSessionId == nil, let id = event.sessionId, !id.isEmpty,
              let name = Self.providerName(for: event) else { return nil }
        let age = now.timeIntervalSince(event.occurredAt)
        guard age >= -5, age <= 60 else { return nil }
        let key = "\(event.source.rawValue)|\(event.sourceInstance)|\(id)"
        if let entry = entries[key] {
            if event.occurredAt < entry.occurredAt { return nil }
            if let old = entry.sequence, let new = event.sequence, new <= old { return nil }
        }
        let completed = event.eventType == "agent.turn_completed"
        let active = ["agent.working", "agent.session_started"].contains(event.eventType)
        guard completed || active else { return nil }
        if completed, entries[key]?.completed == true { return nil }
        // A delayed start in the same second cannot rearm an already completed turn without a sequence.
        if active, let previous = entries[key], previous.completed,
           event.sequence == nil && event.occurredAt <= previous.occurredAt { return nil }
        entries[key] = Entry(occurredAt: event.occurredAt, sequence: event.sequence, completed: completed)
        if entries.count > 2048 {
            let oldest = entries.sorted { $0.value.occurredAt < $1.value.occurredAt }.prefix(512).map(\.key)
            for key in oldest { entries.removeValue(forKey: key) }
        }
        return completed ? name : nil
    }
}


/// Public task labels only, never infer successful work from an agent's output or idle status.
public enum AgentCompanionSpeech {
    public static func safeLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty, !text.contains("/"), !text.contains("\\"), !text.contains("@"),
              text.range(of: #"(?i)(bearer|password|secret|sk-[a-z0-9]|api[_-]?key)"#, options: .regularExpression) == nil else { return nil }
        let clean = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }
        return String(String.UnicodeScalarView(clean).prefix(40))
    }
    public static func introduction(id: String, label: String?) -> String {
        let shortID = String(id.prefix(16))
        return "子代理 \(shortID) 报到" + (safeLabel(label).map { "，负责" + $0 } ?? "")
    }
    public static func ending(label: String?, disconnected: Bool = false) -> String {
        if disconnected { return "连接断开先告退" }
        guard let label = safeLabel(label) else { return "这轮工作结束了" }
        return String(label.prefix(8)) + "结束"
    }
}
