import Darwin
import Foundation
import IOKit.ps
import AppKit
import Metal

struct SystemMetricsSnapshot: Sendable {
    let cpuPercent: Double?
    let memoryUsedBytes: UInt64
    let memoryTotalBytes: UInt64
    let downloadBytesPerSecond: Double?
    let uploadBytesPerSecond: Double?
    let batteryPercent: Int?
    let batteryCharging: Bool?

    var hardware: HardwareMetricsSnapshot = .unavailable
    var batteryPresent: Bool? = nil
    var memoryReadingAvailable = true

    static let unavailable = SystemMetricsSnapshot(
        cpuPercent: nil,
        memoryUsedBytes: 0,
        memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
        downloadBytesPerSecond: nil,
        uploadBytesPerSecond: nil,
        batteryPercent: nil,
        batteryCharging: nil, memoryReadingAvailable: false
    )
}

@MainActor
final class SystemMetricsSampler {
    private var previousCPUTicks: (busy: UInt64, total: UInt64)?
    private var previousNetwork: (date: Date, incoming: UInt64, outgoing: UInt64)?

    private let hardwareReader = HardwareMetricsReader()
    private var hardwareTask: Task<Void, Never>?
    private var lastHardwareRequest = Date.distantPast
    private var hardware = HardwareMetricsSnapshot.unavailable

    func sample(at date: Date = Date()) -> SystemMetricsSnapshot {
        refreshHardware(at: date)
        let cpu = sampleCPU()
        let memory = sampleMemory()
        let network = sampleNetwork(at: date)
        let battery = sampleBattery()
        var snapshot = SystemMetricsSnapshot(
            cpuPercent: cpu,
            memoryUsedBytes: memory.used,
            memoryTotalBytes: memory.total,
            downloadBytesPerSecond: network?.download,
            uploadBytesPerSecond: network?.upload,
            batteryPercent: battery?.percent,
            batteryCharging: battery?.charging
        )
        snapshot.hardware = hardware.fetchedAt.map { date.timeIntervalSince($0) < 30 } == true ? hardware : .unavailable
        snapshot.batteryPresent = battery != nil
        snapshot.memoryReadingAvailable = memory.available
        return snapshot
    }

    func sampleCPUUsage() -> Double? { sampleCPU() }

    private func refreshHardware(at date: Date) {
        let enabled = SystemMetricPreferences.shared.enabled
        guard hardwareTask == nil, date.timeIntervalSince(lastHardwareRequest) >= 5,
              !enabled.isDisjoint(with: [.gpu, .temperature, .storage]) else { return }
        lastHardwareRequest = date
        let reader = hardwareReader
        hardwareTask = Task { [weak self] in
            let result = await reader.read(enabled: enabled, chip: MacHardwareIdentity.chip)
            guard let self else { return }
            self.hardware = result
            self.hardwareTask = nil
        }
    }

    func waitForHardwareSample() async { await hardwareTask?.value }

    private func sampleCPU() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks: [UInt64] = withUnsafePointer(to: info.cpu_ticks) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(CPU_STATE_MAX)) {
                buffer in (0..<Int(CPU_STATE_MAX)).map { index in UInt64(buffer[index]) }
            }
        }
        let idle = ticks[Int(CPU_STATE_IDLE)]
        let total = ticks.reduce(0, +)
        let current = (busy: total - idle, total: total)
        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks,
              current.total >= previous.total,
              current.busy >= previous.busy,
              current.total > previous.total else { return nil }
        return Double(current.busy - previous.busy) / Double(current.total - previous.total) * 100
    }

    private func sampleMemory() -> (used: UInt64, total: UInt64, available: Bool) {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (0, total, false) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        // Match Activity Monitor's app + wired + compressed footprint; exclude reclaimable file cache.
        let occupied = UInt64(info.internal_page_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        let pages = occupied > UInt64(info.purgeable_count) ? occupied - UInt64(info.purgeable_count) : 0
        return (min(total, pages * UInt64(pageSize)), total, true)
    }

    private func sampleNetwork(at date: Date) -> (download: Double, upload: Double)? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }
        var incoming: UInt64 = 0
        var outgoing: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = pointer?.pointee {
            defer { pointer = interface.ifa_next }
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en"), (interface.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            incoming += UInt64(data.pointee.ifi_ibytes)
            outgoing += UInt64(data.pointee.ifi_obytes)
        }
        let current = (date: date, incoming: incoming, outgoing: outgoing)
        defer { previousNetwork = current }
        guard let previous = previousNetwork else { return nil }
        let interval = date.timeIntervalSince(previous.date)
        guard interval > 0, incoming >= previous.incoming, outgoing >= previous.outgoing else { return nil }
        return (
            Double(incoming - previous.incoming) / interval,
            Double(outgoing - previous.outgoing) / interval
        )
    }

    private func sampleBattery() -> (percent: Int, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
                  maximum > 0 else { continue }
            guard (description[kIOPSTypeKey as String] as? String) == (kIOPSInternalBatteryType as String) else { continue }
            return (Int((Double(current) / Double(maximum) * 100).rounded()), description[kIOPSIsChargingKey as String] as? Bool ?? false)
        }
        return nil
    }
}

// MARK: - Selectable, persisted metrics

enum SystemMetric: String, CaseIterable, Sendable {
    case model, cpu, gpu, memory, battery, storage, network, temperature
    var title: String {
        switch self {
        case .model: "电脑型号与芯片"
        case .cpu: "CPU 占用"
        case .gpu: "GPU 占用"
        case .memory: "内存占用"
        case .battery: "电池"
        case .storage: "储存占用"
        case .network: "上传与下载速度"
        case .temperature: "CPU / GPU 温度"
        }
    }
}

@MainActor
final class SystemMetricPreferences {
    static let shared = SystemMetricPreferences()
    static let changed = Notification.Name("WhaleGirl.SystemMetricsChanged")
    private let defaults: UserDefaults
    private let key = "informationPanel.enabledMetrics.v1"
    private(set) var enabled: Set<SystemMetric>
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.stringArray(forKey: key) { enabled = Set(saved.compactMap(SystemMetric.init(rawValue:))) }
        else { enabled = Set(SystemMetric.allCases) }
    }
    func set(_ metric: SystemMetric, enabled value: Bool) {
        if value { enabled.insert(metric) } else { enabled.remove(metric) }
        save()
    }
    func setAll(_ value: Bool) { enabled = value ? Set(SystemMetric.allCases) : []; save() }
    private func save() {
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: key)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    var panelBaseHeight: CGFloat {
        let tiles = enabled.intersection([.cpu, .gpu, .memory, .storage]).count
        return 102 + (enabled.contains(.model) ? 36 : 0) + CGFloat((tiles + 1) / 2) * 100
            + (enabled.contains(.network) ? 38 : 0) + (enabled.contains(.battery) ? 24 : 0)
            + (enabled.contains(.temperature) ? 50 : 0)
    }
}

struct HardwareMetricsSnapshot: Sendable {
    var gpuPercent: Double?
    var gpuName: String?
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var storageUsedBytes: UInt64?
    var storageTotalBytes: UInt64?
    var fetchedAt: Date?
    static let unavailable = HardwareMetricsSnapshot()
}

/// Slow hardware queries run on this actor, never on the UI thread. No subprocesses or privileges.
actor HardwareMetricsReader {
    func read(enabled: Set<SystemMetric>, chip: String) -> HardwareMetricsSnapshot {
        var result = HardwareMetricsSnapshot()
        if enabled.contains(.storage) {
            let url = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
            if let capacity = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
               let total = capacity.volumeTotalCapacity, let available = capacity.volumeAvailableCapacity,
               total > 0, available >= 0, available <= total {
                result.storageTotalBytes = UInt64(total)
                result.storageUsedBytes = UInt64(total - available)
            }
        }
        if enabled.contains(.gpu) || enabled.contains(.temperature) {
            var iterator: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                for _ in 0..<32 {
                    let service = IOIteratorNext(iterator)
                    guard service != 0 else { break }
                    defer { IOObjectRelease(service) }
                    guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
                    let usage = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
                        ?? (stats["GPU Activity(%)"] as? NSNumber)?.doubleValue
                    if let usage, usage.isFinite, (0...100).contains(usage) {
                        // Multi-GPU machines show the busiest readable GPU, not a misleading sum.
                        result.gpuPercent = max(result.gpuPercent ?? usage, usage)
                    }
                    if let temp = (stats["Temperature(C)"] as? NSNumber)?.doubleValue, Self.validTemperature(temp) {
                        result.gpuTemperature = max(result.gpuTemperature ?? temp, temp)
                    }
                }
            }
            result.gpuName = MTLCopyAllDevices().map(\.name).joined(separator: " / ")
        }
        if enabled.contains(.temperature), let smc = ReadOnlySMC() {
            let keys = SMCTemperatureKeys.forChip(chip)
            for key in keys.cpu {
                guard let value = smc.temperature(key), Self.validTemperature(value) else { continue }
                result.cpuTemperature = max(result.cpuTemperature ?? value, value)
            }
            for key in keys.gpu {
                guard let value = smc.temperature(key), Self.validTemperature(value) else { continue }
                result.gpuTemperature = max(result.gpuTemperature ?? value, value)
            }
        }
        result.fetchedAt = Date()
        return result
    }
    static func validTemperature(_ value: Double) -> Bool { value.isFinite && (1...125).contains(value) }
}

/// Read-only SMC ABI adapted from exelban/Stats (MIT), b796af44541a6e1802e58918d301aa8c7c07572d.
/// Attribution/license shipped in AIMonitor/Stats-LICENSE.txt. No write commands or fan controls.
final class ReadOnlySMC {
    private struct Version { var a: UInt8 = 0; var b: UInt8 = 0; var c: UInt8 = 0; var d: UInt8 = 0; var e: UInt16 = 0 }
    private struct Limit { var a: UInt16 = 0; var b: UInt16 = 0; var c: UInt32 = 0; var d: UInt32 = 0; var e: UInt32 = 0 }
    private struct Info { var size: UInt32 = 0; var type: UInt32 = 0; var attributes: UInt8 = 0 }
    private struct Message {
        var key: UInt32 = 0; var version = Version(); var limit = Limit(); var info = Info()
        var padding: UInt16 = 0; var result: UInt8 = 0; var status: UInt8 = 0; var command: UInt8 = 0; var index: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }
    private var connection: io_connect_t = 0
    init?() {
        // SMC ABI has 80 bytes with a 32-byte payload at byte48 on both architectures.
        guard MemoryLayout<Message>.stride == 80, MemoryLayout<Message>.offset(of: \.bytes) == 48 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    private func call(_ input: inout Message) -> Message? {
        var output = Message(); var size = MemoryLayout<Message>.stride
        let status = IOConnectCallStructMethod(connection, 2, &input, size, &output, &size)
        return status == KERN_SUCCESS && output.result == 0 && size == MemoryLayout<Message>.stride ? output : nil
    }
    private func read(_ key: String) -> (UInt32, [UInt8])? {
        guard key.utf8.count == 4 else { return nil }
        var request = Message(); request.key = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }; request.command = 9
        guard let info = call(&request), (1...32).contains(info.info.size) else { return nil }
        request.info.size = info.info.size; request.command = 5
        guard var value = call(&request) else { return nil }
        return withUnsafeBytes(of: &value.bytes) { (info.info.type, Array($0.prefix(Int(info.info.size)))) }
    }
    func temperature(_ key: String) -> Double? {
        guard let (type, bytes) = read(key) else { return nil }
        return Self.decode(type: type, bytes: bytes)
    }
    static func decode(type: UInt32, bytes: [UInt8]) -> Double? {
        if type == 0x666c7420, bytes.count == 4 { // flt , little-endian IEEE754 on Intel and Apple silicon.
            let bits = bytes.enumerated().reduce(UInt32.zero) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
            return Double(Float(bitPattern: bits))
        }
        if type == 0x73703738, bytes.count == 2 { // signed sp78, big-endian fixed point.
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        }
        return nil
    }

}

@MainActor
enum MacHardwareIdentity {
    static let identifier = sysctlString("hw.model") ?? "Mac"
    static let chip = sysctlString("machdep.cpu.brand_string") ?? "处理器信息不可用"
    static let name: String = {
        for path in ["IODeviceTree:/product", "IODeviceTree:/"] {
            let service = IORegistryEntryFromPath(kIOMainPortDefault, path)
            guard service != 0 else { continue }
            defer { IOObjectRelease(service) }
            if let property = IORegistryEntryCreateCFProperty(service, "product-name" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() {
                let value = (property as? String) ?? (property as? Data).flatMap { String(data: $0, encoding: .utf8) }
                if let value = value?.trimmingCharacters(in: .controlCharacters), !value.isEmpty { return value }
            }
        }
        return identifier
    }()
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= 4096 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}

// Generation-specific CPU/GPU keys from Stats Modules/Sensors/values.swift at the attributed commit.
// No prefix guessing: e.g. Tp0P is a powerboard sensor on Intel and must not become CPU temperature.
enum SMCTemperatureKeys {
    static func forChip(_ chip: String) -> (cpu: [String], gpu: [String]) {
        let generation = chip.split(separator: " ").first { $0.first == "M" && $0.dropFirst().allSatisfy(\.isNumber) }.map(String.init) ?? "Intel"
        switch generation {
        case "M1": return (["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"], ["Tg05", "Tg0D", "Tg0L", "Tg0T"])
        case "M2": return (["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"], ["Tg0f", "Tg0j"])
        case "M3": return (["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"], ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"])
        case "M4": return (["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"], ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])
        case "M5": return (["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"], ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"])
        case "M6": return (["Tp0j", "Tp0g", "Tp09", "Tp07", "Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G", "Tp0b", "Tp05", "Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"], ["Tg1e", "Tg0d", "Tg0c", "Tg0b", "Tg1c", "Tg1d", "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1g", "Tg1h"])
        default:
            return (["TC0D", "TC0E", "TC0F", "TC0P", "TCAD", "TCAC", "TCBC"]
                + "0123456789ABCDEF".flatMap { ["TC\($0)c", "TC\($0)C"] }, ["TCGC", "TG0P", "TG0D", "TGDD"])
        }
    }
}
