import Foundation

public enum FramedJSONError: Error, Equatable, Sendable {
    case frameTooLarge
}

public struct FramedJSONReader: Sendable {
    private let maximumFrameBytes: Int
    private var buffer = Data()
    private var discardingOversizedFrame = false

    public init(maximumFrameBytes: Int = WhaleEventContract.maximumFrameBytes) {
        self.maximumFrameBytes = maximumFrameBytes
    }

    public mutating func append(_ data: Data) -> [Result<Data, FramedJSONError>] {
        var results: [Result<Data, FramedJSONError>] = []
        for byte in data {
            if byte == 0x0A {
                if discardingOversizedFrame {
                    discardingOversizedFrame = false
                    buffer.removeAll(keepingCapacity: true)
                    continue
                }
                if buffer.last == 0x0D { buffer.removeLast() }
                if !buffer.isEmpty { results.append(.success(buffer)) }
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            if discardingOversizedFrame { continue }
            buffer.append(byte)
            if buffer.count > maximumFrameBytes {
                buffer.removeAll(keepingCapacity: true)
                discardingOversizedFrame = true
                results.append(.failure(.frameTooLarge))
            }
        }
        return results
    }
}
