import Foundation

public struct SpriteManifest: Codable, Equatable, Sendable {
    public struct Rect: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Point: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
    }

    public struct Atlas: Codable, Equatable, Sendable {
        public let id: String
        public let resource: String
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    public struct Frame: Codable, Equatable, Sendable {
        public let rect: Rect
        public let duration: Double
        public let anchor: Point
        public let visualBounds: Rect
        public let hitbox: Rect
    }

    public struct Clip: Codable, Equatable, Sendable {
        public let id: String
        public let atlasID: String
        public let looping: Bool
        public let frames: [Frame]

        public init(id: String, atlasID: String, looping: Bool, frames: [Frame]) {
            self.id = id
            self.atlasID = atlasID
            self.looping = looping
            self.frames = frames
        }
    }

    public let schemaVersion: Int
    public let atlases: [Atlas]
    public let clips: [Clip]

    public init(schemaVersion: Int, atlases: [Atlas], clips: [Clip]) {
        self.schemaVersion = schemaVersion
        self.atlases = atlases
        self.clips = clips
    }

    public static func decode(_ data: Data) throws -> SpriteManifest {
        let manifest = try JSONDecoder().decode(SpriteManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw SpriteManifestError.unsupportedSchema(schemaVersion) }
        let atlasByID = Dictionary(uniqueKeysWithValues: atlases.map { ($0.id, $0) })
        guard atlasByID.count == atlases.count else { throw SpriteManifestError.duplicateAtlas }
        guard Set(clips.map(\.id)).count == clips.count else { throw SpriteManifestError.duplicateClip }

        for clip in clips {
            guard let atlas = atlasByID[clip.atlasID] else { throw SpriteManifestError.missingAtlas(clip.atlasID) }
            guard !clip.frames.isEmpty else { throw SpriteManifestError.emptyClip(clip.id) }
            for frame in clip.frames {
                guard frame.duration >= 0.03, frame.duration <= 10 else { throw SpriteManifestError.invalidDuration(clip.id) }
                guard frame.rect.x >= 0, frame.rect.y >= 0,
                      frame.rect.width > 0, frame.rect.height > 0,
                      frame.rect.x + frame.rect.width <= Double(atlas.pixelWidth),
                      frame.rect.y + frame.rect.height <= Double(atlas.pixelHeight)
                else { throw SpriteManifestError.frameOutsideAtlas(clip.id) }
                try validateNormalized(frame.visualBounds, clipID: clip.id)
                try validateNormalized(frame.hitbox, clipID: clip.id)
                guard (0...1).contains(frame.anchor.x), (0...1).contains(frame.anchor.y) else {
                    throw SpriteManifestError.invalidAnchor(clip.id)
                }
            }
        }
    }

    private func validateNormalized(_ rect: Rect, clipID: String) throws {
        guard rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
              rect.x + rect.width <= 1, rect.y + rect.height <= 1
        else { throw SpriteManifestError.invalidNormalizedRect(clipID) }
    }

    public func clip(id: String) -> Clip? { clips.first { $0.id == id } }
    public func atlas(id: String) -> Atlas? { atlases.first { $0.id == id } }
}

public enum SpriteManifestError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case duplicateAtlas
    case duplicateClip
    case missingAtlas(String)
    case emptyClip(String)
    case invalidDuration(String)
    case frameOutsideAtlas(String)
    case invalidNormalizedRect(String)
    case invalidAnchor(String)

    public var description: String {
        switch self {
        case let .unsupportedSchema(value): return "Unsupported sprite schema: \(value)"
        case .duplicateAtlas: return "Duplicate atlas id"
        case .duplicateClip: return "Duplicate clip id"
        case let .missingAtlas(id): return "Missing atlas: \(id)"
        case let .emptyClip(id): return "Empty clip: \(id)"
        case let .invalidDuration(id): return "Invalid duration in \(id)"
        case let .frameOutsideAtlas(id): return "Frame outside atlas in \(id)"
        case let .invalidNormalizedRect(id): return "Invalid normalized rect in \(id)"
        case let .invalidAnchor(id): return "Invalid anchor in \(id)"
        }
    }
}

public enum AnimationTimeline {
    public static func frameIndex(clip: SpriteManifest.Clip, elapsed: TimeInterval) -> Int {
        guard !clip.frames.isEmpty else { return 0 }
        let total = clip.frames.reduce(0.0) { $0 + $1.duration }
        let clamped: Double
        if clip.looping {
            clamped = max(0, elapsed).truncatingRemainder(dividingBy: total)
        } else {
            clamped = min(max(0, elapsed), max(0, total - .ulpOfOne))
        }
        var remaining = clamped
        for (index, frame) in clip.frames.enumerated() {
            if remaining < frame.duration { return index }
            remaining -= frame.duration
        }
        return clip.frames.count - 1
    }
}
