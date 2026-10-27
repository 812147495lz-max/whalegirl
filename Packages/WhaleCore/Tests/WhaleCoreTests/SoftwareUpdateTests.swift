import Foundation
import XCTest
@testable import WhaleCore

final class SoftwareUpdateTests: XCTestCase {
    @MainActor
    func testGitHubCommandOutputBoundTimeoutAndNoninteractiveEnvironment() async throws {
        let environment = GitHubUpdateCommand(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$GH_PROMPT_DISABLED\""])
        let data = try await environment.execute()
        XCTAssertEqual(String(data: data, encoding: .utf8), "1")
        let began = Date()
        let hang = GitHubUpdateCommand(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 1>&-; exec /bin/sleep 30"], timeout: 0.2)
        do { _ = try await hang.execute(); XCTFail("stdout-closed child escaped timeout") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
        let overflow = GitHubUpdateCommand(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["fixture"])
        do { _ = try await overflow.execute(); XCTFail("unbounded command output accepted") } catch {}
    }
    @MainActor
    func testGitHubCommandCancellationAndDownloadLimit() async throws {
        let command = GitHubUpdateCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        let task = Task { try await command.execute() }
        try await Task.sleep(for: .milliseconds(80)); task.cancel()
        do { _ = try await task.value; XCTFail("cancelled child survived") }
        catch { XCTAssertTrue(error is CancellationError) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("whale-download-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let tooLarge = GitHubUpdateCommand(executable: URL(fileURLWithPath: "/usr/bin/mkfile"),
            arguments: ["-n", "4096", file.path], download: file, limit: 16)
        do { _ = try await tooLarge.execute(); XCTFail("oversized command download accepted") } catch {}
    }
    func testVersionsCompareNumericallyWithoutDowngrade() {
        XCTAssertTrue(SoftwareVersion("v1.10")! > SoftwareVersion("1.9.9")!)
        XCTAssertEqual(SoftwareVersion("1.7"), SoftwareVersion("v1.7.0"))
        XCTAssertTrue(SoftwareVersion("1.6.2")! > SoftwareVersion("1.5")!)
        for bad in ["", "v", "1..7", "1.7-beta", "../1.8", "1.2.3.4.5", "999999999999999999999999"] {
            XCTAssertNil(SoftwareVersion(bad))
        }
    }

    private func release(_ patch: [String: Any] = [:], assetPatch: [String: Any] = [:]) throws -> GitHubSoftwareRelease {
        let repo = GitHubSoftwareRelease.repository
        var asset: [String: Any] = ["name": "WhaleGirl-v1.8-Universal.zip", "size": 100,
            "digest": "sha256:" + String(repeating: "a", count: 64), "state": "uploaded",
            "browser_download_url": "https://github.com/\(repo)/releases/download/v1.8/WhaleGirl-v1.8-Universal.zip"]
        asset.merge(assetPatch) { _, v in v }
        var object: [String: Any] = ["tag_name": "v1.8", "draft": false, "prerelease": false,
            "html_url": "https://github.com/\(repo)/releases/tag/v1.8", "assets": [asset]]
        object.merge(patch) { _, v in v }
        return try JSONDecoder().decode(GitHubSoftwareRelease.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testOnlyNewerOfficialReleaseProducesPackage() throws {
        let r = try release()
        XCTAssertNil(try r.newerPackage(than: "1.9"))
        XCTAssertNil(try r.newerPackage(than: "1.8.0"))
        let p = try XCTUnwrap(r.newerPackage(than: "1.7"))
        XCTAssertEqual(p.version, "1.8"); XCTAssertEqual(p.sha256, String(repeating: "a", count: 64))
    }
    func testOfficialWebsiteChecksumFallback() throws {
        let url = URL(string: "https://github.com/\(GitHubSoftwareRelease.repository)/releases/tag/v1.8")!
        let hash = String(repeating: "b", count: 64)
        let sums = hash + "  WhaleGirl-v1.8-Universal.zip\n" + String(repeating: "a", count: 64) + "  WhaleGirl-v1.8-Universal.dmg\n"
        let package = try GitHubSoftwareRelease.packageFromChecksum(releaseURL: url, current: "1.7", text: sums, size: 500)
        XCTAssertEqual(package?.sha256, hash)
        XCTAssertEqual(package?.version, "1.8")
        XCTAssertNil(try GitHubSoftwareRelease.packageFromChecksum(releaseURL: url, current: "1.9", text: "", size: 0))
        XCTAssertEqual(try GitHubSoftwareRelease.formalTag(at: url), "v1.8")
    }
    func testFallbackRejectsForeignReleaseWrongChecksumDuplicateAndOversize() throws {
        let url = URL(string: "https://github.com/\(GitHubSoftwareRelease.repository)/releases/tag/v1.8")!
        let sum = String(repeating: "a", count: 64) + "  WhaleGirl-v1.8-Universal.zip\n"
        for text in ["", "invalid  WhaleGirl-v1.8-Universal.zip", sum + sum,
                     String(repeating: "a", count: 64) + "  Wrong.zip"] {
            XCTAssertThrowsError(try GitHubSoftwareRelease.packageFromChecksum(releaseURL: url, current: "1.7", text: text, size: 500))
        }
        XCTAssertThrowsError(try GitHubSoftwareRelease.packageFromChecksum(releaseURL: url, current: "1.7", text: sum, size: 2_000_000_000))
        for wrong in ["https://example.com/releases/tag/v1.8", "https://github.com/other/repo/releases/tag/v1.8",
                      "https://github.com/\(GitHubSoftwareRelease.repository)/releases/tag/v1.8-beta"] {
            XCTAssertThrowsError(try GitHubSoftwareRelease.formalTag(at: URL(string: wrong)!))
        }
    }
    func testDraftPrereleaseBadTagsAndWrongRepositoryRejected() throws {
        for patch: [String: Any] in [["draft": true], ["prerelease": true], ["tag_name": "v1.8-beta"],
            ["html_url": "https://github.com/attacker/whalegirl/releases/tag/v1.8"]] {
            XCTAssertThrowsError(try release(patch).newerPackage(than: "1.7"))
        }
    }
    func testWrongURLNameSizeAndMissingHashRejected() throws {
        for patch: [String: Any] in [["name": "WhaleGirl.dmg"], ["size": 0], ["size": 2_000_000_000],
            ["digest": NSNull()], ["digest": "sha256:bad"], ["digest": "md5:" + String(repeating: "a", count: 64)],
            ["browser_download_url": "https://example.com/WhaleGirl-v1.8-Universal.zip"], ["state": "new"]] {
            XCTAssertThrowsError(try release(assetPatch: patch).newerPackage(than: "1.7"))
        }
        let r = try release()
        let data = try JSONEncoderFixture.encodeDuplicatedAssets(r)
        XCTAssertThrowsError(try JSONDecoder().decode(GitHubSoftwareRelease.self, from: data).newerPackage(than: "1.7"))
    }

    private struct Entry {
        let name: String
        var localName: String? = nil
        var mode: UInt32 = 0o100644
        var flags: UInt16 = 0
        var uncompressed: UInt32 = 1
    }
    private func archive(_ extras: [Entry] = []) -> Data {
        var content = Data(), central = Data()
        let entries = [Entry(name: "WhaleGirl.app/Contents/Info.plist"), Entry(name: "WhaleGirl.app/Contents/MacOS/WhaleGirl")] + extras
        func number<T: FixedWidthInteger>(_ n: T) -> Data {
            var value = n.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        for e in entries {
            let name = Data(e.name.utf8), local = Data((e.localName ?? e.name).utf8)
            let offset = UInt32(content.count)
            content += number(UInt32(0x04034b50)) + number(UInt16(20)) + number(e.flags) + number(UInt16(0))
            content += Data(repeating: 0, count: 8) + number(UInt32(1)) + number(e.uncompressed)
            content += number(UInt16(local.count)) + number(UInt16(0)) + local + Data([1])
            central += number(UInt32(0x02014b50)) + number(UInt16(0x0314)) + number(UInt16(20)) + number(e.flags) + number(UInt16(0))
            central += Data(repeating: 0, count: 8) + number(UInt32(1)) + number(e.uncompressed)
            central += number(UInt16(name.count)) + Data(repeating: 0, count: 8) + number(e.mode << 16) + number(offset) + name
        }
        let end = number(UInt32(0x06054b50)) + Data(repeating: 0, count: 4)
            + number(UInt16(entries.count)) + number(UInt16(entries.count))
            + number(UInt32(central.count)) + number(UInt32(content.count)) + number(UInt16(0))
        return content + central + end
    }
    private func validate(_ data: Data) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url); try SoftwareUpdateArchive.validate(url)
    }
    func testNormalArchiveAccepted() throws { try validate(archive()) }
    func testTraversalAbsoluteUnrelatedAndSymlinkRejected() {
        for name in ["../escape", "/tmp/escape", "WhaleGirl.app/../../escape", "WhaleGirl.app/Contents/../Info.plist", "unrelated.sh", "WhaleGirl.app\\escape"] {
            XCTAssertThrowsError(try validate(archive([Entry(name: name)])))
        }
        XCTAssertThrowsError(try validate(archive([Entry(name: "WhaleGirl.app/link", mode: 0o120777)])))
    }
    func testLocalHeaderMismatchDuplicateAndEncryptedEntriesRejected() {
        XCTAssertThrowsError(try validate(archive([Entry(name: "WhaleGirl.app/test", localName: "WhaleGirl.app/evil")])))
        XCTAssertThrowsError(try validate(archive([Entry(name: "WhaleGirl.app/Contents/Info.plist")])))
        XCTAssertThrowsError(try validate(archive([Entry(name: "WhaleGirl.app/encrypted", flags: 1)])))
        XCTAssertThrowsError(try validate(archive([Entry(name: "WhaleGirl.app/bomb", uncompressed: 4_000_000_001)])))
    }
    func testTruncatedAndEmptyArchiveRejected() {
        XCTAssertThrowsError(try validate(Data()))
        XCTAssertThrowsError(try validate(archive().dropLast(2)))
    }
}

private enum JSONEncoderFixture {
    static func encodeDuplicatedAssets(_ release: GitHubSoftwareRelease) throws -> Data {
        let repo = GitHubSoftwareRelease.repository
        let a = release.assets[0]
        let asset: [String: Any] = ["name": a.name, "size": a.size, "digest": a.digest!,
            "state": a.state, "browser_download_url": a.browser_download_url.absoluteString]
        return try JSONSerialization.data(withJSONObject: ["tag_name": "v1.8", "draft": false, "prerelease": false,
            "html_url": "https://github.com/\(repo)/releases/tag/v1.8", "assets": [asset, asset]])
    }
}
