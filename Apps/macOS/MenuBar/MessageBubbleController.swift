import AppKit
import AVKit
import ImageIO
import WhaleCore

@MainActor
private final class MessageInteractivePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MessageBubbleController: NSObject {
    private final class Bitmap: @unchecked Sendable {
        let image: CGImage
        nonisolated init(_ image: CGImage) { self.image = image }
    }
    private var panel: NSPanel?
    private var player: AVPlayer?
    private var deadlineTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<MessageDelivery, Never>?
    private var generation = UUID()
    private var reply = NSTextField(string: "")
    private var onReply: ((String) -> Bool)?
    private var onOpenConversation: (() -> Void)?
    private var spaceObservation: AIMonitorObservation?
    var isVisible: Bool { panel?.isVisible == true }
    override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        spaceObservation = AIMonitorObservation(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.dismissed) }
        }, center: center)
    }
    func present(_ message: IncomingMessage, settings: MessageAPISettings, anchor: CGRect, visibleFrame: CGRect,
                 onReply: @escaping (String) -> Bool, onOpenConversation: @escaping () -> Void,
                 onStarted: () -> Void) async -> MessageDelivery {
        finish(.cancelled)
        let request = generation
        return await withTaskCancellationHandler {
            var bitmap: Bitmap?
            var item: AVPlayerItem?
            var lifetime = message.submission.kind == .image ? settings.imageSeconds : settings.textSeconds
            var capped = false
            if let file = message.file {
                if message.submission.kind == .image {
                    bitmap = await Task.detached(priority: .userInitiated) {
                        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary) else { return nil as Bitmap? }
                        return Bitmap(image)
                    }.value
                    guard bitmap != nil else { return .failed }
                } else {
                    let asset = AVURLAsset(url: file, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue, AVURLAssetShouldSupportAliasDataReferencesKey: false])
                    let timeout = Task { @MainActor in
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }; asset.cancelLoading()
                    }
                    do {
                        guard try await asset.load(.isPlayable) else { timeout.cancel(); return .failed }
                        let duration = try await asset.load(.duration).seconds
                        timeout.cancel()
                        guard duration.isFinite, duration > 0 else { return .failed }
                        capped = duration > settings.maxPlaybackSeconds
                        lifetime = capped ? settings.maxPlaybackSeconds : duration + 1
                        item = AVPlayerItem(asset: asset)
                    } catch { timeout.cancel(); return .failed }
                }
            }
            guard !Task.isCancelled, generation == request else { return .cancelled }
            self.onReply = onReply; self.onOpenConversation = onOpenConversation
            let width = min(CGFloat(settings.bubbleWidth), visibleFrame.width - 24)
            let innerWidth = width - 32
            let kind = message.submission.kind
            let measuredText = ((message.submission.text ?? "") as NSString).boundingRect(with: CGSize(width: innerWidth, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 13)])
            let contentHeight: CGFloat
            switch kind {
            case .text: contentHeight = min(220, max(60, ceil(measuredText.height) + 12))
            case .image:
                contentHeight = bitmap.map { min(240, max(80, innerWidth * CGFloat($0.image.height) / CGFloat($0.image.width))) } ?? 160
            case .audio: contentHeight = 65
            case .video: contentHeight = 210
            }
            let captionHeight: CGFloat = kind != .text && !(message.submission.text ?? "").isEmpty ? 42 : 0
            let height = contentHeight + captionHeight + 90
            let desired = CGRect(x: anchor.midX - width / 2, y: anchor.minY - height - 7, width: width, height: height)
            let frame = DisplayGeometry.clamp(desired, to: visibleFrame)
            let panel = MessageInteractivePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "鲸鱼娘消息"
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 1); panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .canJoinAllApplications, .transient, .fullScreenAuxiliary, .ignoresCycle]
            let bubble = HoverSpeechBubbleView(frame: CGRect(origin: .zero, size: frame.size))
            bubble.material = .popover; bubble.blendingMode = .withinWindow; bubble.state = .active
            bubble.tailX = anchor.midX - frame.minX; panel.contentView = bubble
            let title = NSTextField(labelWithString: message.submission.title ?? message.submission.sender ?? "外部消息")
            title.font = .systemFont(ofSize: 12, weight: .semibold); title.textColor = .secondaryLabelColor
            title.frame = CGRect(x: 16, y: height - 34, width: width - 112, height: 18); bubble.addSubview(title)
            let open = NSButton(title: "对话", target: self, action: #selector(openConversation)); open.bezelStyle = .inline
            open.frame = CGRect(x: width - 92, y: height - 36, width: 48, height: 22); bubble.addSubview(open)
            let close = NSButton(title: "×", target: self, action: #selector(dismiss)); close.isBordered = false
            close.frame = CGRect(x: width - 36, y: height - 36, width: 24, height: 22); bubble.addSubview(close)
            let contentFrame = CGRect(x: 16, y: 48 + captionHeight, width: innerWidth, height: contentHeight)
            if kind == .text {
                let scroll = NSScrollView(frame: contentFrame); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
                let text = NSTextView(frame: CGRect(origin: .zero, size: contentFrame.size)); text.isEditable = false; text.isRichText = false
                text.drawsBackground = false; text.font = .systemFont(ofSize: 13); text.textColor = .labelColor
                text.string = message.submission.text ?? ""; text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
                scroll.documentView = text; bubble.addSubview(scroll)
            } else if let bitmap {
                let view = NSImageView(frame: contentFrame); view.image = NSImage(cgImage: bitmap.image, size: .zero)
                view.imageScaling = .scaleProportionallyUpOrDown; bubble.addSubview(view)
            } else if let item {
                let player = AVPlayer(playerItem: item); player.volume = Float(settings.volume); self.player = player
                let view = AVPlayerView(frame: contentFrame); view.player = player; view.controlsStyle = .inline; view.showsFullScreenToggleButton = false
                bubble.addSubview(view)
            }
            if captionHeight > 0 {
                let caption = NSTextField(wrappingLabelWithString: message.submission.text ?? "")
                caption.font = .systemFont(ofSize: 12); caption.maximumNumberOfLines = 2
                caption.frame = CGRect(x: 16, y: 48, width: innerWidth, height: captionHeight - 4); bubble.addSubview(caption)
            }
            reply = NSTextField(string: ""); reply.placeholderString = "回复…"; reply.target = self; reply.action = #selector(sendReply)
            reply.frame = CGRect(x: 16, y: 12, width: width - 100, height: 26); bubble.addSubview(reply)
            let send = NSButton(title: "发送", target: self, action: #selector(sendReply)); send.frame = CGRect(x: width - 78, y: 12, width: 62, height: 26); bubble.addSubview(send)
            self.panel = panel
            let result = await withCheckedContinuation { continuation in
                self.continuation = continuation
                panel.orderFrontRegardless(); self.player?.play(); onStarted()
                let initialLifetime = lifetime, wasCapped = capped
                self.deadlineTask = Task { @MainActor [weak self] in
                    var elapsed = 0.0
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        guard let self else { return }
                        if self.panel?.isKeyWindow == true || !self.reply.stringValue.isEmpty { continue }
                        if let player = self.player {
                            if player.currentItem?.status == .failed { self.finish(.failed); return }
                            if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0,
                               player.currentTime().seconds >= duration - 0.08 { self.finish(.completed); return }
                        }
                        // Reading or composing a reply pins a text/image bubble.
                        elapsed += 0.1
                        if elapsed >= initialLifetime { self.finish(wasCapped ? .dismissed : .completed); return }
                    }
                }
            }
            return result
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == request else { return }
                self.finish(.cancelled)
            }
        }
    }
    func finish(_ result: MessageDelivery) {
        generation = UUID(); deadlineTask?.cancel(); deadlineTask = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        panel?.orderOut(nil); panel?.close(); panel = nil; onReply = nil; onOpenConversation = nil
        let waiting = continuation; continuation = nil; waiting?.resume(returning: result)
    }
    @objc private func dismiss() { finish(.dismissed) }
    @objc private func openConversation() { onOpenConversation?() }
    @objc private func sendReply() {
        guard onReply?(reply.stringValue) == true else { reply.placeholderString = "未发送，请在对话窗口检查"; return }
        finish(.completed)
    }
}
