import Foundation

/// Parses only the already-visible Usage settings surface; never estimates quota from messages or activity.
public enum NativeQuotaText {
    private static func remaining(in text: String) -> Double? {
        let patterns = [
            (#"(?:已使用|已用|used)\s*([0-9]+(?:\.[0-9]+)?)\s*%"#, false),
            (#"([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:used|已使用|已用)"#, false),
            (#"(?:剩余|remaining)\s*([0-9]+(?:\.[0-9]+)?)\s*%"#, true),
            (#"([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:remaining|left)"#, true)
        ]
        for (pattern, isRemaining) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text), let value = Double(text[range]),
                  value.isFinite, (0...100).contains(value) else { continue }
            return isRemaining ? value : 100 - value
        }
        return nil
    }
    private static func section(_ text: String, after pattern: String, before end: String? = nil) -> String? {
        guard let start = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        var result = String(text[start.upperBound...].prefix(1200))
        if let end, let stop = result.range(of: end, options: [.regularExpression, .caseInsensitive]) { result = String(result[..<stop.lowerBound]) }
        return result
    }
    public static func reading(provider: String, text: String, now: Date = Date()) -> AIQuotaReading {
        var windows: [AIQuotaWindow] = []
        if provider == "gemini" {
            if let current = section(text, after: "当前用量|Current usage", before: "每周限额|Weekly limit"), let value = remaining(in: current) {
                // The UI labels this Current usage, not a guaranteed duration. Preserve its wording.
                windows.append(.init(durationSeconds: 0, remainingPercent: value, periodLabel: "当前额度"))
            }
            if let weekly = section(text, after: "每周限额|Weekly limit", before: "高级设置|Advanced settings"), let value = remaining(in: weekly) {
                windows.append(.init(durationSeconds: 604800, remainingPercent: value))
            }
        } else if provider == "grok", let weekly = section(text, after: "每周用量|每周使用量|Weekly usage", before: "按需|On.demand"), let value = remaining(in: weekly) {
            windows.append(.init(durationSeconds: 604800, remainingPercent: value))
        }
        return .init(providerId: provider, state: windows.isEmpty ? "nativeUnavailable" : "ready", fetchedAt: now, windows: windows)
    }
}
