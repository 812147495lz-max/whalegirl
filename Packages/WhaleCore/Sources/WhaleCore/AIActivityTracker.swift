import Foundation

/// Provider-local observed event state. No inference from quota, process presence or CPU.
public struct AIActivityTracker: Sendable {
    private struct Signal: Sendable {
        let provider: String
        let event: String
        let at: Date
        let sequence: UInt64?
    }
    private var signals: [String: Signal] = [:]
    public init() {}
    @discardableResult public mutating func ingest(_ event: WhaleEvent, now: Date = Date()) -> Bool {
        guard event.parentSessionId == nil, let session = event.sessionId, !session.isEmpty,
              now.timeIntervalSince(event.occurredAt) >= -5, now.timeIntervalSince(event.occurredAt) <= 60,
              ["agent.working", "agent.session_started", "agent.turn_completed", "agent.disconnected", "agent.error", "agent.failed", "agent.cancelled", "agent.interrupted"].contains(event.eventType) else { return false }
        let provider: String
        switch event.source {
        case .codex: provider = "codex"
        case .dsh: provider = "dsh"
        case .remote:
            guard let id = event.metadata?["provider"], ["claude", "claudecc", "gemini-cli", "grok-cli", "gemini", "grok", "cursor", "copilot", "opencode"].contains(id) else { return false }
            provider = id == "claude" ? "claudecc" : id
        default: return false
        }
        let key = provider + "|" + event.sourceInstance + "|" + session
        if let old = signals[key] {
            guard event.occurredAt >= old.at else { return false }
            if let a = old.sequence, let b = event.sequence, b <= a { return false }
        }
        signals[key] = Signal(provider: provider, event: event.eventType, at: event.occurredAt, sequence: event.sequence)
        if signals.count > 1024 { for entry in signals.sorted(by: { $0.value.at < $1.value.at }).prefix(256) { signals[entry.key] = nil } }
        return true
    }
    public func title(for provider: String, now: Date = Date()) -> String? {
        let matching = signals.values.filter { $0.provider == provider }
        guard let latest = matching.max(by: { $0.at < $1.at }) else { return nil }
        let fresh = matching.filter { now.timeIntervalSince($0.at) <= 300 }
        guard !fresh.isEmpty else { return "事件状态已过期" }
        let busy = fresh.filter { ["agent.working", "agent.session_started"].contains($0.event) }.count
        if busy > 0 { return "正在运行 · \(busy)个会话" }
        return switch latest.event {
        case "agent.turn_completed": "本轮回复已结束"
        case "agent.disconnected": "事件连接中断"
        case "agent.cancelled", "agent.interrupted": "本轮已取消"
        default: "本轮出现错误"
        }
    }
}
