import Foundation
import WhaleCore

/// Automatic app data must not require access to protected user document folders.
enum WhaleGirlUserFiles {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WhaleGirl/UserData", isDirectory: true)
}

/// Editable, original short lines for the community-inspired DeepSeek-chan voice.
@MainActor
enum DeepSeekChanDialog {
    static let builtInLines = [
        "主人来啦？本鲸的算力刚好空着。",
        "事情可以慢慢想，饭要趁热吃。",
        "我在深度思考，尾巴只是顺便摇摇。",
        "这点问题，交给本鲸和一碗米饭。",
        "别催，我的思路正在海里转弯。",
        "报告主人，摸鱼进度已完成，开始认真。",
        "算力在转，脑子在转，尾巴转得最快。",
        "你先忙，我负责可爱和待机。",
        "再给我三秒……好，三秒到了，我继续想。",
        "我没有偷懒，我是在后台节能。",
        "本鲸的答案很稳，饭量也很稳。",
        "思路游远了？等我把它捞回来。",
        "主人上线，本鲸切到认真模式。",
        "想听答案？先夸夸我的尾巴。",
        "我先把问题想复杂，再替你讲简单。",
        "今天的 token 配额，不能浪费在发呆上。",
        "这不是摆烂，是鲸鱼式待机。",
        "嗯？叫本鲸有什么事，饭点除外也可以。",
        "别看我圆，处理问题可一点不绕圈。",
        "本鲸准备好了，问题和零食都可以上。",
        "等我眨完眼，就来帮你。",
        "主人放心，尾巴摇着，脑子也没停。",
        "这条思路不错，我先收进小鱼干罐头里。",
        "你说吧，本鲸今天心情不错。"
    ]

    static let fileURL = WhaleGirlUserFiles.directory.appendingPathComponent("气泡文案.csv")
    private static let store = DialogueCSVStore(url: fileURL, defaults: builtInLines)
    static var lines: [String] { store.currentLines() }
    static func prepareFile() throws { try store.ensureFile() }

    static func randomLine(excluding previous: String? = nil) -> String {
        let current = lines
        let candidates = current.filter { $0 != previous }
        return (candidates.isEmpty ? current : candidates).randomElement() ?? "本鲸今天也在认真待机。"
    }
}

/// Reads only on a speech request; retains valid lines across partial saves and I/O errors.
@MainActor
final class DialogueCSVStore {
    let url: URL
    private var lastGood: [String]
    init(url: URL, defaults: [String]) { self.url = url; lastGood = defaults }

    func ensureFile() throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Never overwrite a user file, including one created between the existence check and write.
        try Data(DialogueCSV.encode(lastGood).utf8).write(to: url, options: [.withoutOverwriting])
    }

    func currentLines() -> [String] {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { return lastGood }
            let text: String?
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                text = String(data: data, encoding: .utf16)
            } else { text = String(data: data, encoding: .utf8) }
            if let text { lastGood = try DialogueCSV.decode(text) }
        } catch { /* Editors can temporarily replace/truncate the file. Keep the last good list. */ }
        return lastGood
    }
}
