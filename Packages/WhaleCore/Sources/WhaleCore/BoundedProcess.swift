import Foundation
import Darwin

/// Shared non-shell process I/O. Callers retain their own output, timeout and
/// error policies; cancellation, EOF, draining and child reaping have one owner.
public final class BoundedProcess: @unchecked Sendable {
    public struct Command: Sendable {
        public let executable: URL
        public let arguments: [String]
        public let timeout: TimeInterval
        public let outputLimit: Int
        public var environment: [String: String]?
        public var directory: URL?
        public var mergeStandardError = false
        public var observedFile: URL?
        public var fileLimit: Int64 = .max
        public init(_ executable: URL, _ arguments: [String], timeout: TimeInterval, outputLimit: Int) {
            self.executable = executable; self.arguments = arguments
            self.timeout = timeout; self.outputLimit = outputLimit
        }
    }
    public struct Result: Sendable {
        public let data: Data
        public let exitCode: Int32
        public let cancelled: Bool
        public let timedOut: Bool
        public let overflow: Bool
        public let ioFailed: Bool
        public var succeeded: Bool { exitCode == 0 && !cancelled && !timedOut && !overflow && !ioFailed }
    }
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    public func execute(_ command: Command, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        let worker = Task.detached(priority: .utility) { try self.run(command, progress: progress) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: {
            self.cancel(); worker.cancel()
        }
    }
    public func run(_ command: Command, onLine: (@Sendable (String) -> Void)? = nil,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> Result {
        let child = Process(), pipe = Pipe()
        child.executableURL = command.executable; child.arguments = command.arguments
        child.currentDirectoryURL = command.directory; child.environment = command.environment
        child.standardInput = FileHandle.nullDevice; child.standardOutput = pipe
        child.standardError = command.mergeStandardError ? pipe : FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child } catch { lock.unlock(); throw error }
        lock.unlock()
        try? pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        defer { try? pipe.fileHandleForReading.close(); lock.lock(); process = nil; lock.unlock() }
        let deadline = ProcessInfo.processInfo.systemUptime + command.timeout
        var data = Data(), pending = Data(), buffer = [UInt8](repeating: 0, count: 32768)
        var eof = false, timedOut = false, overflow = false, ioFailed = false
        func fileExceedsLimit() -> Bool {
            guard let file = command.observedFile, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
            progress(min(1, Double(size) / Double(max(1, command.fileLimit))))
            return size > command.fileLimit
        }
        while true {
            lock.lock(); let stopped = cancelled; lock.unlock()
            timedOut = ProcessInfo.processInfo.systemUptime >= deadline
            overflow = fileExceedsLimit()
            if stopped || timedOut || overflow { break }
            if !eof {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard count <= command.outputLimit - data.count else { overflow = true; break }
                    let chunk = Data(buffer.prefix(count)); data.append(chunk)
                    if let onLine {
                        pending.append(chunk)
                        while let end = pending.firstIndex(of: 10) {
                            onLine(String(decoding: pending[..<end], as: UTF8.self)); pending.removeSubrange(...end)
                        }
                    }
                    continue
                } else if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EINTR { ioFailed = true; break }
            }
            if eof && !child.isRunning { break }
            usleep(20_000)
        }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        if !pending.isEmpty { onLine?(String(decoding: pending, as: UTF8.self)) }
        lock.lock(); let stopped = cancelled; lock.unlock()
        overflow = overflow || fileExceedsLimit()
        return Result(data: data, exitCode: child.terminationStatus, cancelled: stopped,
                      timedOut: timedOut, overflow: overflow, ioFailed: ioFailed)
    }
}
