import Foundation
import Darwin

public enum NetworkDiagnosticError: Error, LocalizedError, Sendable {
    case invalidTarget, invalidReading
    public var errorDescription: String? {
        switch self {
        case .invalidTarget: "请输入有效的网址、域名或 IP；网址仅支持 HTTP/HTTPS，不能包含账号密码。"
        case .invalidReading: "测速服务未返回有效结果，请稍后重试。"
        }
    }
}

public struct NetworkTestTarget: Sendable, Equatable {
    public let host: String
    public let downloadURL: URL
    public init(_ input: String) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 2048, !input.contains(where: { $0.isWhitespace || $0.isNewline }),
              !input.contains("\\") else { throw NetworkDiagnosticError.invalidTarget }
        let candidate: String
        if input.contains("://") { candidate = input }
        else if Self.isIP(input), input.contains(":") { candidate = "https://[\(input)]/" }
        else { candidate = "https://" + input }
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              let url = components.url, let rawHost = url.host else { throw NetworkDiagnosticError.invalidTarget }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        guard Self.isIP(host) || Self.isDNSName(host), components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw NetworkDiagnosticError.invalidTarget
        }
        self.host = host.lowercased()
        var download = components; download.fragment = nil
        guard let downloadURL = download.url else { throw NetworkDiagnosticError.invalidTarget }
        self.downloadURL = downloadURL
    }
    public static func isIP(_ text: String) -> Bool {
        var ipv4 = in_addr(), ipv6 = in6_addr()
        return text.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }
    private static func isDNSName(_ text: String) -> Bool {
        let host = text.hasSuffix(".") ? String(text.dropLast()) : text
        guard !host.isEmpty, host.utf8.count <= 253, !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}

public struct RouteProbe: Sendable, Equatable {
    public let ip: String?
    public let milliseconds: Double?
    public let annotation: String?
    public init(ip: String?, milliseconds: Double?, annotation: String? = nil) {
        self.ip = ip; self.milliseconds = milliseconds; self.annotation = annotation
    }
}
public struct RouteHop: Sendable, Equatable {
    public let number: Int
    public let probes: [RouteProbe]
    public var addresses: [String] { probes.compactMap(\.ip).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    public init(number: Int, probes: [RouteProbe]) { self.number = number; self.probes = probes }
}

/// Numeric traceroute output only. Never turns missing replies or exit0 into a reached destination.
public struct RouteTrace: Sendable {
    public private(set) var destinationIP: String?
    public private(set) var hops: [RouteHop] = []
    public init() {}
    public var reachedHop: Int? {
        guard let destinationIP else { return nil }
        return hops.first { hop in hop.probes.contains { probe in
            probe.ip == destinationIP && probe.milliseconds != nil && probe.annotation == nil
        } }?.number
    }
    @discardableResult public mutating func ingest(_ line: String) -> Bool {
        if line.hasPrefix("traceroute ") || line.hasPrefix("traceroute6 ") {
            if let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")") {
                let ip = String(line[line.index(after: open)..<close])
                if NetworkTestTarget.isIP(ip) { destinationIP = ip }
            }
            return true
        }
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first else { return false }
        let continuation = NetworkTestTarget.isIP(first) || first == "*" || (tokens.count > 1 && tokens[1] == "ms")
        let hop: Int, previous: [RouteProbe]
        var index: Int
        if continuation {
            // macOS starts a new indented line when a later probe replies from a different IP.
            guard let last = hops.last else { return false }
            hop = last.number; previous = last.probes; index = 0
        } else {
            guard let number = Int(first), (1...64).contains(number) else { return false }
            hop = number; previous = []; index = 1
        }
        var probes: [RouteProbe] = [], ip = previous.compactMap(\.ip).last
        while index < tokens.count {
            let token = tokens[index]
            if NetworkTestTarget.isIP(token) { ip = token; index += 1; continue }
            if token == "*" { probes.append(.init(ip: nil, milliseconds: nil)); index += 1; continue }
            if let latency = Double(token), latency.isFinite, latency >= 0,
               index + 1 < tokens.count, tokens[index + 1] == "ms", let ip {
                let annotation = index + 2 < tokens.count && tokens[index + 2].hasPrefix("!") ? tokens[index + 2] : nil
                probes.append(.init(ip: ip, milliseconds: latency, annotation: annotation)); index += annotation == nil ? 2 : 3
                continue
            }
            index += 1
        }
        guard !probes.isEmpty, previous.count + probes.count <= 3 else { return false }
        let row = RouteHop(number: hop, probes: previous + probes)
        if let index = hops.firstIndex(where: { $0.number == hop }) { hops[index] = row }
        else { hops.append(row); hops.sort { $0.number < $1.number } }
        return true
    }
    public var summary: String {
        if let reachedHop { return "已到达目标，共 \(reachedHop) 跳" }
        if let last = hops.last { return "已探测 \(last.number) 跳，尚未确认到达目标" }
        return "尚无路由结果"
    }
}

public struct NetworkCapacityReading: Sendable, Equatable {
    public let downloadMbps: Double?
    public let uploadMbps: Double?
    public let idleMilliseconds: Double?
    public init(json: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              root["error"] == nil, root["error_domain"] == nil, root["error_code"] == nil else {
            throw NetworkDiagnosticError.invalidReading
        }
        func number(_ key: String, positive: Bool = false) -> Double? {
            guard let value = root[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let n = value.doubleValue
            return n.isFinite && (positive ? n > 0 : n >= 0) ? n : nil
        }
        downloadMbps = number("dl_throughput", positive: true).map { $0 / 1_000_000 }
        uploadMbps = number("ul_throughput", positive: true).map { $0 / 1_000_000 }
        idleMilliseconds = number("base_rtt")
        guard downloadMbps != nil || uploadMbps != nil else { throw NetworkDiagnosticError.invalidReading }
    }
}

public struct NetworkLatencyReading: Sendable, Equatable {
    public let averageMilliseconds: Double
    public init(output: String) throws {
        guard let line = output.split(separator: "\n").last(where: { $0.contains("min/avg/max") }),
              let equals = line.firstIndex(of: "=") else { throw NetworkDiagnosticError.invalidReading }
        let parts = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count >= 3, let average = Double(parts[1]), average.isFinite, average >= 0 else {
            throw NetworkDiagnosticError.invalidReading
        }
        averageMilliseconds = average
    }
}

public struct NetworkQuickReport: Sendable {
    public let host: String
    public var latency: Double?
    public var trace: RouteTrace?
    public var downloadMbps: Double?
    public var downloadRequested = true
    public var smallDownload = false
    public var publicBandwidth = false
    public init(host: String) { self.host = host }
    public var speech: String {
        var lines = ["测好啦！\(host)"]
        if let latency { lines.append(String(format: "平均延迟 %.1f ms", latency)) }
        else if trace != nil { lines.append("目标延迟未测得") }
        if let trace {
            if let count = trace.reachedHop { lines.append("到达目标共 \(count) 跳") }
            else { lines.append("已探测 \(trace.hops.last?.number ?? 0) 跳，终点未确认") }
        }
        if let downloadMbps {
            lines.append(String(format: "%@下载 %.2f Mbps", publicBandwidth ? "公网" : "目标", downloadMbps))
            if smallDownload { lines.append("小页面速度仅供参考") }
        } else if downloadRequested { lines.append("本次未取得下载速度") }
        return lines.joined(separator: "\n")
    }
}
