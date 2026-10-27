import Foundation

/// Reuses gh's own authenticated transport/keychain. No token is requested,
/// copied, logged or persisted by WhaleGirl. Calls never open a login prompt.
public final class GitHubUpdateCommand: @unchecked Sendable {
    public static func executable() -> URL? {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
    public static let metadataArguments = ["api", "--hostname", "github.com",
        "repos/" + GitHubSoftwareRelease.repository + "/releases/latest", "--jq",
        "{tag_name,draft,prerelease,html_url,assets:[.assets[]|{name,size,digest,state,browser_download_url}]}"]
    private let process = BoundedProcess()
    private let command: BoundedProcess.Command
    private let progress: @Sendable (Double) -> Void

    public init(executable: URL, arguments: [String], timeout: TimeInterval = 25,
                download: URL? = nil, limit: Int64 = 0, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        var command = BoundedProcess.Command(executable, arguments, timeout: timeout, outputLimit: 2_097_152)
        var environment = ProcessInfo.processInfo.environment
        environment["GH_HOST"] = "github.com"; environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"; environment["GH_NO_EXTENSION_UPDATE_NOTIFIER"] = "1"
        environment["GH_PAGER"] = "/bin/cat"; environment["NO_COLOR"] = "1"; environment.removeValue(forKey: "GH_DEBUG")
        command.environment = environment; command.directory = URL(fileURLWithPath: "/", isDirectory: true)
        command.observedFile = download; command.fileLimit = limit
        self.command = command; self.progress = progress
    }
    public func cancel() { process.cancel() }
    public func execute() async throws -> Data {
        do {
            let result = try await process.execute(command, progress: progress)
            if result.cancelled { throw CancellationError() }
            guard result.succeeded else { throw SoftwareUpdateError.download }
            return result.data
        } catch {
            if error is CancellationError { throw error }
            throw SoftwareUpdateError.download
        }
    }
}
