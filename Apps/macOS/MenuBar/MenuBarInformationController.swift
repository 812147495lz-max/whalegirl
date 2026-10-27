import AppKit
import ImageIO
import QuartzCore
import WhaleCore

/// One transient, click-through presentation anchored to the menu icon's rope.
@MainActor
final class MenuBarInformationController {
    enum State { case hidden, loading, descending, showing, ascending }
    struct HandoffPose {
        let image: CGImage
        let frame: CGRect
    }
    struct SourcePoint: Decodable { let x: Double; let y: Double }
    struct Alignment: Decodable {
        let presentationHand: SourcePoint?
        let hoverCrop: SpriteManifest.Rect
        let fallCrop: SpriteManifest.Rect
        let sourceScale: Double
        let offsetX: Double
        let offsetY: Double
    }
    private(set) var state: State = .hidden
    var isActive: Bool { state != .hidden }
    private(set) var frameIndex = 0
    private(set) var characterPanel: NSPanel?
    private(set) var informationPanel: NSPanel?
    private(set) var informationView: ComputerInformationView?
    private(set) var networkSpeechPanel: NSPanel?
    private var networkSpeechTask: Task<Void, Never>?
    var onClosed: (() -> Void)?
    var onLoadFailure: (() -> Void)?
    var onPresentationReady: (() -> Void)?
    private let spriteLayer = CALayer()
    private let handoffLayer = CALayer()
    private let sampler: SystemMetricsSampler
    private let aiStore: AIMonitorStore?
    private var aiObservation: AIMonitorObservation?
    private var metricObservation: AIMonitorObservation?
    private var addressLayoutObservation: AIMonitorObservation?
    private let folder: URL?
    private let manifest: SpriteManifest?
    let alignment: Alignment?
    let informationRevealFrameIndex: Int
    private var hasRevealedInformation = false
    private var handoffPose: HandoffPose?
    private var anchor = CGRect.zero
    private var scale = 1.0
    private var targetScreen: NSScreen?
    private var cardFrame = CGRect.zero
    private var currentClip: SpriteManifest.Clip?
    private var currentBitmap: Bitmap?
    private var animationTimer: Timer?
    private var refreshTimer: Timer?
    private var loadingTask: Task<Void, Never>?
    private var generation = UUID()
    private var closeAfterDescent = false

    private final class Bitmap: @unchecked Sendable {
        let image: CGImage
        nonisolated init(_ image: CGImage) { self.image = image }
    }

    init(bundle: Bundle = .main, sampler: SystemMetricsSampler = .init(), aiStore: AIMonitorStore? = nil) {
        self.sampler = sampler
        self.aiStore = aiStore
        folder = bundle.resourceURL?.appendingPathComponent("ClickAnimations", isDirectory: true)
        manifest = folder.flatMap { try? SpriteManifest.decode(Data(contentsOf: $0.appendingPathComponent("sprite-manifest.json"))) }
        struct Playback: Decodable { let informationRevealFrameIndex: Int }
        struct Metadata: Decodable { let handoff: Alignment; let playback: Playback? }
        let metadata = folder.flatMap {
            try? JSONDecoder().decode(Metadata.self, from: Data(contentsOf: $0.appendingPathComponent("provenance.json")))
        }
        alignment = metadata?.handoff
        let lastFallFrame = max(0, (manifest?.clip(id: "fall")?.frames.count ?? 1) - 1)
        informationRevealFrameIndex = min(lastFallFrame, max(0, metadata?.playback?.informationRevealFrameIndex ?? lastFallFrame))
        metricObservation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: SystemMetricPreferences.changed,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.layoutPanels()
            } })
        addressLayoutObservation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: NetworkAddressStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }; self.layoutPanels()
            }
        })
        if let aiStore {
            aiObservation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: AIMonitorStore.changed,
                object: aiStore, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.isActive else { return }
                        self.layoutPanels()
                        self.informationPanel?.ignoresMouseEvents = false
                    }
                })
        }
    }

    func open(anchor: CGRect, screen: NSScreen, scale: Double, handoffPose: HandoffPose? = nil) {
        guard !isActive else { return }
        guard alignment != nil else { onLoadFailure?(); return }
        self.anchor = anchor
        self.handoffPose = handoffPose
        targetScreen = screen
        self.scale = scale
        closeAfterDescent = false
        hasRevealedInformation = false
        state = .loading
        FullScreenAvoidance.shared.refreshIfNeeded(force: true)
        aiStore?.refresh()
        _ = sampler.sample() // Prime deltas without touching the existing menu CPU sampler.
        load("fall") { [weak self] clip, bitmap in
            guard let self else { return }
            self.state = .descending
            self.prepareCharacterPanel()
            guard self.presentationAllowed() else { self.shutdown(); return }
            self.begin(clip, bitmap: bitmap, animated: true)
            self.characterPanel?.orderFrontRegardless()
            self.onPresentationReady?()
        }
    }

    func close() {
        switch state {
        case .hidden, .ascending: return
        case .loading: shutdown()
        case .descending:
            closeAfterDescent = true
            informationPanel?.orderOut(nil)
            refreshTimer?.invalidate()
            refreshTimer = nil
        case .showing: beginAscent()
        }
    }

    func shutdown() {
        let wasActive = isActive
        dismissNetworkSpeech(); NetworkQuickTestController.dismiss()
        generation = UUID()
        loadingTask?.cancel()
        loadingTask = nil
        animationTimer?.invalidate()
        animationTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        characterPanel?.orderOut(nil)
        informationPanel?.orderOut(nil)
        spriteLayer.contents = nil
        handoffLayer.contents = nil
        handoffPose = nil
        currentBitmap = nil
        currentClip = nil
        closeAfterDescent = false
        hasRevealedInformation = false
        state = .hidden
        if wasActive { onClosed?() }
    }

    func updateLayout(anchor: CGRect, screen: NSScreen, scale: Double) {
        guard isActive else { return }
        self.anchor = anchor
        targetScreen = screen
        self.scale = scale
        handoffPose = handoffPose.map {
            HandoffPose(image: $0.image, frame: Self.hoverPresentationFrame(anchor: anchor,
                visibleFrame: screen.visibleFrame, sourceSize: CGSize(width: $0.image.width, height: $0.image.height),
                displayScale: scale * 1.3))
        }
        layoutPanels()
    }

    private func presentationAllowed() -> Bool {
        guard let targetScreen,
              NSScreen.screens.contains(where: { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                == targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }) else { return false }
        FullScreenAvoidance.shared.refreshIfNeeded()
        return !FullScreenAvoidance.shared.shouldSuppress(on: targetScreen)
    }

    private func load(_ kind: String, completion: @escaping (SpriteManifest.Clip, Bitmap) -> Void) {
        loadingTask?.cancel()
        generation = UUID()
        let request = generation
        guard let folder, let clip = manifest?.clip(id: kind),
              let atlas = manifest?.atlas(id: clip.atlasID) else {
            shutdown()
            onLoadFailure?()
            return
        }
        let url = folder.appendingPathComponent(atlas.resource)
        loadingTask = Task { [weak self] in
            let bitmap = await Task.detached(priority: .userInitiated) {
                Self.decode(url: url, width: atlas.pixelWidth, height: atlas.pixelHeight)
            }.value
            await FullScreenAvoidance.shared.waitForInitialSnapshot()
            guard !Task.isCancelled, let self, self.generation == request else { return }
            self.loadingTask = nil
            guard let bitmap else {
                self.shutdown()
                self.onLoadFailure?()
                return
            }
            completion(clip, bitmap)
        }
    }

    nonisolated private static func decode(url: URL, width: Int, height: Int) -> Bitmap? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                  image.width == width, image.height == height,
                  let context = CGContext(data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage().map(Bitmap.init)
        }
    }

    private func makePanel(size: CGSize) -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenPrimary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        return panel
    }

    private func prepareCharacterPanel() {
        if characterPanel == nil {
            let panel = makePanel(size: CGSize(width: 200, height: 240))
            let view = NSView(frame: panel.contentView?.bounds ?? .zero)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.masksToBounds = true
            spriteLayer.contentsGravity = .resize
            spriteLayer.minificationFilter = .trilinear
            spriteLayer.contentsScale = targetScreen?.backingScaleFactor ?? 2
            view.layer?.addSublayer(spriteLayer)
            handoffLayer.name = "hover-handoff"
            handoffLayer.contentsGravity = .resize
            handoffLayer.minificationFilter = .trilinear
            handoffLayer.contentsScale = targetScreen?.backingScaleFactor ?? 2
            view.layer?.addSublayer(handoffLayer)
            panel.contentView = view
            characterPanel = panel
        }
        layoutPanels()
    }

    static func hoverPresentationFrame(anchor: CGRect, visibleFrame: CGRect, sourceSize: CGSize,
                                       displayScale: Double) -> CGRect {
        let fit = min(102 * displayScale / sourceSize.width, 115 * displayScale / sourceSize.height)
        return DisplayGeometry.frameBelowMenuBar(anchor: anchor,
            size: CGSize(width: sourceSize.width * fit, height: sourceSize.height * fit), visibleFrame: visibleFrame)
    }

    static func presentationFrames(anchor: CGRect, visibleFrame: CGRect, alignment: Alignment,
                                   scale: Double, hoverFrame: CGRect? = nil, additionalCardHeight: CGFloat = 0)
        -> (character: CGRect, canvas: CGRect, card: CGRect, hover: CGRect) {
        let h = alignment.hoverCrop, f = alignment.fallCrop
        let hover = hoverFrame ?? hoverPresentationFrame(anchor: anchor, visibleFrame: visibleFrame,
            sourceSize: CGSize(width: h.width, height: h.height), displayScale: scale * 1.3)
        let px = hover.width / h.width, py = hover.height / h.height
        let width = f.width * alignment.sourceScale * px
        let height = f.height * alignment.sourceScale * py
        let top = hover.maxY - (f.y * alignment.sourceScale + alignment.offsetY - h.y) * py
        let canvas = CGRect(x: hover.minX + (f.x * alignment.sourceScale + alignment.offsetX - h.x) * px,
                            y: top - height, width: width, height: height)
        // Clip to the display, never translate/resize the registered artwork.
        let character = canvas.intersection(visibleFrame)
        let hand = presentationHand(canvas: canvas, alignment: alignment)
        let cardSize = CGSize(width: min(264, visibleFrame.width - 16), height: min(224 + additionalCardHeight, visibleFrame.height - 16))
        var card = CGRect(x: hand.x + 10, y: hand.y - cardSize.height + 44,
                          width: cardSize.width, height: cardSize.height)
        if card.maxX > visibleFrame.maxX - 8 {
            // At the right edge, keep the card below the palm instead of covering the face.
            card.origin = CGPoint(x: min(hand.x - 24, visibleFrame.maxX - cardSize.width - 8),
                                  y: min(hand.y - 12, character.minY - 8) - cardSize.height)
        }
        return (character, canvas, DisplayGeometry.clamp(card, to: visibleFrame), hover)
    }

    /// Raw show-frame palm anchor; stored in provenance so replacement art can move it.
    static func presentationHand(canvas: CGRect, alignment: Alignment) -> CGPoint {
        let source = alignment.presentationHand ?? SourcePoint(x: 810, y: 402)
        let crop = alignment.fallCrop
        return CGPoint(x: canvas.minX + (source.x - crop.x) / crop.width * canvas.width,
                       y: canvas.maxY - (source.y - crop.y) / crop.height * canvas.height)
    }

    private func layoutPanels() {
        guard let targetScreen, let alignment else { return }
        let frames = Self.presentationFrames(anchor: anchor, visibleFrame: targetScreen.visibleFrame,
                                            alignment: alignment, scale: scale, hoverFrame: handoffPose?.frame, additionalCardHeight: (aiStore?.sectionHeight ?? 0) + SystemMetricPreferences.shared.panelBaseHeight - 224)
        cardFrame = frames.card
        characterPanel?.setFrame(frames.character, display: true)
        // AppKit can snap a window origin to backing pixels. Compensate inside
        // that actual window so the shared pose remains at its exact screen rect.
        let actualFrame = characterPanel?.frame ?? frames.character
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.frame = frames.canvas.offsetBy(dx: -actualFrame.minX, dy: -actualFrame.minY)
        handoffLayer.frame = frames.hover.offsetBy(dx: -actualFrame.minX, dy: -actualFrame.minY)
        CATransaction.commit()
        if state == .showing || (state == .descending && hasRevealedInformation) {
            informationPanel?.setFrame(cardFrame, display: true)
        }
    }

    private func begin(_ clip: SpriteManifest.Clip, bitmap: Bitmap, animated: Bool) {
        animationTimer?.invalidate()
        animationTimer = nil
        currentClip = clip
        currentBitmap = bitmap
        frameIndex = animated ? 0 : min(1, clip.frames.count - 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = bitmap.image
        CATransaction.commit()
        displayCurrentFrame()
        if animated {
            let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advanceAnimation() }
            }
            timer.tolerance = 0.002
            animationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func displayCurrentFrame() {
        guard let clip = currentClip, let bitmap = currentBitmap, clip.frames.indices.contains(frameIndex) else { return }
        let rect = clip.frames[frameIndex].rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let useHandoff = clip.id == "fall" && frameIndex == 0 && handoffPose != nil
        spriteLayer.isHidden = useHandoff
        handoffLayer.isHidden = !useHandoff
        handoffLayer.contents = useHandoff ? handoffPose?.image : nil
        spriteLayer.contentsRect = CGRect(x: rect.x / Double(bitmap.image.width),
            y: 1 - (rect.y + rect.height) / Double(bitmap.image.height),
            width: rect.width / Double(bitmap.image.width), height: rect.height / Double(bitmap.image.height))
        CATransaction.commit()
    }

    /// Also used by deterministic tests; production advances via its 30 fps timer.
    func advanceAnimation() {
        guard state == .descending || state == .ascending, let clip = currentClip else { return }
        guard presentationAllowed() else { shutdown(); return }
        if frameIndex + 1 < clip.frames.count {
            frameIndex += 1
            displayCurrentFrame()
            if state == .descending, frameIndex >= informationRevealFrameIndex,
               !closeAfterDescent, !hasRevealedInformation { showInformation() }
            return
        }
        animationTimer?.invalidate()
        animationTimer = nil
        currentClip = nil
        if state == .ascending { shutdown() }
        else if closeAfterDescent { beginAscent() }
        else {
            load("show") { [weak self] clip, bitmap in
                guard let self else { return }
                guard self.presentationAllowed() else { self.shutdown(); return }
                self.state = .showing
                self.begin(clip, bitmap: bitmap, animated: false)
                if self.closeAfterDescent { self.beginAscent() }
                else if !self.hasRevealedInformation { self.showInformation() }
            }
        }
    }

    private func showInformation() {
        hasRevealedInformation = true
        if informationPanel == nil {
            let panel = makePanel(size: cardFrame.size)
            panel.hasShadow = true
            panel.ignoresMouseEvents = false
            let view = ComputerInformationView(frame: CGRect(origin: .zero, size: cardFrame.size), aiStore: aiStore)
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            informationView = view
            informationPanel = panel
        }
        guard let panel = informationPanel else { return }
        informationView?.update(sampler.sample())
        panel.alphaValue = 0
        panel.setFrame(cardFrame.offsetBy(dx: -12, dy: 0), display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(self.cardFrame, display: true)
            panel.animator().alphaValue = 1
        }
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .showing || self.state == .descending else { return }
                guard self.presentationAllowed() else { self.shutdown(); return }
                self.informationView?.update(self.sampler.sample())
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        if ProcessInfo.processInfo.arguments.contains("--show-network-options"), let button = informationView?.networkTestButton {
            NetworkQuickTestController.show(relativeTo: button)
        }
    }

    func showNetworkResult(_ line: String) {
        guard state == .showing, let characterPanel, let screen = targetScreen, presentationAllowed() else { return }
        dismissNetworkSpeech()
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let width: CGFloat = 256
        let textRect = (line as NSString).boundingRect(with: CGSize(width: width - 24, height: 240), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let size = CGSize(width: width, height: ceil(textRect.height) + 26)
        let frame = DisplayGeometry.clamp(CGRect(x: characterPanel.frame.midX - width / 2, y: characterPanel.frame.minY - size.height - 8, width: width, height: size.height), to: screen.visibleFrame)
        let panel = makePanel(size: size); panel.level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.hasShadow = true
        let bubble = HoverSpeechBubbleView(frame: CGRect(origin: .zero, size: size))
        bubble.material = .popover; bubble.blendingMode = .behindWindow; bubble.state = .active
        bubble.tailX = characterPanel.frame.midX - frame.minX
        let label = NSTextField(wrappingLabelWithString: line); label.font = font; label.alignment = .center
        label.frame = CGRect(x: 12, y: 8, width: width - 24, height: size.height - 26)
        bubble.addSubview(label); panel.contentView = bubble; panel.setFrame(frame, display: true)
        label.textColor = InformationPalette.ink
        panel.setAccessibilityLabel("鲸鱼娘消息")
        networkSpeechPanel = panel; panel.orderFrontRegardless()
        networkSpeechTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            self?.dismissNetworkSpeech()
        }
    }
    private func dismissNetworkSpeech() {
        networkSpeechTask?.cancel(); networkSpeechTask = nil
        networkSpeechPanel?.orderOut(nil); networkSpeechPanel = nil
    }
    private func beginAscent() {
        dismissNetworkSpeech(); NetworkQuickTestController.dismiss()
        refreshTimer?.invalidate()
        refreshTimer = nil
        informationPanel?.orderOut(nil)
        state = .ascending
        currentClip = nil
        load("up") { [weak self] clip, bitmap in self?.begin(clip, bitmap: bitmap, animated: true) }
    }
}

/// IPv6 owns the full card width and fits one line, without ellipses or hidden digits.
