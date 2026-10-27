import AppKit
import WhaleCore

/// Only projected usage metadata is decoded. Unknown values remain nil all the way to CSV.
struct UsageReportRecord: Decodable, Identifiable, Sendable {
    let id: String
    let source: String
    let session: String
    let occurredAt: Date
    let model: String?
    let inputTokens: Int64?
    let outputTokens: Int64?
    let cachedInputTokens: Int64?
    let uncachedInputTokens: Int64?
    let cacheWriteTokens: Int64?
    let reasoningTokens: Int64?
    let costAmount: String?
    let currency: String?
    let costKind: String
    let costBasis: String?
    let granularity: String?

    var sourceTitle: String { source == "dsh" ? "DSH" : "Codex" }
    var decimalCost: Decimal? {
        guard costKind == "reported" || costKind == "estimated", let costAmount, let currency,
              currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
              costAmount.range(of: "^[0-9]{1,20}(\\.[0-9]{1,30})?$", options: .regularExpression) != nil,
              costAmount.filter({ $0 != "." }).count <= 32
        else { return nil }
        return Decimal(string: costAmount, locale: Locale(identifier: "en_US_POSIX"))
    }
    var costText: String {
        guard decimalCost != nil, let costAmount, let currency else { return "费用未提供" }
        if costKind == "estimated", currency == "CNY", costBasis?.hasPrefix("DeepSeek官方价") == true {
            return "官方价估算 ¥" + costAmount
        }
        return (costKind == "estimated" ? "估算 " : "实报 ") + currency + " " + costAmount
    }
    var bubbleText: String {
        let unit = granularity == "turn" ? "本轮" : "本次"
        return "\(sourceTitle) \(unit)用量\n输入 \(Self.token(inputTokens)) · 输出 \(Self.token(outputTokens))\n缓存命中 \(Self.token(cachedInputTokens)) · 未命中 \(Self.token(uncachedInputTokens))\n\(costText)"
    }
    static func token(_ value: Int64?) -> String { value.map(String.init) ?? "—" }
    private enum CodingKeys: String, CodingKey {
        case id, source, session, occurredAt, model, inputTokens, outputTokens, cachedInputTokens
        case uncachedInputTokens, cacheWriteTokens, reasoningTokens, costAmount, currency, costKind, costBasis, granularity
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(String.self, forKey: .source)
        session = try c.decode(String.self, forKey: .session)
        let timestamp = try c.decode(String.self, forKey: .occurredAt)
        let iso = ISO8601DateFormatter()
        iso.formatOptions.insert(.withFractionalSeconds)
        let date = iso.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        guard let date, ["codex", "dsh"].contains(source), !id.isEmpty, id.count <= 256,
              session.count <= 256 else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Invalid usage metadata")
        }
        occurredAt = date
        model = try c.decodeIfPresent(String.self, forKey: .model).map { String($0.prefix(160)) }
        func count(_ key: CodingKeys) -> Int64? {
            guard let number = try? c.decode(Int64.self, forKey: key), number >= 0 else { return nil }
            return number
        }
        inputTokens = count(.inputTokens); outputTokens = count(.outputTokens)
        cachedInputTokens = count(.cachedInputTokens); uncachedInputTokens = count(.uncachedInputTokens)
        cacheWriteTokens = count(.cacheWriteTokens); reasoningTokens = count(.reasoningTokens)
        costAmount = try c.decodeIfPresent(String.self, forKey: .costAmount)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        costKind = try c.decodeIfPresent(String.self, forKey: .costKind) ?? "unavailable"
        costBasis = try c.decodeIfPresent(String.self, forKey: .costBasis).map { String($0.prefix(256)) }
        granularity = try c.decodeIfPresent(String.self, forKey: .granularity)
    }
}

struct UsageReportSummary {
    struct TokenTotal {
        var total = Decimal.zero
        var known = 0
        mutating func add(_ value: Int64?) {
            if let value { total += Decimal(value); known += 1 }
        }
        func text(count: Int) -> String {
            guard known > 0 else { return "—（未提供）" }
            let number = NSDecimalNumber(decimal: total).stringValue
            return known == count ? number : number + "（\(count - known) 条未知）"
        }
    }
    var input = TokenTotal(), output = TokenTotal(), cached = TokenTotal(), uncached = TokenTotal()
    var reported: [String: Decimal] = [:], estimated: [String: Decimal] = [:]
    var missingCosts = 0
    init(_ records: [UsageReportRecord]) {
        for record in records {
            input.add(record.inputTokens); output.add(record.outputTokens)
            cached.add(record.cachedInputTokens); uncached.add(record.uncachedInputTokens)
            if let cost = record.decimalCost, let currency = record.currency {
                if record.costKind == "reported" { reported[currency, default: .zero] += cost }
                else { estimated[currency, default: .zero] += cost }
            } else { missingCosts += 1 }
        }
    }
    static func money(_ amounts: [String: Decimal]) -> String {
        amounts.isEmpty ? "—" : amounts.keys.sorted().map { $0 + " " + NSDecimalNumber(decimal: amounts[$0]!).stringValue }.joined(separator: " · ")
    }
}

enum UsageReportCSV {
    static func cell(_ value: String) -> String {
        // Quote for RFC 4180, and neutralize spreadsheet formulas even after whitespace.
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let unsafe = first.map { "=+-@".contains($0) } == true || value.first.map { "\t\r\n".contains($0) } == true
        let safe = (unsafe ? "'" : "") + value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    static func data(_ records: [UsageReportRecord]) -> Data {
        let header = ["id", "source", "session", "occurred_at_utc", "model", "granularity", "input_tokens_including_cache", "output_tokens_including_reasoning", "cache_hit_tokens", "cache_miss_tokens", "cache_write_tokens", "reasoning_tokens", "cost_kind", "cost_amount", "currency", "cost_basis"]
        let iso = ISO8601DateFormatter()
        var lines = [header.map(cell).joined(separator: ",")]
        for r in records {
            var fields: [String] = [r.id, r.source, r.session, iso.string(from: r.occurredAt), r.model ?? "", r.granularity ?? "request"]
            let counts: [Int64?] = [r.inputTokens, r.outputTokens, r.cachedInputTokens, r.uncachedInputTokens, r.cacheWriteTokens, r.reasoningTokens]
            fields.append(contentsOf: counts.map { $0.map { String($0) } ?? "" })
            fields.append(r.decimalCost == nil ? "unavailable" : r.costKind)
            fields.append(r.decimalCost == nil ? "" : (r.costAmount ?? ""))
            fields.append(r.decimalCost == nil ? "" : (r.currency ?? ""))
            fields.append(r.costBasis ?? "")
            lines.append(fields.map(cell).joined(separator: ","))
        }
        return Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

private struct UsageReportSnapshot: Decodable, Sendable {
    let schemaVersion: Int
    let records: [UsageReportRecord]
    let status: [String: String]
}

/// Process work and cancellation share one lock. A cancelled launch cannot escape the watchdog.
private final class UsageCollectorJob: Sendable {
    private let process = BoundedProcess()
    func cancel() { process.cancel() }
    func run(script: URL, state: URL) -> Data? {
        let command = BoundedProcess.Command(URL(fileURLWithPath: "/usr/bin/python3"),
            [script.path, "--state-path", state.path], timeout: 12, outputLimit: 16 * 1024 * 1024)
        guard let result = try? process.run(command), result.succeeded, !result.data.isEmpty else { return nil }
        return result.data
    }
}

@MainActor
final class UsageReportStore {
    static let shared = UsageReportStore()
    static let changed = Notification.Name("WhaleGirl.UsageReportChanged")
    var onNewRecord: ((UsageReportRecord) -> Void)?
    var broadcastsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "usageReport.broadcastsEnabled.v1") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "usageReport.broadcastsEnabled.v1"); notify() }
    }
    private(set) var records: [UsageReportRecord] = []
    private(set) var statusText = "等待本机用量记录"
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var job: UsageCollectorJob?
    private var running = false
    private var hasBaseline = false
    private var startedAt = Date()
    private var lastLaunch = -TimeInterval.infinity
    private var seen = Set<String>()
    private var seenOrder: [String] = []
    private var controller: UsageReportWindowController?
    private let directory: URL
    private var seenURL: URL { directory.appendingPathComponent("usage-notified-v1.json") }
    private var snapshotURL: URL { directory.appendingPathComponent("usage-last-report-v1.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? WhaleGirlUserFiles.directory
        let url = self.directory.appendingPathComponent("usage-notified-v1.json")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
           let data = try? Data(contentsOf: url), let ids = try? JSONDecoder().decode([String].self, from: data) {
            seenOrder = Array(ids.filter { $0.count <= 256 }.suffix(20000)); seen = Set(seenOrder)
        }
        let snapshot = self.directory.appendingPathComponent("usage-last-report-v1.json")
        if let size = try? snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024,
           let data = try? Data(contentsOf: snapshot), let saved = try? JSONDecoder().decode(UsageReportSnapshot.self, from: data),
           saved.schemaVersion == 1, saved.records.count <= 10000 {
            var unique = Set<String>()
            records = saved.records.filter { unique.insert($0.id).inserted }.sorted { $0.occurredAt > $1.occurredAt }
            statusText = "已载入上次用量记录；等待本机更新"
        }
    }
    func start() {
        guard !running else { return }
        running = true; hasBaseline = false; startedAt = Date()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { running = false; statusText = "无法创建用量数据目录"; notify(); return }
        refresh()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 0.4; self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        running = false; timer?.invalidate(); timer = nil
        task?.cancel(); job?.cancel()
    }
    func showReport() {
        if controller == nil { controller = UsageReportWindowController(store: self) }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }
    private func refresh() {
        guard running, task == nil, ProcessInfo.processInfo.systemUptime - lastLaunch >= 3 else { return }
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("AIMonitor/whale_usage_report.py"),
              FileManager.default.fileExists(atPath: script.path), FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            statusText = "本机用量采集器或 Python 3 不可用"; notify(); return
        }
        let state = directory.appendingPathComponent("usage-collector-v1.json")
        let job = UsageCollectorJob(); self.job = job; lastLaunch = ProcessInfo.processInfo.systemUptime
        task = Task { [weak self] in
            let output = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) { () -> (Data, UsageReportSnapshot)? in
                    guard let data = job.run(script: script, state: state),
                          let result = try? JSONDecoder().decode(UsageReportSnapshot.self, from: data),
                          result.schemaVersion == 1, result.records.count <= 10000,
                          !(result.records.isEmpty && result.status.values.contains("collectorUnavailable")) else { return nil }
                    return (data, result)
                }.value
            } onCancel: { job.cancel() }
            guard let self else { return }
            self.task = nil; self.job = nil
            guard self.running, !Task.isCancelled else { return }
            guard let (data, result) = output else {
                self.statusText = "采集暂不可用（已保留上次记录）"; self.notify(); return
            }
            var unique = Set<String>()
            self.records = result.records.filter { unique.insert($0.id).inserted }.sorted { $0.occurredAt > $1.occurredAt }
            let new = self.records.reversed().filter { !self.seen.contains($0.id) }
            for record in new {
                self.seen.insert(record.id); self.seenOrder.append(record.id)
            }
            self.seenOrder = Array(self.seenOrder.suffix(20000)); self.seen = Set(self.seenOrder)
            if let encoded = try? JSONEncoder().encode(self.seenOrder) {
                try? encoded.write(to: self.seenURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.seenURL.path)
            }
            if self.hasBaseline && self.broadcastsEnabled {
                for record in new where record.occurredAt >= self.startedAt { self.onNewRecord?(record) }
            }
            self.hasBaseline = true
            var saved = true
            do {
                try data.write(to: self.snapshotURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.snapshotURL.path)
            } catch { saved = false }
            func label(_ source: String) -> String {
                switch result.status[source] {
                case "ready": return "可读取"
                case "unavailable": return "未找到可读用量"
                case "partial", "limited": return "部分记录可读（读取上限）"
                case "error": return "暂时读取失败"
                case "collectorUnavailable": return "采集器暂不可用"
                case "decoderUnavailable": return "缺少压缩解码器"
                case "frameLimitOrInvalidData": return "部分压缩记录不可读"
                default: return "等待可读用量"
                }
            }
            self.statusText = "DSH：\(label("dsh")) · Codex：\(label("codex")) · 最多保留 10,000 条" + (saved ? "" : " · 本次报表未能保存")
            self.notify()
        }
    }
}
