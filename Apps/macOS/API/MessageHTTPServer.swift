import Foundation
import Network
import WhaleCore

/// All connection state is confined to queue. The handler receives bounded,
/// authenticated requests only, and never runs on the socket callback queue.
final class MessageHTTPServer: @unchecked Sendable {
    private final class Client: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        var decoder: MessageHTTPDecoder
        var authenticated = false
        var dispatched = false
        var timeout: DispatchWorkItem?
        var task: Task<Void, Never>?
        init(_ connection: NWConnection, limit: Int) { self.connection = connection; decoder = .init(bodyLimit: limit) }
    }
    private let queue = DispatchQueue(label: "io.whalegirl.message-http", qos: .utility)
    private let listener: NWListener
    private let settings: MessageAPISettings
    private let handler: @Sendable (MessageHTTPRequest) async -> MessageHTTPResponse
    private let onState: @Sendable (String) -> Void
    private var clients: [UUID: Client] = [:]
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelled = false
    private var requestTimes: [TimeInterval] = []
    var port: UInt16? { listener.port?.rawValue }

    init(settings: MessageAPISettings, handler: @escaping @Sendable (MessageHTTPRequest) async -> MessageHTTPResponse,
         onState: @escaping @Sendable (String) -> Void) throws {
        self.settings = settings; self.handler = handler; self.onState = onState
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(settings.listenHost), port: NWEndpoint.Port(rawValue: settings.port)!)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onState("正在监听")
            case .failed: self.onState("监听失败，请检查地址和端口"); self.listener.cancel()
            case .cancelled:
                self.cancelled = true
                for client in Array(self.clients.values) { self.close(client) }
                let waiters = self.stopWaiters; self.stopWaiters.removeAll()
                waiters.forEach { $0.resume() }
            default: break
            }
        }
    }
    func start() { listener.start(queue: queue) }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.cancelled { continuation.resume(); return }
                self.stopWaiters.append(continuation)
                self.listener.cancel()
            }
        }
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 4, !cancelled else { connection.cancel(); return }
        let client = Client(connection, limit: settings.maxUploadBytes)
        clients[client.id] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state { case .failed, .cancelled: self.close(client); default: break }
        }
        let timeout = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client else { return }; self.close(client)
        }
        client.timeout = timeout; queue.asyncAfter(deadline: .now() + 90, execute: timeout)
        connection.start(queue: queue); receive(client)
    }
    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak client] data, _, ended, error in
            guard let self, let client, self.clients[client.id] != nil, !client.dispatched else { return }
            do {
                if let data { try client.decoder.append(data) }
                if let head = client.decoder.head, !client.authenticated {
                    guard MessageAPIAuthentication.accepts(head.headers["authorization"], token: self.settings.token) else {
                        self.send(.init(status: 401, json: ["error": "unauthorized"]), to: client); return
                    }
                    guard head.path == "/v1/uploads" || head.contentLength <= 65_536 else {
                        self.send(.init(status: 413, json: ["error": "body_too_large"]), to: client); return
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    self.requestTimes.removeAll { now - $0 > 60 }
                    guard self.requestTimes.count < 120 else {
                        self.send(.init(status: 429, json: ["error": "rate_limited"]), to: client); return
                    }
                    self.requestTimes.append(now); client.authenticated = true
                    if head.headers["expect"] != nil, head.contentLength > 0 {
                        client.connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    }
                }
                if let request = client.decoder.request {
                    client.dispatched = true
                    let handler = self.handler
                    client.task = Task { [weak self, weak client] in
                        let response = await handler(request)
                        guard let self, let client, !Task.isCancelled else { return }
                        self.queue.async { self.send(response, to: client) }
                    }
                } else if ended || error != nil { self.close(client) }
                else { self.receive(client) }
            } catch MessageAPIError.tooLarge { self.send(.init(status: 413, json: ["error": "body_too_large"]), to: client) }
            catch { self.send(.init(status: 400, json: ["error": "invalid_http"]), to: client) }
        }
    }
    private func send(_ response: MessageHTTPResponse, to client: Client) {
        guard clients[client.id] != nil else { return }
        client.dispatched = true
        client.connection.send(content: response.bytes, completion: .contentProcessed { [weak self, weak client] _ in
            guard let self, let client else { return }; self.close(client)
        })
    }
    private func close(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        client.timeout?.cancel(); client.task?.cancel(); client.connection.cancel()
    }
}
