import AppKit
import ImageIO
import WhaleCore

@MainActor
final class SpriteRepository {
    enum Skin: String, CaseIterable {
        case classic, red
        var title: String { self == .classic ? "经典鲸鱼娘" : "赤风RED" }
    }

    struct CommunityAction: Decodable {
        let clipID: String
        let title: String
        let category: String
        var skin: String? = nil
    }

    struct RenderLayout: Decodable {
        let canvasWidth: Double
        let canvasHeight: Double
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        var normalized: CGRect {
            CGRect(x: x / canvasWidth, y: 1 - (y + height) / canvasHeight,
                   width: width / canvasWidth, height: height / canvasHeight)
        }
    }
    private var renderLayouts: [String: RenderLayout] = [:]
    private var clipsByID: [String: SpriteManifest.Clip] = [:]
    private var atlasesByID: [String: SpriteManifest.Atlas] = [:]

    func renderLayout(for clipID: String) -> RenderLayout? {
        guard let clip = clip(clipID) else { return nil }
        return renderLayouts[clip.atlasID]
    }

    func canvasAspect(for clipID: String) -> Double {
        if let layout = renderLayout(for: clipID) { return layout.canvasWidth / layout.canvasHeight }
        guard let rect = clip(clipID)?.frames.first?.rect else { return 1 }
        return rect.width / rect.height
    }

    func atlas(_ id: String) -> SpriteManifest.Atlas? { atlasesByID[id] }

    private final class ActionClaim {
        weak var owner: AnyObject?
        var clipIDs: Set<String> = []
        init(owner: AnyObject) { self.owner = owner }
    }
    private var stationaryClaims: [ObjectIdentifier: ActionClaim] = [:]

    /// Main-actor reservation includes the outgoing pose until the new texture is displayed.
    func claimStationaryAction(_ preferred: String, candidates: [String], owner: AnyObject) -> String? {
        stationaryClaims = stationaryClaims.filter { $0.value.owner != nil }
        let key = ObjectIdentifier(owner)
        let occupied = Set(stationaryClaims.filter { $0.key != key }.values.flatMap { $0.clipIDs })
        guard let selected = ([preferred] + candidates).first(where: { !occupied.contains(stationaryKey($0)) }) else { return nil }
        let claim = stationaryClaims[key] ?? ActionClaim(owner: owner)
        claim.clipIDs.insert(stationaryKey(selected))
        stationaryClaims[key] = claim
        return selected
    }

    func retainStationaryAction(_ clipID: String?, owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        guard let clipID else { stationaryClaims[key] = nil; return }
        stationaryClaims[key]?.clipIDs = [stationaryKey(clipID)]
    }

    private func stationaryKey(_ clipID: String) -> String {
        // Short aliases of the same source action count as the same action.
        clip(clipID)?.atlasID ?? clipID
    }

    private struct CommunityCatalog: Decodable {
        let aliases: [String: String]
        let actions: [CommunityAction]
    }

    final class DecodedAtlas: @unchecked Sendable {
        let image: CGImage
        let alpha: [UInt8]
        var byteCost: Int { image.bytesPerRow * image.height + alpha.count }

        nonisolated init?(source: CGImage) {
            let width = source.width, height = source.height
            guard let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            // Materialize a bitmap once. An ImageIO-backed crop can decode the WebP again.
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage(), let data = context.data else { return nil }
            self.image = image
            let pixels = data.assumingMemoryBound(to: UInt8.self)
            var mask = [UInt8](repeating: 0, count: (width * height + 7) / 8)
            for index in 0..<(width * height) where pixels[index * 4 + 3] >= 24 {
                mask[index / 8] |= 1 << (index % 8)
            }
            self.alpha = mask
        }

        func mask(for rect: CGRect) -> SpriteAlphaMask {
            SpriteAlphaMask(alpha: alpha, atlasWidth: image.width, rect: rect, packed: true)
        }
    }

    private final class WeakAtlas {
        weak var value: DecodedAtlas?
        init(_ value: DecodedAtlas) { self.value = value }
    }
    private static let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "WhaleGirl.SpriteDecode"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    let manifest: SpriteManifest
    private let allCommunityActions: [CommunityAction]
    private var actionsBySkin: [String: [CommunityAction]] = [:]
    private(set) var selectedSkin: Skin
    var communityActions: [CommunityAction] {
        actionsBySkin[selectedSkin.rawValue] ?? []
    }
    private struct SkinCatalog: Decodable {
        let aliases: [String: [String: String]]
    }
    private var skinAliases: [String: [String: String]] = [:]

    @discardableResult
    func selectSkin(_ skin: Skin) -> Bool {
        guard skin != selectedSkin,
              actionsBySkin[skin.rawValue]?.isEmpty == false else { return false }
        selectedSkin = skin
        defaults.set(skin.rawValue, forKey: "desktopPetSkin")
        return true
    }

    var walkingActions: [CommunityAction] {
        // RED's supplied reactions do not provide a continuous full-body walking cycle.
        guard selectedSkin == .classic else { return [] }
        return [("full.walk", "小跑"), ("full.walk.side", "横向小步走")]
            .filter { clip($0.0) != nil }
            .map { CommunityAction(clipID: $0.0, title: $0.1, category: "走路与跑步") }
    }
    private let communityAliases: [String: String]
    private let bundle: Bundle
    private let defaults: UserDefaults
    private var images: [String: NSImage] = [:]
    private var cgImages: [String: CGImage] = [:]
    private var communityLRU: [String] = []
    private var decodedAtlases: [String: DecodedAtlas] = [:]
    private var liveAtlases: [String: WeakAtlas] = [:]
    let communityCacheBudget = 64 * 1024 * 1024
    var cachedCommunityBytes: Int { decodedAtlases.filter { $0.key.hasPrefix("community.") }.values.reduce(0) { $0 + $1.byteCost } }
    private(set) var communityDecodeCount = 0

    func decodedAtlas(atlasID: String) -> DecodedAtlas? {
        if let atlas = decodedAtlases[atlasID] ?? liveAtlases[atlasID]?.value { return atlas }
        guard !atlasID.hasPrefix("community."), let image = cgImage(atlasID: atlasID),
              let atlas = DecodedAtlas(source: image) else { return nil }
        decodedAtlases[atlasID] = atlas
        return atlas
    }

    private func cache(_ atlas: DecodedAtlas, id: String) {
        decodedAtlases[id] = atlas
        liveAtlases[id] = WeakAtlas(atlas)
        communityLRU.removeAll { $0 == id }
        communityLRU.append(id)
        while cachedCommunityBytes > communityCacheBudget, let evicted = communityLRU.first {
            communityLRU.removeFirst()
            decodedAtlases[evicted] = nil
        }
        liveAtlases = liveAtlases.filter { $0.value.value != nil }
    }
    private var atlasLoads: [String: Task<DecodedAtlas?, Never>] = [:]

    init(bundle: Bundle, defaults: UserDefaults = .standard) throws {
        self.bundle = bundle
        self.defaults = defaults
        selectedSkin = Skin(rawValue: defaults.string(forKey: "desktopPetSkin") ?? "") ?? .classic
        guard let url = bundle.url(forResource: "sprite-manifest", withExtension: "json") else {
            throw RepositoryError.missingManifest
        }
        let base = try SpriteManifest.decode(Data(contentsOf: url))
        let folder = bundle.resourceURL?.appendingPathComponent("CommunityActions", isDirectory: true)
        if let folder, FileManager.default.fileExists(atPath: folder.path) {
            let layoutURL = folder.appendingPathComponent("render-layout.json")
            if FileManager.default.fileExists(atPath: layoutURL.path) {
                renderLayouts = try JSONDecoder().decode([String: RenderLayout].self, from: Data(contentsOf: layoutURL))
            }
            let extra = try SpriteManifest.decode(Data(contentsOf: folder.appendingPathComponent("sprite-manifest.json")))
            let catalog = try JSONDecoder().decode(CommunityCatalog.self, from: Data(contentsOf: folder.appendingPathComponent("catalog.json")))
            let skinsURL = folder.appendingPathComponent("skins.json")
            if FileManager.default.fileExists(atPath: skinsURL.path) {
                skinAliases = try JSONDecoder().decode(SkinCatalog.self, from: Data(contentsOf: skinsURL)).aliases
            }
            // Use only the continuous left-facing running section; exclude the turn,
            // fall and recovery from the full community action. Keep the original clip intact.
            var clips = base.clips + extra.clips
            if let running = catalog.actions.first(where: { $0.title == "原地左转奔跑" }),
               let source = extra.clip(id: running.clipID), source.frames.count >= 52 {
                clips.append(SpriteManifest.Clip(id: "full.walk", atlasID: source.atlasID,
                    looping: true, frames: Array(source.frames[24..<52])))
            }
            if let sideways = catalog.actions.first(where: { $0.title == "螃蟹走路" }),
               let source = extra.clip(id: sideways.clipID), source.frames.count >= 88 {
                clips.append(SpriteManifest.Clip(id: "full.walk.side", atlasID: source.atlasID,
                    looping: true, frames: Array(source.frames[24..<88])))
            }
            manifest = SpriteManifest(schemaVersion: 1,
                atlases: base.atlases + extra.atlases, clips: clips)
            try manifest.validate()
            for action in catalog.actions where manifest.clip(id: action.clipID) == nil {
                throw RepositoryError.invalidCommunityClip(action.clipID)
            }
            for clipID in catalog.aliases.values where manifest.clip(id: clipID) == nil {
                throw RepositoryError.invalidCommunityClip(clipID)
            }
            for aliases in skinAliases.values {
                for clipID in aliases.values where manifest.clip(id: clipID) == nil {
                    throw RepositoryError.invalidCommunityClip(clipID)
                }
            }
            allCommunityActions = catalog.actions
            communityAliases = catalog.aliases
        } else {
            manifest = base
            allCommunityActions = []
            communityAliases = [:]
        }
        actionsBySkin = Dictionary(grouping: allCommunityActions, by: { $0.skin ?? "classic" })
        if actionsBySkin[selectedSkin.rawValue]?.isEmpty != false {
            selectedSkin = .classic
        }
        clipsByID = Dictionary(uniqueKeysWithValues: manifest.clips.map { ($0.id, $0) })
        atlasesByID = Dictionary(uniqueKeysWithValues: manifest.atlases.map { ($0.id, $0) })
    }

    func resolvedClipID(_ id: String) -> String {
        guard id.hasPrefix("full."), !communityActions.isEmpty else { return id }
        if let alternate = skinAliases[selectedSkin.rawValue]?[String(id.dropFirst(5))] { return alternate }
        if id == "full.return" { return "full.community.return" }
        return communityAliases[String(id.dropFirst(5))] ?? id
    }

    func clip(_ id: String) -> SpriteManifest.Clip? { clipsByID[resolvedClipID(id)] }

    private func atlasURL(_ atlas: SpriteManifest.Atlas) -> URL? {
        if atlas.resource.hasPrefix("CommunityActions/") {
            return bundle.resourceURL?.appendingPathComponent(atlas.resource)
        }
        return bundle.url(forResource: atlas.resource, withExtension: "png")
    }

    /// One background decoder; active players retain and share materialized bitmaps.
    func prepareClip(_ clipID: String) async -> Bool {
        guard let clip = clip(clipID) else { return false }
        guard clip.atlasID.hasPrefix("community.") else { return cgImage(atlasID: clip.atlasID) != nil }
        if let existing = decodedAtlas(atlasID: clip.atlasID) {
            cache(existing, id: clip.atlasID)
            return true
        }
        guard let atlas = atlas(clip.atlasID), let url = atlasURL(atlas) else { return false }
        let load: Task<DecodedAtlas?, Never>
        if let existing = atlasLoads[clip.atlasID] {
            load = existing
        } else {
            let queue = Self.decodeQueue
            communityDecodeCount += 1
            load = Task.detached(priority: .utility) {
                await withCheckedContinuation { continuation in
                    queue.addOperation {
                        let decoded: DecodedAtlas? = autoreleasepool {
                            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                                  let image = CGImageSourceCreateImageAtIndex(source, 0,
                                    [kCGImageSourceShouldCache: false] as CFDictionary),
                                  image.width == atlas.pixelWidth, image.height == atlas.pixelHeight else { return nil }
                            return DecodedAtlas(source: image)
                        }
                        continuation.resume(returning: decoded)
                    }
                }
            }
            atlasLoads[clip.atlasID] = load
        }
        let decoded = await load.value
        atlasLoads[clip.atlasID] = nil
        guard let decoded else { return false }
        cache(decoded, id: clip.atlasID)
        return true
    }

    func image(atlasID: String) -> NSImage? {
        if let cached = images[atlasID] { return cached }
        if atlasID.hasPrefix("community.") {
            guard let cgImage = decodedAtlas(atlasID: atlasID)?.image else { return nil }
            return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
        }
        guard let atlas = atlas(atlasID),
              let url = atlasURL(atlas),
              let image = NSImage(contentsOf: url) else { return nil }
        images[atlasID] = image
        return image
    }

    func cgImage(atlasID: String) -> CGImage? {
        if atlasID.hasPrefix("community.") { return decodedAtlas(atlasID: atlasID)?.image }
        if let cached = cgImages[atlasID] { return cached }
        guard !atlasID.hasPrefix("community.") else { return nil }
        guard let image = image(atlasID: atlasID),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        cgImages[atlasID] = cgImage
        return cgImage
    }

    func firstFrameImage(clipID: String, targetSize: NSSize) -> NSImage? {
        guard let clip = clip(clipID), let frame = clip.frames.first,
              let atlas = atlas(clip.atlasID),
              let image = image(atlasID: clip.atlasID) else { return nil }

        let result = NSImage(size: targetSize)
        result.lockFocus()
        let source = NSRect(
            x: frame.rect.x,
            y: Double(atlas.pixelHeight) - frame.rect.y - frame.rect.height,
            width: frame.rect.width,
            height: frame.rect.height
        )
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: source, operation: .sourceOver, fraction: 1)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }

    enum RepositoryError: LocalizedError {
        case missingManifest
        case invalidCommunityClip(String)
        var errorDescription: String? {
            switch self {
            case .missingManifest: return "找不到或无法读取 sprite-manifest.json"
            case let .invalidCommunityClip(id): return "社区动作清单引用了不存在的动作：\(id)"
            }
        }
    }
}
