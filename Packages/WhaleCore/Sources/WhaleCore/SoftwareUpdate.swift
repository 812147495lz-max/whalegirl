import Foundation

public struct SoftwareVersion: Comparable, Sendable, Equatable {
    private let parts: [Int]
    public init?(_ value: String) {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let components = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count), components.allSatisfy({
            !$0.isEmpty && $0.count <= 8 && $0.allSatisfy { $0.isASCII && $0.isNumber }
        }) else { return nil }
        let parsed = components.compactMap { Int($0) }
        guard parsed.count == components.count else { return nil }
        parts = parsed + Array(repeating: 0, count: 4 - parsed.count)
    }
    public static func < (a: Self, b: Self) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

public enum SoftwareUpdateError: Error, LocalizedError, Sendable {
    case invalidRelease, missingPackage, missingDigest, invalidArchive, download, incompatible, notWritable, insufficientSpace, rateLimited
    public var errorDescription: String? {
        switch self {
        case .invalidRelease: "发布信息无效，已保留当前版本。"
        case .missingPackage: "新版尚未提供可自动安装的 Universal ZIP，请查看 GitHub 发布页。"
        case .missingDigest: "发布包缺少有效的 SHA-256，无法自动安装。"
        case .invalidArchive: "更新包结构或校验不正确，已停止安装。"
        case .rateLimited: "GitHub匿名接口已限流，备用发布页暂不可达；稍后会自动重试。"
        case .download: "无法从 GitHub 获取更新，请检查网络后重试。"
        case .incompatible: "更新包与当前软件或系统不兼容，已保留当前版本。"
        case .insufficientSpace: "磁盘空间不足，请清理空间后重试。"
        case .notWritable: "应用所在文件夹不可写。请将鲸鱼娘移到可写的 Applications 文件夹后更新。"
        }
    }
}

public struct GitHubSoftwareRelease: Decodable, Sendable {
    public static let repository = "812147495lz-max/whalegirl"
    public static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let size: Int64
        public let digest: String?
        public let state: String
        public let browser_download_url: URL
    }
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public let html_url: URL
    public let assets: [Asset]

    public static func formalTag(at url: URL) throws -> String {
        let tag = url.lastPathComponent
        guard SoftwareVersion(tag) != nil,
              url.absoluteString == "https://github.com/\(repository)/releases/tag/\(tag)"
        else { throw SoftwareUpdateError.invalidRelease }
        return tag
    }

    /// The official /releases/latest redirect is the alternate authority when
    /// anonymous REST requests are rate-limited. The checksum is fetched from
    /// that same tagged release, never from an unrelated mirror.
    public static func packageFromChecksum(releaseURL: URL, current: String, text: String, size: Int64) throws -> SoftwareUpdatePackage? {
        let tag = try formalTag(at: releaseURL)
        guard let currentVersion = SoftwareVersion(current), let latest = SoftwareVersion(tag) else {
            throw SoftwareUpdateError.invalidRelease
        }
        guard latest > currentVersion else { return nil }
        let filename = "WhaleGirl-\(tag.hasPrefix("v") ? tag : "v" + tag)-Universal.zip"
        let rows = text.replacingOccurrences(of: "\u{FEFF}", with: "").split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, parts[1] == filename || parts[1] == "*" + filename else { return nil }
            return String(parts[0]).lowercased()
        }
        guard rows.count == 1, let hash = rows.first, hash.count == 64,
              hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw SoftwareUpdateError.missingDigest }
        guard size > 0, size <= 1_500_000_000 else { throw SoftwareUpdateError.missingPackage }
        return SoftwareUpdatePackage(tag: tag, version: String(tag.drop(while: { $0 == "v" })),
                                     url: URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(filename)")!,
                                     size: size, sha256: hash)
    }

    public func newerPackage(than current: String) throws -> SoftwareUpdatePackage? {
        guard !draft, !prerelease, let version = SoftwareVersion(tag_name),
              let installed = SoftwareVersion(current),
              html_url.absoluteString == "https://github.com/\(Self.repository)/releases/tag/\(tag_name)"
        else { throw SoftwareUpdateError.invalidRelease }
        guard version > installed else { return nil }
        let expected = "WhaleGirl-\(tag_name.hasPrefix("v") ? tag_name : "v" + tag_name)-Universal.zip"
        let matches = assets.filter { $0.name == expected && $0.state == "uploaded" }
        guard matches.count == 1, let asset = matches.first, asset.size > 0, asset.size <= 1_500_000_000,
              asset.browser_download_url.absoluteString == "https://github.com/\(Self.repository)/releases/download/\(tag_name)/\(expected)"
        else { throw SoftwareUpdateError.missingPackage }
        guard let digest = asset.digest, digest.hasPrefix("sha256:") else { throw SoftwareUpdateError.missingDigest }
        let hash = String(digest.dropFirst(7)).lowercased()
        guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw SoftwareUpdateError.missingDigest
        }
        return SoftwareUpdatePackage(tag: tag_name, version: String(tag_name.drop(while: { $0 == "v" })),
                                     url: asset.browser_download_url, size: asset.size, sha256: hash)
    }
}

public struct SoftwareUpdatePackage: Sendable {
    public let tag: String
    public let version: String
    public let url: URL
    public let size: Int64
    public let sha256: String
}

/// Check central and local ZIP headers before ditto sees any entry. No ZIP64,
/// encrypted entries, symbolic links, traversal, or unrelated top-level payloads.
public enum SoftwareUpdateArchive {
    public static func validate(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 22, size <= 1_500_000_000 else { throw SoftwareUpdateError.invalidArchive }
        let tailSize = min(size, 65_557)
        try file.seek(toOffset: size - tailSize)
        let tail = [UInt8](try file.read(upToCount: Int(tailSize)) ?? Data())
        func integer(_ bytes: [UInt8], _ offset: Int, _ count: Int) throws -> UInt64 {
            guard offset >= 0, offset + count <= bytes.count else { throw SoftwareUpdateError.invalidArchive }
            return (0..<count).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
        }
        var end: Int?
        for i in stride(from: tail.count - 22, through: 0, by: -1) {
            if try integer(tail, i, 4) == 0x06054b50,
               i + 22 + Int(try integer(tail, i + 20, 2)) == tail.count { end = i; break }
        }
        guard let end, try integer(tail, end + 4, 2) == 0,
              try integer(tail, end + 6, 2) == 0 else { throw SoftwareUpdateError.invalidArchive }
        let count = Int(try integer(tail, end + 10, 2))
        let directorySize = try integer(tail, end + 12, 4)
        let directoryOffset = try integer(tail, end + 16, 4)
        guard count > 0, count <= 30_000, try integer(tail, end + 8, 2) == UInt64(count),
              directorySize <= 16_777_216,
              directoryOffset + directorySize == size - tailSize + UInt64(end)
        else { throw SoftwareUpdateError.invalidArchive }
        try file.seek(toOffset: directoryOffset)
        let directory = [UInt8](try file.read(upToCount: Int(directorySize)) ?? Data())
        var offset = 0, total: UInt64 = 0, seen = Set<String>()
        var foundInfo = false, foundExecutable = false
        for _ in 0..<count {
            guard try integer(directory, offset, 4) == 0x02014b50 else { throw SoftwareUpdateError.invalidArchive }
            let flags = try integer(directory, offset + 8, 2)
            let method = try integer(directory, offset + 10, 2)
            let compressed = try integer(directory, offset + 20, 4)
            let uncompressed = try integer(directory, offset + 24, 4)
            let nameSize = Int(try integer(directory, offset + 28, 2))
            let extraSize = Int(try integer(directory, offset + 30, 2))
            let commentSize = Int(try integer(directory, offset + 32, 2))
            let mode = try integer(directory, offset + 38, 4) >> 16
            let localOffset = try integer(directory, offset + 42, 4)
            let next = offset + 46 + nameSize + extraSize + commentSize
            guard next <= directory.count, nameSize > 0, flags & 0x41 == 0,
                  method == 0 || method == 8, mode & 0xf000 != 0xa000,
                  try integer(directory, offset + 34, 2) == 0,
                  let name = String(bytes: directory[(offset + 46)..<(offset + 46 + nameSize)], encoding: .utf8),
                  !name.contains("\\"), !name.contains(":"), !name.contains("\0"),
                  !name.contains("\n"), !name.contains("\r"), !name.hasPrefix("/"),
                  !name.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
                  !name.split(separator: "/", omittingEmptySubsequences: false).contains("."),
                  !name.contains("//"),
                  name.hasPrefix("WhaleGirl.app/") || name == "WhaleGirl.app" || name.hasPrefix("__MACOSX/"),
                  seen.insert(name.lowercased()).inserted,
                  localOffset + 30 < directoryOffset
            else { throw SoftwareUpdateError.invalidArchive }
            total += uncompressed
            guard total <= 4_000_000_000 else { throw SoftwareUpdateError.invalidArchive }
            try file.seek(toOffset: localOffset)
            let local = [UInt8](try file.read(upToCount: 30) ?? Data())
            guard try integer(local, 0, 4) == 0x04034b50,
                  try integer(local, 6, 2) == flags, try integer(local, 8, 2) == method,
                  try integer(local, 26, 2) == UInt64(nameSize) else { throw SoftwareUpdateError.invalidArchive }
            let localExtra = try integer(local, 28, 2)
            let localName = try file.read(upToCount: nameSize) ?? Data()
            guard localName == Data(directory[(offset + 46)..<(offset + 46 + nameSize)]),
                  localOffset + 30 + UInt64(nameSize) + localExtra + compressed <= directoryOffset
            else { throw SoftwareUpdateError.invalidArchive }
            foundInfo = foundInfo || name == "WhaleGirl.app/Contents/Info.plist"
            foundExecutable = foundExecutable || name == "WhaleGirl.app/Contents/MacOS/WhaleGirl"
            offset = next
        }
        guard offset == directory.count, foundInfo, foundExecutable else { throw SoftwareUpdateError.invalidArchive }
    }
}
