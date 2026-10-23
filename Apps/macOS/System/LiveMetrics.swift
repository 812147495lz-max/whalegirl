import AppKit
import Darwin
import WhaleCore

@MainActor
final class SystemMetricsHistory {
    static let shared = SystemMetricsHistory()
    static let changed = Notification.Name("WhaleGirl.MetricHistoryChanged")
    struct Sample { let date: Date; let values: [SystemMetric: [Double?]] }
    private(set) var samples: [Sample] = []
    let duration: TimeInterval = 300
    func record(_ snapshot: SystemMetricsSnapshot, at date: Date) {
        guard samples.last.map({ date.timeIntervalSince($0.date) >= 0.8 }) ?? true else { return }
        if let last = samples.last, date.timeIntervalSince(last.date) > 3 {
            samples.append(Sample(date: last.date.addingTimeInterval(1), values: [:]))
        }
        let memory = snapshot.memoryReadingAvailable && snapshot.memoryTotalBytes > 0
            ? Double(snapshot.memoryUsedBytes) / Double(snapshot.memoryTotalBytes) * 100 : nil
        samples.append(Sample(date: date, values: [
            .cpu: [snapshot.cpuPercent], .gpu: [snapshot.hardware.gpuPercent], .memory: [memory],
            .battery: [snapshot.batteryPercent.map(Double.init)],
            .network: [snapshot.downloadBytesPerSecond, snapshot.uploadBytesPerSecond],
            .temperature: [snapshot.hardware.cpuTemperature, snapshot.hardware.gpuTemperature]
        ]))
        samples.removeAll { date.timeIntervalSince($0.date) > duration }
        if samples.count > 305 { samples.removeFirst(samples.count - 305) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

@MainActor
final class MetricTrendView: NSView {
    private let metric: SystemMetric
    private let showsTimeWindow: Bool
    private var observation: AIMonitorObservation?
    init(metric: SystemMetric, showsTimeWindow: Bool = true) {
        self.metric = metric; self.showsTimeWindow = showsTimeWindow
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        observation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: SystemMetricsHistory.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        })
        setAccessibilityRole(.image)
        setAccessibilityLabel(metric.title + "折线图，最近5分钟，每秒采样；缺失数据不连线")
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let history = SystemMetricsHistory.shared
        let samples = history.samples
        let all = samples.flatMap { $0.values[metric] ?? [] }.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
        let isNetwork = metric == .network
        let top = isNetwork ? max(1024, (all.max() ?? 0) * 1.12) : metric == .temperature ? max(100, (all.max() ?? 0) * 1.1) : 100
        let plot = CGRect(x: 1, y: 2, width: max(1, bounds.width - 2), height: max(1, bounds.height - 15))
        let grid = NSBezierPath()
        for factor in [0.0, 0.5, 1.0] {
            let y = plot.minY + plot.height * factor
            grid.move(to: NSPoint(x: plot.minX, y: y)); grid.line(to: NSPoint(x: plot.maxX, y: y))
        }
        InformationPalette.border.withAlphaComponent(0.6).setStroke(); grid.lineWidth = 0.5; grid.stroke()
        let now = samples.last?.date ?? Date()
        let horizon = min(history.duration, max(30, now.timeIntervalSince(samples.first?.date ?? now)))
        let seriesCount = metric == .network || metric == .temperature ? 2 : 1
        for index in 0..<seriesCount {
            let path = NSBezierPath(); path.lineWidth = 1.5; path.lineJoinStyle = .round
            var connected = false
            var lastPoint: NSPoint?
            for sample in samples {
                guard let values = sample.values[metric], values.indices.contains(index), let value = values[index], value.isFinite, value >= 0 else { connected = false; continue }
                let x = plot.maxX - CGFloat(now.timeIntervalSince(sample.date) / horizon) * plot.width
                let y = plot.minY + CGFloat(min(1, max(0, value / top))) * plot.height
                lastPoint = NSPoint(x: x, y: y)
                if connected { path.line(to: NSPoint(x: x, y: y)) } else { path.move(to: NSPoint(x: x, y: y)); connected = true }
            }
            let color = index == 0 ? InformationPalette.blue : InformationPalette.teal
            color.setStroke(); path.stroke()
            if let lastPoint { color.setFill(); NSBezierPath(ovalIn: NSRect(x: lastPoint.x - 1.5, y: lastPoint.y - 1.5, width: 3, height: 3)).fill() }
        }
        let axis: String
        if isNetwork { axis = ByteCountFormatter.string(fromByteCount: Int64(min(top, Double(Int64.max / 2))), countStyle: .file) + "/s" }
        else { axis = String(format: "%.0f", top) + (metric == .temperature ? "°C" : "%") }
        let attributes: [NSAttributedString.Key: Any] = [.font: InformationDataStyle.font, .foregroundColor: InformationPalette.secondary]
        (axis as NSString).draw(at: NSPoint(x: 0, y: bounds.height - 14), withAttributes: attributes)
        if showsTimeWindow {
            let window = horizon >= 299 ? "5m" : String(format: "%.0fs", horizon)
            let width = (window as NSString).size(withAttributes: attributes).width
            (window as NSString).draw(at: NSPoint(x: bounds.width - width, y: bounds.height - 14), withAttributes: attributes)
        }
        if all.isEmpty { (samples.isEmpty ? "等待数据" as NSString : "暂无数据" as NSString).draw(at: NSPoint(x: 2, y: plot.midY - 5), withAttributes: attributes) }
        let last = samples.last?.values[metric]?.compactMap { $0 }.first
        setAccessibilityValue(last.map { String(format: "最新 %.1f", $0) } ?? "暂无可用数据")
        toolTip = metric.title + " · 最近5分钟 · 1秒采样 · " + now.formatted(date: .omitted, time: .standard) + "\n" + (metric == .network ? "蓝色：下载；青色：上传" : metric == .temperature ? "蓝色：CPU；青色：GPU" : "") + "\n间断表示没有有效读数，数值仅保存在内存。"
    }
}

@MainActor
final class NetworkAddressStore {
    static let shared = NetworkAddressStore()
    static let changed = Notification.Name("WhaleGirl.NetworkAddressesChanged")
    private(set) var internalAddress = "读取中…"
    var internalAddressLines: [String] {
        internalAddress.components(separatedBy: " · ").sorted { !$0.contains(":") && $1.contains(":") }
    }
    static func informationRowHeight(for address: String) -> CGFloat { 20 }
    private(set) var publicAddress = "未查询"
    var publicAddressLines: [String] { publicAddress.components(separatedBy: " · ") }
    private(set) var fetchedAt: Date?
    private var task: Task<Void, Never>?
    func refresh(force: Bool = false) {
        internalAddress = Self.localAddresses().joined(separator: " · ")
        if internalAddress.isEmpty { internalAddress = "不可用" }
        guard task == nil, force || fetchedAt.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { changed(); return }
        publicAddress = "查询中…"; changed()
        task = Task { [weak self] in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6; config.timeoutIntervalForResource = 8
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            async let ipv4 = Self.fetchPublicAddress(session: session, host: "api.ipify.org")
            async let ipv6 = Self.fetchPublicAddress(session: session, host: "api6.ipify.org")
            let values = await [ipv4, ipv6].compactMap { $0 }
            guard let self, !Task.isCancelled else { return }
            self.publicAddress = values.isEmpty ? "不可用" : values.joined(separator: " · ")
            self.fetchedAt = Date(); self.task = nil; self.changed()
        }
    }
    nonisolated private static func fetchPublicAddress(session: URLSession, host: String) async -> String? {
        do {
            let (bytes, response) = try await session.bytes(from: URL(string: "https://" + host)!)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == host else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 128 else { return nil }; data.append(byte)
            }
            let address = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard NetworkTestTarget.isIP(address), !Task.isCancelled,
                  (host == "api6.ipify.org") == address.contains(":") else { return nil }
            return address
        } catch { return nil }
    }
    func stop() { task?.cancel(); task = nil }
    private func changed() { NotificationCenter.default.post(name: Self.changed, object: self) }
    private static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        var node: UnsafeMutablePointer<ifaddrs>? = head
        while let item = node?.pointee {
            defer { node = item.ifa_next }
            guard let addr = item.ifa_addr, [UInt8(AF_INET), UInt8(AF_INET6)].contains(addr.pointee.sa_family),
                  item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: item.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !address.hasPrefix("169.254."), !address.lowercased().hasPrefix("fe80:"), !result.contains(address) { result.append(address) }
            }
        }
        return Array(result.prefix(4))
    }
}
