import Darwin
import Foundation
import Testing
@testable import WhaleCore

struct LocalEventServerTests {
    @Test func receivesFrameAfterClientConnectsBeforeWriting() async throws {
        let directory = temporaryDirectory()
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let server = try LocalEventServer(directoryURL: directory, frameHandler: { continuation.yield($0) }, failureHandler: {})
        defer { server.stop(); continuation.finish(); try? FileManager.default.removeItem(at: directory) }
        try server.start()
        let frame = Data("{\"delayed\":true}".utf8)
        try send(frame + Data("\n".utf8), to: server.socketPath, delay: 150_000)
        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await stream.first { _ in true } == frame }
            group.addTask { try? await Task.sleep(for: .seconds(1)); return false }
            let result = await group.next() ?? false; group.cancelAll(); return result
        }
        #expect(received)
    }
    @Test func receivesAFramedEventOverUnixSocket() async throws {
        let directory = temporaryDirectory()
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let server = try LocalEventServer(
            directoryURL: directory,
            frameHandler: { continuation.yield($0) },
            failureHandler: {}
        )
        defer {
            server.stop()
            continuation.finish()
            try? FileManager.default.removeItem(at: directory)
        }
        try server.start()
        let frame = Data("{\"ok\":true}".utf8)
        try send(frame + Data("\n".utf8), to: server.socketPath)
        let received = await stream.first { _ in true }
        #expect(received == frame)

        let attributes = try FileManager.default.attributesOfItem(atPath: server.socketPath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func refusesToReplaceASymbolicLink() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try LocalEventServer(directoryURL: directory, frameHandler: { _ in }, failureHandler: {})
        try FileManager.default.createSymbolicLink(
            atPath: server.socketPath,
            withDestinationPath: directory.appendingPathComponent("elsewhere").path
        )
        #expect(throws: LocalEventServerError.self) { try server.start() }
    }

    @Test func validFrameTravelsFromSocketThroughCodecIntoSessionHub() async throws {
        let directory = temporaryDirectory()
        let hub = EventHub()
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        let server = try LocalEventServer(
            directoryURL: directory,
            frameHandler: { frame in
                Task {
                    do {
                        let event = try WhaleEventCodec.decode(frame)
                        _ = await hub.ingest(event, receivedAt: Date(timeIntervalSince1970: 1_800_000_100))
                        continuation.yield(true)
                    } catch {
                        continuation.yield(false)
                    }
                }
            },
            failureHandler: { continuation.yield(false) }
        )
        defer {
            server.stop()
            continuation.finish()
            try? FileManager.default.removeItem(at: directory)
        }
        try server.start()
        let frame = Data("""
        {"schemaVersion":1,"eventId":"00000000-0000-0000-0000-000000000101","source":"codex","sourceInstance":"test","sessionId":"session-a","parentSessionId":null,"projectKey":"WhaleGirl","eventType":"agent.waiting_approval","occurredAt":"2026-10-13T12:00:00Z","receivedAt":null,"sequence":7,"severity":"action_required","summary":"等待操作授权","displayTarget":{"kind":"none","bundleId":null,"uri":null},"metadata":{"client":"codex-hook","approvalKind":"Bash"},"privacyClass":"metadata_only"}
        """.utf8)
        try send(frame + Data("\n".utf8), to: server.socketPath)
        #expect(await stream.first { _ in true } == true)
        let snapshot = await hub.snapshot()
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions.first?.status == .waitingApproval)
        #expect(snapshot.sessions.first?.lastSequence == 7)
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: "/tmp/wg-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    private func send(_ data: Data, to path: String, delay: useconds_t = 0) throws {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { throw POSIXError(.EIO) }
        defer { close(client) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.utf8CString.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: source.prefix(destination.count))
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        if delay > 0 { usleep(delay) }
        let written = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress, data.count) }
        guard written == data.count else { throw POSIXError(.EIO) }
    }
}
