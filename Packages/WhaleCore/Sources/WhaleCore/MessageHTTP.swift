import Foundation

public struct MessageHTTPHead: Sendable {
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let contentLength: Int
    public var path: String { String(target.split(separator: "?", maxSplits: 1)[0]) }
}
public struct MessageHTTPRequest: Sendable {
    public let head: MessageHTTPHead
    public let body: Data
}
/// One request per connection; no chunking, pipelining or folded headers.
public struct MessageHTTPDecoder: Sendable {
    public private(set) var head: MessageHTTPHead?
    private var buffer = Data()
    private let bodyLimit: Int
    public init(bodyLimit: Int) { self.bodyLimit = bodyLimit }
    public mutating func append(_ data: Data) throws {
        guard data.count <= bodyLimit + 16_384 - buffer.count else { throw MessageAPIError.tooLarge }
        buffer.append(data)
        if head == nil {
            guard let range = buffer.range(of: Data([13, 10, 13, 10])) else {
                if buffer.count > 16_384 { throw MessageAPIError.tooLarge }; return
            }
            guard range.lowerBound <= 16_384, let text = String(data: buffer[..<range.lowerBound], encoding: .utf8) else { throw MessageAPIError.malformedHTTP }
            let lines = text.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
            guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST", "PATCH"].contains(first[0]),
                  first[1].hasPrefix("/"), !first[1].hasPrefix("//"), first[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw MessageAPIError.malformedHTTP }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { throw MessageAPIError.malformedHTTP }
                let name = String(line[..<colon]).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                      headers[name] == nil, !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else { throw MessageAPIError.malformedHTTP }
                headers[name] = value
            }
            guard headers["host"] != nil, headers["transfer-encoding"] == nil, (headers["expect"] == nil || headers["expect"]?.lowercased() == "100-continue") else { throw MessageAPIError.malformedHTTP }
            let lengthText = headers["content-length"] ?? "0"
            guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(lengthText) else { throw MessageAPIError.malformedHTTP }
            guard length <= bodyLimit else { throw MessageAPIError.tooLarge }
            head = MessageHTTPHead(method: String(first[0]), target: String(first[1]), headers: headers, contentLength: length)
            buffer.removeSubrange(..<range.upperBound)
        }
        if let head, buffer.count > head.contentLength { throw MessageAPIError.malformedHTTP }
    }
    public var request: MessageHTTPRequest? {
        guard let head, buffer.count == head.contentLength else { return nil }
        return MessageHTTPRequest(head: head, body: buffer)
    }
}
public struct MessageHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int = 200, json: [String: String]) {
        self.status = status; body = (try? JSONEncoder().encode(json)) ?? Data("{}".utf8)
    }
    public init(status: Int = 200, body: Data) { self.status = status; self.body = body }
    public var bytes: Data {
        let reason = [200: "OK", 201: "Created", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 409: "Conflict", 413: "Content Too Large", 415: "Unsupported Media Type", 422: "Unprocessable Content", 429: "Too Many Requests", 500: "Internal Server Error", 503: "Service Unavailable", 507: "Insufficient Storage"][status] ?? "Error"
        return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n".utf8) + body
    }
}
