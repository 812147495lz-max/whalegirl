import AppKit
import CryptoKit
import Darwin
import WhaleCore

struct SoftwareUpdatePlan: Codable, Sendable {
    let id: String
    let parentPID: Int32
    let target: URL
    let replacement: URL
    let installedVersion: String
    let installedHash: String
    let newVersion: String
}

enum SoftwareUpdateInstaller {
    static let bundleID = "io.whalegirl.app"

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func tool(_ executable: String, _ arguments: [String]) throws -> String {
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.standardOutput = pipe
        try child.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        guard child.terminationStatus == 0 else { throw SoftwareUpdateError.invalidArchive }
        return String(data: output, encoding: .utf8) ?? ""
    }

    static func metadata(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard data.count < 1_048_576,
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw SoftwareUpdateError.incompatible }
        return info
    }

    static func validateApp(_ app: URL, version: String, requiresUpdater: Bool) throws {
        let info = try metadata(app)
        guard info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleExecutable"] as? String == "WhaleGirl",
              let installed = info["CFBundleShortVersionString"] as? String,
              let actualVersion = SoftwareVersion(installed), let expectedVersion = SoftwareVersion(version),
              actualVersion == expectedVersion,
              let minimum = info["LSMinimumSystemVersion"] as? String,
              let requiredOS = SoftwareVersion(minimum),
              let currentOS = SoftwareVersion(ProcessInfo.processInfo.operatingSystemVersionStringNumeric),
              requiredOS <= currentOS,
              !requiresUpdater || (info["WhaleGirlUpdaterProtocolVersion"] as? Int == 1)
        else { throw SoftwareUpdateError.incompatible }
        let fm = FileManager.default
        guard !app.hasDirectoryPath || app.pathExtension == "app",
              app.resolvingSymlinksInPath().standardizedFileURL.path == app.standardizedFileURL.path,
              let entries = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey])
        else { throw SoftwareUpdateError.incompatible }
        for case let entry as URL in entries {
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw SoftwareUpdateError.invalidArchive
            }
        }
        _ = try tool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let architectures = try tool("/usr/bin/lipo", ["-archs", app.appendingPathComponent("Contents/MacOS/WhaleGirl").path])
        guard architectures.contains("arm64"), architectures.contains("x86_64") else { throw SoftwareUpdateError.incompatible }
    }

    static func createStage(target: URL) throws -> URL {
        let fm = FileManager.default, parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", fm.isWritableFile(atPath: parent.path),
              target.resolvingSymlinksInPath().standardizedFileURL.path == target.standardizedFileURL.path,
              !target.path.hasPrefix("/Volumes/"), !target.path.contains("/AppTranslocation/")
        else { throw SoftwareUpdateError.notWritable }
        let stage = parent.appendingPathComponent(".WhaleGirl-update-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return stage
    }

    static func prepare(stage: URL, target: URL, package: SoftwareUpdatePackage) throws -> URL {
        let zip = stage.appendingPathComponent("update.zip")
        guard try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(package.size),
              try hash(zip) == package.sha256 else { throw SoftwareUpdateError.invalidArchive }
        try SoftwareUpdateArchive.validate(zip)
        try Task.checkCancellation()
        let expanded = stage.appendingPathComponent("expanded", isDirectory: true)
        _ = try tool("/usr/bin/ditto", ["-x", "-k", zip.path, expanded.path])
        try Task.checkCancellation()
        let app = expanded.appendingPathComponent("WhaleGirl.app", isDirectory: true)
        try validateApp(app, version: package.version, requiresUpdater: true)
        let old = try metadata(target)
        guard let oldVersion = old["CFBundleShortVersionString"] as? String,
              let before = SoftwareVersion(oldVersion), let after = SoftwareVersion(package.version), after > before
        else { throw SoftwareUpdateError.incompatible }
        let fm = FileManager.default
        let helper = stage.appendingPathComponent("apply-update")
        try fm.copyItem(at: target.appendingPathComponent("Contents/MacOS/WhaleGirl"), to: helper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let plan = SoftwareUpdatePlan(id: String(stage.lastPathComponent.dropFirst(".WhaleGirl-update-".count)),
                                     parentPID: ProcessInfo.processInfo.processIdentifier,
                                     target: target, replacement: app, installedVersion: oldVersion,
                                     installedHash: try hash(target.appendingPathComponent("Contents/MacOS/WhaleGirl")),
                                     newVersion: package.version)
        let planURL = stage.appendingPathComponent("plan.json")
        try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: planURL.path)
        try fm.removeItem(at: zip)
        return planURL
    }
}

private extension ProcessInfo {
    var operatingSystemVersionStringNumeric: String {
        let v = operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

/// Same signed executable runs in a dedicated non-UI mode after its parent exits.
/// The transaction lives next to the installed app, so both renames stay on one volume.
@MainActor
enum SoftwareUpdateHelper {
    static func acknowledgeLaunch() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let value = arguments.first(where: { $0.hasPrefix("--whale-update-token=") }),
              let token = value.split(separator: "=", maxSplits: 1).last,
              UUID(uuidString: String(token)) != nil else { return }
        let stage = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(".WhaleGirl-update-" + token, isDirectory: true)
        guard stage.resolvingSymlinksInPath().standardizedFileURL.path == stage.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: stage.appendingPathComponent("plan.json").path)
        else { return }
        try? Data(token.utf8).write(to: stage.appendingPathComponent("launch-ack"), options: .atomic)
        if let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: cache.appendingPathComponent("WhaleGirl/Updates/last-failure.json"))
        }
    }

    static func run(planURL: URL) -> Int32 {
        let stage = planURL.deletingLastPathComponent(), fm = FileManager.default
        var movedOld = false, installedNew = false
        var plan: SoftwareUpdatePlan?
        let old = stage.appendingPathComponent("previous.app", isDirectory: true)
        func open(_ app: URL, token: String? = nil) throws {
            var args = ["-n", "-a", app.path]
            if let token { args += ["--args", "--whale-update-token=" + token] }
            _ = try SoftwareUpdateInstaller.tool("/usr/bin/open", args)
        }
        do {
            let data = try Data(contentsOf: planURL)
            guard data.count < 16_384 else { throw SoftwareUpdateError.invalidArchive }
            let decoded = try JSONDecoder().decode(SoftwareUpdatePlan.self, from: data)
            guard UUID(uuidString: decoded.id) != nil,
                  stage.lastPathComponent == ".WhaleGirl-update-" + decoded.id,
                  stage.resolvingSymlinksInPath().standardizedFileURL.path == stage.standardizedFileURL.path,
                  decoded.target.deletingLastPathComponent() == stage.deletingLastPathComponent(),
                  decoded.replacement == stage.appendingPathComponent("expanded/WhaleGirl.app", isDirectory: true),
                  decoded.parentPID > 1, decoded.target.pathExtension == "app",
                  let before = SoftwareVersion(decoded.installedVersion),
                  let after = SoftwareVersion(decoded.newVersion), after > before
            else { throw SoftwareUpdateError.invalidArchive }
            plan = decoded
            // Never kill the old process: its normal application shutdown saves state.
            for _ in 0..<600 {
                if kill(decoded.parentPID, 0) != 0 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard kill(decoded.parentPID, 0) != 0,
                  try SoftwareUpdateInstaller.hash(decoded.target.appendingPathComponent("Contents/MacOS/WhaleGirl")) == decoded.installedHash
            else { throw SoftwareUpdateError.incompatible }
            try SoftwareUpdateInstaller.validateApp(decoded.target, version: decoded.installedVersion, requiresUpdater: false)
            try SoftwareUpdateInstaller.validateApp(decoded.replacement, version: decoded.newVersion, requiresUpdater: true)
            try fm.moveItem(at: decoded.target, to: old); movedOld = true
            try fm.moveItem(at: decoded.replacement, to: decoded.target); installedNew = true
            try open(decoded.target, token: decoded.id)
            let ack = stage.appendingPathComponent("launch-ack")
            var started = false
            for _ in 0..<300 {
                if (try? String(contentsOf: ack, encoding: .utf8)) == decoded.id { started = true; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard started else { throw SoftwareUpdateError.incompatible }
            // Successful startup acknowledged: no accumulating rollback/application copies.
            try? fm.removeItem(at: stage)
            return 0
        } catch {
            if let plan {
                if movedOld, installedNew {
                    // Only the replacement we launched is eligible for termination.
                    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: SoftwareUpdateInstaller.bundleID)
                        .filter { $0.bundleURL?.standardizedFileURL == plan.target.standardizedFileURL && $0.processIdentifier != plan.parentPID }
                    applications.forEach { _ = $0.terminate() }
                    for _ in 0..<50 {
                        if applications.allSatisfy({ kill($0.processIdentifier, 0) != 0 }) { break }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    applications.filter { kill($0.processIdentifier, 0) == 0 }.forEach { _ = $0.forceTerminate() }
                    for _ in 0..<50 {
                        if applications.allSatisfy({ kill($0.processIdentifier, 0) != 0 }) { break }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    guard applications.allSatisfy({ kill($0.processIdentifier, 0) != 0 }) else {
                        try? Data("新版未退出；保留原版本供恢复。".utf8).write(to: stage.appendingPathComponent("failure.txt"))
                        return 1
                    }
                    if fm.fileExists(atPath: plan.target.path) {
                        try? fm.moveItem(at: plan.target, to: stage.appendingPathComponent("failed.app"))
                    }
                }
                if movedOld, !fm.fileExists(atPath: plan.target.path) {
                    try? fm.moveItem(at: old, to: plan.target)
                }
                if let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
                    let directory = cache.appendingPathComponent("WhaleGirl/Updates", isDirectory: true)
                    try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let record = try? JSONEncoder().encode(["failedVersion": plan.newVersion])
                    try? record?.write(to: directory.appendingPathComponent("last-failure.json"), options: .atomic)
                }
                if kill(plan.parentPID, 0) != 0,
                   (try? SoftwareUpdateInstaller.hash(plan.target.appendingPathComponent("Contents/MacOS/WhaleGirl"))) == plan.installedHash {
                    try? open(plan.target)
                    try? fm.removeItem(at: stage)
                }
            }
            // An incomplete recovery keeps its transaction instead of deleting the only old app.
            if fm.fileExists(atPath: stage.path) {
                try? Data("更新未完成，已尝试保留原版本。".utf8).write(to: stage.appendingPathComponent("failure.txt"), options: .atomic)
            }
            return 1
        }
    }
}
