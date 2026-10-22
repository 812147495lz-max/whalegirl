import Darwin
import Foundation

public enum LocalEventServerError: Error {
    case pathTooLong
    case unsafeDirectory
    case unsafeExistingNode
    case alreadyRunning
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

public final class LocalEventServer: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (Data) -> Void
    public typealias FailureHandler = @Sendable () -> Void

    public let socketPath: String
    private let frameHandler: FrameHandler
    private let failureHandler: FailureHandler
    private let queue = DispatchQueue(label: "io.whalegirl.events.socket", qos: .utility)
    private var descriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public init(
        directoryURL: URL? = nil,
        frameHandler: @escaping FrameHandler,
        failureHandler: @escaping FailureHandler
    ) throws {
        self.frameHandler = frameHandler
        self.failureHandler = failureHandler
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = directoryURL ?? applicationSupport
            .appendingPathComponent("WhaleGirl", isDirectory: true)
            .appendingPathComponent("ipc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.validateDirectory(directory.path)
        socketPath = directory.appendingPathComponent("whalegirl-events.sock").path
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw LocalEventServerError.pathTooLong
        }
    }

    public func start() throws {
        guard descriptor < 0 else { return }
        try prepareSocketPath()
        let created = socket(AF_UNIX, SOCK_STREAM, 0)
        guard created >= 0 else { throw LocalEventServerError.socketCreationFailed(errno) }
        descriptor = created

        var address = Self.address(for: socketPath)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(created, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(created)
            descriptor = -1
            throw LocalEventServerError.bindFailed(code)
        }
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            close(created)
            descriptor = -1
            unlink(socketPath)
            throw LocalEventServerError.bindFailed(code)
        }
        guard listen(created, 8) == 0 else {
            let code = errno
            close(created)
            descriptor = -1
            unlink(socketPath)
            throw LocalEventServerError.listenFailed(code)
        }
        _ = fcntl(created, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: created, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { close(created) }
        acceptSource = source
        source.resume()
    }

    public func stop() {
        let activeDescriptor = descriptor
        descriptor = -1
        acceptSource?.cancel()
        acceptSource = nil
        if activeDescriptor >= 0 { shutdown(activeDescriptor, SHUT_RDWR) }
        var status = stat()
        if lstat(socketPath, &status) == 0,
           (status.st_mode & S_IFMT) == S_IFSOCK,
           status.st_uid == getuid() {
            unlink(socketPath)
        }
    }

    private func acceptConnections() {
        while descriptor >= 0 {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK { failureHandler() }
                return
            }
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else {
                close(client)
                continue
            }
            // Darwin inherits O_NONBLOCK from the listening socket. A hook often writes
            // just after connect returns; treating that first EAGAIN as EOF loses it.
            let flags = fcntl(client, F_GETFL, 0)
            guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
                close(client); failureHandler(); continue
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.read(client: client) }
        }
    }

    private func read(client: Int32) {
        defer { close(client) }
        var reader = FramedJSONReader()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        var frameCount = 0
        while true {
            // poll also handles clients that wrote and closed before accept. On macOS,
            // setting SO_RCVTIMEO on that already-disconnected socket can fail EINVAL.
            var readiness = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let ready = poll(&readiness, 1, 2_000)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return }
            let count = Darwin.read(client, &bytes, bytes.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            for result in reader.append(Data(bytes.prefix(count))) {
                frameCount += 1
                guard frameCount <= 120 else {
                    failureHandler()
                    return
                }
                switch result {
                case let .success(frame): frameHandler(frame)
                case .failure: failureHandler()
                }
            }
        }
    }

    private func prepareSocketPath() throws {
        var status = stat()
        guard lstat(socketPath, &status) == 0 else {
            if errno == ENOENT { return }
            throw LocalEventServerError.unsafeExistingNode
        }
        guard (status.st_mode & S_IFMT) == S_IFSOCK, status.st_uid == getuid() else {
            throw LocalEventServerError.unsafeExistingNode
        }
        if Self.canConnect(to: socketPath) { throw LocalEventServerError.alreadyRunning }
        guard unlink(socketPath) == 0 else { throw LocalEventServerError.unsafeExistingNode }
    }

    private static func canConnect(to path: String) -> Bool {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { return false }
        defer { close(client) }
        var address = Self.address(for: path)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private static func address(for path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.utf8CString.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: source.prefix(destination.count))
            }
        }
        return address
    }

    private static func validateDirectory(_ path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              (status.st_mode & 0o077) == 0 else {
            throw LocalEventServerError.unsafeDirectory
        }
    }
}
