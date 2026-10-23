import Foundation

/// Records only observed quota windows, never infers a reset from the clock alone.
public struct CodexQuotaRecoveryTracker: Codable, Sendable {
    private struct Entry: Codable, Sendable {
        var percent: Double
        var resetsAt: Date?
        var fetchedAt: Date
        var notifiedReset: Date?
    }
    private var entries: [String: Entry] = [:]
    public init() {}
    public mutating func ingest(_ reading: AIQuotaReading, now: Date = Date()) -> [AIQuotaWindow] {
        guard reading.providerId == "codex", reading.state == "ready", reading.isValid, !reading.isStale(at: now) else { return [] }
        var recovered: [AIQuotaWindow] = []
        for window in reading.windows {
            let key = "\(window.durationSeconds)|\(window.bucket ?? "")|\(window.periodLabel ?? "")"
            let old = entries[key]
            guard old.map({ reading.fetchedAt > $0.fetchedAt }) ?? true else { continue }
            var next = Entry(percent: window.remainingPercent, resetsAt: window.resetsAt, fetchedAt: reading.fetchedAt, notifiedReset: old?.notifiedReset)
            if let old {
                let increased = window.remainingPercent > old.percent + 0.5
                let advanced = old.resetsAt.flatMap { previous in
                    window.resetsAt.map { $0.timeIntervalSince(previous) > 1 && now >= previous.addingTimeInterval(-5) }
                } ?? false
                let availableAgain = old.percent <= 0.1 && window.remainingPercent > 0.5
                let alreadyNotified = window.resetsAt != nil && old.notifiedReset == window.resetsAt
                if increased && (advanced || availableAgain) && !alreadyNotified {
                    recovered.append(window); next.notifiedReset = window.resetsAt
                }
            }
            entries[key] = next
        }
        if entries.count > 64 { entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(32).map { ($0.key, $0.value) }) }
        return recovered
    }
}

public extension AIQuotaReading {
    var remainingSummary: String? {
        guard state == "ready", isValid else { return nil }
        if !windows.isEmpty {
            return windows.prefix(3).map { window in
                window.periodTitle + (window.bucket.map { " · " + String($0.prefix(18)) } ?? "") + String(format: " %.0f%%", window.remainingPercent)
            }.joined(separator: " · ")
        }
        if !balances.isEmpty {
            return balances.prefix(2).map { balance in
                let prefix = balance.currency == "CNY" ? "¥" : balance.currency == "USD" ? "$" : balance.currency + " "
                let formatter = NumberFormatter(); formatter.numberStyle = .decimal
                formatter.maximumFractionDigits = 4; formatter.minimumFractionDigits = 2
                let value = NSDecimalNumber(string: balance.amount, locale: Locale(identifier: "en_US_POSIX"))
                return prefix + (formatter.string(from: value) ?? balance.amount)
            }.joined(separator: " · ")
        }
        return nil
    }
}
