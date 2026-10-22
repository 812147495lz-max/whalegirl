import Foundation
import WhaleCore

@MainActor
final class AgentCompanionController {
    private(set) var roster = AgentCompanionRoster(includeRoots: true)
    var onSpawn: ((String) -> Void)?
    var onFinished: ((String, Bool) -> Void)?
    var onThinking: ((String, String) -> Void)?
    private var nextThought: [String: Date] = [:]
    private var thinkingRoots: Set<String> = []
    var onResumed: ((String) -> Void)?
    private(set) var labels: [String: String] = [:]
    var onClose: ((String) -> Void)?
    private var timer: Timer?
    private var enabled = true
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if !value { closeAll() } else { roster = AgentCompanionRoster(includeRoots: true) }
    }
    func receive(_ event: WhaleEvent) {
        guard enabled else { return }
        let key = AgentCompanionRoster.key(for: event) ?? AgentCompanionRoster.rootKey(for: event)
        if let key, let label = AgentCompanionSpeech.safeLabel(event.metadata?["agentLabel"]) { labels[key] = label }
        if let key, key.hasPrefix("root|"), labels[key] == nil { labels[key] = ReplyCompletionTracker.providerName(for: event) }
        let wasRetiring = key.flatMap { roster.entries[$0]?.retireAt } != nil
        apply(roster.ingest(event, now: Date()))
        if let key, key.hasPrefix("root|"), let entry = roster.entries[key],
           entry.lastOccurredAt == event.occurredAt, entry.lastSequence == event.sequence, !entry.dismissed {
            if ["agent.working", "agent.tool_started"].contains(event.eventType) { thinkingRoots.insert(key) }
            else if ["agent.waiting_input", "agent.waiting_approval", "agent.turn_completed", "agent.session_completed", "agent.failed", "agent.interrupted", "agent.disconnected"].contains(event.eventType) {
                thinkingRoots.remove(key); nextThought[key] = nil
            } else if event.eventType == "agent.heartbeat", entry.retireAt == nil { thinkingRoots.insert(key) }
        }

        if let key, wasRetiring, let entry = roster.entries[key], entry.retireAt == nil, !entry.dismissed { onResumed?(key) }
        if roster.hasPendingWork, timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            timer.tolerance = 0.1; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func tick() {
        let now = Date()
        apply(roster.tick(now: now))
        nextThought = nextThought.filter { roster.entries[$0.key]?.dismissed == false && roster.entries[$0.key]?.retireAt == nil }
        for (key, entry) in roster.entries where thinkingRoots.contains(key) && !entry.dismissed && entry.retireAt == nil {
            if nextThought[key] == nil { nextThought[key] = now.addingTimeInterval(Double.random(in: 12...25)) }
            if let deadline = nextThought[key], now >= deadline {
                onThinking?(key, ["让我想一想…", "正在认真处理呢", "再梳理一下思路", "我还在忙，稍等呀"].randomElement()!)
                nextThought[key] = now.addingTimeInterval(Double.random(in: 12...25))
            }
        }
        if !roster.hasPendingWork { timer?.invalidate(); timer = nil }
    }
    private func apply(_ effects: [AgentCompanionRoster.Effect]) {
        for effect in effects {
            switch effect {
            case let .spawn(key): onSpawn?(key)
            case let .finished(key): onFinished?(key, true)
            case let .disconnected(key): onFinished?(key, false)
            case let .close(key): onClose?(key)
            }
        }
    }
    func dismiss(_ key: String) { roster.dismiss(key) }
    func closeAll() {
        let keys = roster.entries.filter { !$0.value.dismissed }.map(\.key)
        thinkingRoots.removeAll(); nextThought.removeAll()
        roster.dismissAll(); timer?.invalidate(); timer = nil
        for key in keys { onClose?(key) }
    }
}
