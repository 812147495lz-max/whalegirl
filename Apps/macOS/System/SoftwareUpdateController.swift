import AppKit
import WhaleCore

private final class SoftwareUpdateTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    let progress: @Sendable (Double) -> Void
    init(limit: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.limit = limit; self.progress = progress
    }
    static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["github.com", "api.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host?.lowercased() ?? "")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allowed(request.url) ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit else { downloadTask.cancel(); return }
        progress(min(1, Double(totalBytesWritten) / Double(max(1, limit))))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

@MainActor
final class SoftwareUpdateController {
    static let shared = SoftwareUpdateController()
    private(set) var status = "尚未检查更新"
    private(set) var fraction: Double?
    private(set) var busy = false
    private(set) var ready = false
    private(set) var available: SoftwareUpdatePackage?
    var changed: (() -> Void)?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var window: SoftwareUpdateWindow?
    private var preparedPlan: URL?
    private var currentSession: URLSession?
    private var lastProgressStep = -1
    private var activeTransfer: UUID?
    private var failedVersion: String?
    private var rateLimitReset: TimeInterval?
    private var authenticatedCLI: URL?
    private var cliCheckFailed = false
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "softwareUpdate.automatic.v1") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "softwareUpdate.automatic.v1")
            if !newValue { cancel() }
            notify()
            if newValue { checkIfDue() }
        }
    }
    private func notify() { window?.reload(); changed?() }
    private func setStatus(_ value: String, progress: Double? = nil) {
        status = value; fraction = progress; notify()
    }
    func start() {
        guard timer == nil else { return }
        SoftwareUpdateHelper.acknowledgeLaunch()
        if let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let failure = directory.appendingPathComponent("WhaleGirl/Updates/last-failure.json")
            if let data = try? Data(contentsOf: failure), data.count < 4096,
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let version = result["failedVersion"], SoftwareVersion(version) != nil {
                failedVersion = version
                setStatus("上次更新 \(version) 未完成，当前版本已保留；可手动重试。")
            }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.ready { self.installWhenReady() }
                else { self.checkIfDue() }
            }
        }
        timer.tolerance = 10; self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        // The first check uses the same persisted interval as later checks.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard self?.timer != nil else { return }
            self?.checkIfDue()
        }
    }
    func stop() { timer?.invalidate(); timer = nil; cancel() }
    private func checkIfDue() {
        guard automatic, !busy, !ready else { return }
        let last = UserDefaults.standard.double(forKey: "softwareUpdate.lastAttempt.v1")
        let scheduled = UserDefaults.standard.double(forKey: "softwareUpdate.nextAttempt.v1")
        let due = scheduled > 0 ? scheduled : last + 6 * 3600
        if Date().timeIntervalSince1970 >= due { check(manual: false) }
    }
    func showAndCheck() {
        if window == nil { window = SoftwareUpdateWindow(updater: self) }
        window?.showWindow(nil); window?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !busy, !ready { check(manual: true) }
    }
    func primaryAction() {
        if busy { cancel() }
        else if ready { installWhenReady() }
        else if let available { download(available) }
        else { check(manual: true) }
    }
    func cancel() {
        task?.cancel(); currentSession?.invalidateAndCancel()
        if ready, let plan = preparedPlan {
            try? FileManager.default.removeItem(at: plan.deletingLastPathComponent())
            preparedPlan = nil; ready = false; setStatus("已取消更新，继续使用当前版本。")
        }
    }
    private func session(delegate: SoftwareUpdateTransfer? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 1800
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("WhaleGirl/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }
    private func latestRelease(using connection: URLSession) async throws -> (String, SoftwareUpdatePackage?) {
        rateLimitReset = nil; authenticatedCLI = nil; cliCheckFailed = false
        if let executable = GitHubUpdateCommand.executable() {
            do {
                let data = try await GitHubUpdateCommand(executable: executable, arguments: GitHubUpdateCommand.metadataArguments).execute()
                try Task.checkCancellation()
                let release = try JSONDecoder().decode(GitHubSoftwareRelease.self, from: data)
                let candidate = try release.newerPackage(than: currentVersion)
                authenticatedCLI = executable
                return (release.tag_name, candidate)
            } catch {
                try Task.checkCancellation()
                cliCheckFailed = true
                if let failure = error as? SoftwareUpdateError {
                    if case .download = failure {} else { throw failure }
                } else if error is DecodingError { throw SoftwareUpdateError.invalidRelease }
            }
        }
        do {
            let (data, response) = try await connection.data(for: request(GitHubSoftwareRelease.endpoint))
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url == GitHubSoftwareRelease.endpoint else {
                throw SoftwareUpdateError.download
            }
            if [403, 429].contains(http.statusCode), http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                rateLimitReset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
            }
            guard http.statusCode == 200, data.count <= 2_097_152 else { throw SoftwareUpdateError.download }
            let release = try JSONDecoder().decode(GitHubSoftwareRelease.self, from: data)
            return (release.tag_name, try release.newerPackage(than: currentVersion))
        } catch {
            try Task.checkCancellation()
            // Invalid release identity/digests are rejected; transport/API availability
            // failures alone use the official web-release/checksum alternate route.
            if let e = error as? SoftwareUpdateError {
                if case .download = e {} else { throw error }
            } else if !(error is URLError) { throw error }
            do { return try await latestFromWebsite(using: connection) }
            catch {
                try Task.checkCancellation()
                if rateLimitReset != nil { throw SoftwareUpdateError.rateLimited }
                throw error
            }
        }
    }
    private func latestFromWebsite(using connection: URLSession) async throws -> (String, SoftwareUpdatePackage?) {
        var head = request(GitHubSoftwareRelease.releasesURL.appendingPathComponent("latest"))
        head.httpMethod = "HEAD"; head.setValue("text/html", forHTTPHeaderField: "Accept")
        let (_, response) = try await connection.data(for: head)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let url = http.url else {
            throw SoftwareUpdateError.download
        }
        let tag = try GitHubSoftwareRelease.formalTag(at: url)
        guard let version = SoftwareVersion(tag), let current = SoftwareVersion(currentVersion) else { throw SoftwareUpdateError.invalidRelease }
        guard version > current else { return (tag, nil) }
        let name = "WhaleGirl-\(tag.hasPrefix("v") ? tag : "v" + tag)-Universal.zip"
        let root = "https://github.com/\(GitHubSoftwareRelease.repository)/releases/download/\(tag)/"
        let checksumURL = URL(string: root + "SHA256SUMS-" + tag + ".txt")!
        let limited = session(delegate: SoftwareUpdateTransfer(limit: 65_536, progress: { _ in }))
        defer { limited.invalidateAndCancel() }
        var checksumRequest = request(checksumURL)
        checksumRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (file, checksumResponse) = try await limited.download(for: checksumRequest)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let checksumHTTP = checksumResponse as? HTTPURLResponse, checksumHTTP.statusCode == 200,
              SoftwareUpdateTransfer.allowed(checksumHTTP.url),
              let text = try? String(contentsOf: file, encoding: .utf8), text.utf8.count <= 65_536 else { throw SoftwareUpdateError.missingDigest }
        var packageHead = request(URL(string: root + name)!)
        packageHead.httpMethod = "HEAD"; packageHead.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (_, packageResponse) = try await connection.data(for: packageHead)
        guard let packageHTTP = packageResponse as? HTTPURLResponse, packageHTTP.statusCode == 200,
              SoftwareUpdateTransfer.allowed(packageHTTP.url),
              let size = packageHTTP.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) else { throw SoftwareUpdateError.missingPackage }
        return (tag, try GitHubSoftwareRelease.packageFromChecksum(releaseURL: url, current: currentVersion, text: text, size: size))
    }
    func check(manual: Bool) {
        guard task == nil, !ready else { return }
        available = nil; busy = true; setStatus("正在检查 GitHub 正式版…")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "softwareUpdate.lastAttempt.v1")
        UserDefaults.standard.set(Date().timeIntervalSince1970 + 6 * 3600, forKey: "softwareUpdate.nextAttempt.v1")
        task = Task { [weak self] in
            guard let self else { return }
            var candidate: SoftwareUpdatePackage?
            do {
                let connection = self.session(); self.currentSession = connection
                defer { connection.invalidateAndCancel(); self.currentSession = nil }
                let (tag, foundPackage) = try await self.latestRelease(using: connection)
                candidate = foundPackage
                self.available = candidate
                if let found = candidate {
                    if !manual, self.failedVersion == found.version {
                        candidate = nil
                        self.setStatus("该版本上次更新失败，已暂停自动重试；请手动检查更新。")
                    } else { self.setStatus("发现新版 \(found.version)，可更新并重启。") }
                } else {
                    let channel = self.authenticatedCLI == nil ? "" : "\n已通过本机 GitHub 登录检查。"
                    self.setStatus("当前 \(self.currentVersion) 已是最新可用版本；GitHub 正式版 \(tag)。" + channel)
                }
            } catch {
                if !Task.isCancelled {
                    let now = Date().timeIntervalSince1970
                    let retry = self.rateLimitReset.map { min(now + 6 * 3600, max(now + 300, $0 + 30)) } ?? now + 3600
                    UserDefaults.standard.set(retry, forKey: "softwareUpdate.nextAttempt.v1")
                }
                self.available = nil
                let message = self.cliCheckFailed
                    ? "本机 GitHub CLI 查询未成功，公开通道也暂不可用；稍后自动重试。"
                    : (error as? SoftwareUpdateError)?.localizedDescription ?? "检查失败，请稍后重试或查看 GitHub 发布页。"
                self.setStatus(Task.isCancelled ? "已取消检查。" : message)
            }
            self.busy = false; self.task = nil; self.notify()
            if let candidate, self.automatic, !Task.isCancelled { self.download(candidate) }
        }
    }
    private func download(_ candidate: SoftwareUpdatePackage) {
        guard task == nil, !ready else { return }
        let transferID = UUID(); activeTransfer = transferID
        busy = true; lastProgressStep = -1; setStatus("正在下载 \(candidate.version)…", progress: 0)
        task = Task { [weak self] in
            guard let self else { return }
            var stage: URL?
            do {
                let target = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
                stage = try SoftwareUpdateInstaller.createStage(target: target)
                guard let stage else { throw SoftwareUpdateError.notWritable }
                let capacity = try stage.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                guard capacity > candidate.size * 4 + 256_000_000 else {
                    self.setStatus("磁盘空间不足，请至少留出约 \((candidate.size * 4 + 256_000_000) / 1_000_000_000 + 1) GB 后重试。")
                    throw SoftwareUpdateError.insufficientSpace
                }
                let progress: @Sendable (Double) -> Void = { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.busy, self.activeTransfer == transferID else { return }
                        let step = Int(value * 100)
                        guard step > self.lastProgressStep else { return }
                        self.lastProgressStep = step
                        self.setStatus("正在下载 \(candidate.version)… \(step)%", progress: value)
                    }
                }
                let zip = stage.appendingPathComponent("update.zip")
                if let executable = self.authenticatedCLI {
                    let arguments = ["release", "download", candidate.tag, "--repo", "github.com/" + GitHubSoftwareRelease.repository,
                                     "--pattern", candidate.url.lastPathComponent, "--output", zip.path]
                    _ = try await GitHubUpdateCommand(executable: executable, arguments: arguments, timeout: 1800,
                                                     download: zip, limit: candidate.size, progress: progress).execute()
                } else {
                    let transfer = SoftwareUpdateTransfer(limit: candidate.size, progress: progress)
                    let connection = self.session(delegate: transfer); self.currentSession = connection
                    defer { connection.invalidateAndCancel(); self.currentSession = nil }
                    var downloadRequest = self.request(candidate.url)
                    downloadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                    let (download, response) = try await connection.download(for: downloadRequest)
                    try Task.checkCancellation()
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                          SoftwareUpdateTransfer.allowed(response.url) else { throw SoftwareUpdateError.download }
                    try FileManager.default.moveItem(at: download, to: zip)
                }
                self.activeTransfer = nil
                self.setStatus("正在校验并准备安装 \(candidate.version)…")
                let worker = Task.detached(priority: .utility) {
                    try SoftwareUpdateInstaller.prepare(stage: stage, target: target, package: candidate)
                }
                let plan = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                self.preparedPlan = plan; self.ready = true
                self.setStatus("\(candidate.version) 已准备好，即将更新并重启。", progress: 1)
            } catch {
                self.activeTransfer = nil
                if let stage { try? FileManager.default.removeItem(at: stage) }
                self.setStatus(Task.isCancelled ? "已取消更新，继续使用当前版本。" : (error as? SoftwareUpdateError)?.localizedDescription ?? "下载或校验失败，当前版本未改动。")
            }
            self.busy = false; self.task = nil; self.notify()
            if self.ready, !Task.isCancelled { self.installWhenReady() }
        }
    }
    private func installWhenReady() {
        guard ready, let plan = preparedPlan else { return }
        guard NSApp.modalWindow == nil, !NSApp.windows.contains(where: { $0.attachedSheet != nil }) else {
            setStatus("新版已准备好，等待当前对话框关闭后更新。", progress: 1); return
        }
        do {
            let helper = Process()
            helper.executableURL = plan.deletingLastPathComponent().appendingPathComponent("apply-update")
            helper.arguments = ["--apply-whale-update", plan.path]
            helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
            try helper.run()
            // stop() must not cancel/delete the now-independent transaction.
            ready = false; preparedPlan = nil
            setStatus("正在更新并重启…", progress: 1)
            NSApp.terminate(nil)
        } catch { setStatus("无法启动安装程序，当前版本未改动；可重试。") }
    }
}

@MainActor
private final class SoftwareUpdateWindow: NSWindowController {
    private let updater: SoftwareUpdateController
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let action = NSButton(title: "检查更新", target: nil, action: nil)
    private let automatic = NSButton(checkboxWithTitle: "自动检查、下载并安装新版本", target: nil, action: nil)
    init(updater: SoftwareUpdateController) {
        self.updater = updater
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WhaleGirl · 软件更新"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = NSView(); window.contentView = content
        let title = NSTextField(labelWithString: "软件更新")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let version = NSTextField(labelWithString: "当前版本 \(updater.currentVersion) · GitHub / whalegirl")
        version.font = .systemFont(ofSize: 12); version.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 13); status.maximumNumberOfLines = 3
        status.heightAnchor.constraint(equalToConstant: 55).isActive = true
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1
        progress.widthAnchor.constraint(equalToConstant: 430).isActive = true
        automatic.target = self; automatic.action = #selector(toggleAutomatic)
        automatic.toolTip = "启动后及每6小时检查正式版；新版本校验通过后原位安装并重启。"
        action.target = self; action.action = #selector(primary); action.bezelStyle = .rounded
        let release = NSButton(title: "GitHub 发布页", target: self, action: #selector(openRelease)); release.bezelStyle = .rounded
        let buttons = NSStackView(views: [release, action]); buttons.orientation = .horizontal; buttons.spacing = 12
        let stack = NSStackView(views: [title, version, status, progress, automatic, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
                                     stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24)])
        window.center(); reload()
    }
    required init?(coder: NSCoder) { nil }
    func reload() {
        status.stringValue = updater.status; status.toolTip = updater.status
        automatic.state = updater.automatic ? .on : .off
        progress.isIndeterminate = updater.busy && updater.fraction == nil
        if progress.isIndeterminate { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        progress.doubleValue = updater.fraction ?? 0
        action.title = updater.busy ? "取消" : updater.ready ? "更新并重启" : updater.available == nil ? "检查更新" : "更新并重启"
    }
    @objc private func primary() { updater.primaryAction() }
    @objc private func toggleAutomatic() { updater.automatic = automatic.state == .on }
    @objc private func openRelease() { NSWorkspace.shared.open(GitHubSoftwareRelease.releasesURL) }
}
