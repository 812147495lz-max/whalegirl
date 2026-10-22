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
    var onClosed: (() -> Void)?
    var onLoadFailure: (() -> Void)?
    var onPresentationReady: (() -> Void)?
    private let spriteLayer = CALayer()
    private let handoffLayer = CALayer()
    private let sampler: SystemMetricsSampler
    private let aiStore: AIMonitorStore?
    private var aiObservation: AIMonitorObservation?
    private var metricObservation: AIMonitorObservation?
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
                self.layoutPanels(); self.informationView?.reloadMetrics()
            } })
        if let aiStore {
            aiObservation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: AIMonitorStore.changed,
                object: aiStore, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.isActive else { return }
                        self.layoutPanels()
                        self.informationView?.reloadAI()
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
        let cardSize = CGSize(width: min(236, visibleFrame.width - 16), height: min(224 + additionalCardHeight, visibleFrame.height - 16))
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
    }

    private func beginAscent() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        informationPanel?.orderOut(nil)
        state = .ascending
        currentClip = nil
        load("up") { [weak self] clip, bitmap in self?.begin(clip, bitmap: bitmap, animated: true) }
    }
}

@MainActor
final class ComputerInformationView: NSView {
    private let aiStore: AIMonitorStore?
    private let preferences: SystemMetricPreferences
    private let content = NSStackView()
    private var fields: [SystemMetric: NSTextField] = [:]
    private var captions: [SystemMetric: NSTextField] = [:]
    private var meters: [SystemMetric: StatusMeterView] = [:]
    private var lastMetrics = SystemMetricsSnapshot.unavailable
    private var aiSection: AIQuotaSectionView?
    private var glassBackground: NSVisualEffectView?
    private var tintBackground: NSView?
    private var lastOpaqueFallback: Bool?

    override convenience init(frame: NSRect) { self.init(frame: frame, aiStore: nil) }

    init(frame: NSRect, aiStore: AIMonitorStore?, preferences: SystemMetricPreferences = .shared) {
        self.aiStore = aiStore; self.preferences = preferences
        super.init(frame: frame)
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true; layer?.cornerRadius = 20; layer?.masksToBounds = true
        let glass = NSVisualEffectView(frame: bounds)
        glass.material = .popover; glass.blendingMode = .behindWindow; glass.state = .active
        glass.autoresizingMask = [.width, .height]; addSubview(glass); glassBackground = glass
        let tint = InformationGlassTint(frame: bounds)
        tint.autoresizingMask = [.width, .height]; addSubview(tint); tintBackground = tint
        let title = Self.label("运行概览", size: 15, weight: .semibold)
        let gear = NSButton(image: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "选择电脑信息") ?? NSImage(), target: self, action: #selector(showMetricSettings))
        gear.bezelStyle = .inline; gear.isBordered = false; gear.contentTintColor = InformationPalette.blue
        gear.toolTip = "自定义显示的电脑信息"
        let header = NSStackView(views: [title, NSView(), Self.label("♡", size: 12, color: InformationPalette.rose), gear])
        header.orientation = .horizontal; header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false; addSubview(header)
        let scroll = NSScrollView(); scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let document = InformationDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content)
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        let footer = Self.label("鲸鱼娘陪着你", size: 10, color: InformationPalette.secondary)
        footer.translatesAutoresizingMaskIntoConstraints = false; addSubview(footer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            header.heightAnchor.constraint(equalToConstant: 28),
            gear.widthAnchor.constraint(equalToConstant: 28), gear.heightAnchor.constraint(equalToConstant: 28),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -30),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        reloadMetrics()
        setAccessibilityLabel("电脑实时状态")
    }
    required init?(coder: NSCoder) { nil }
    @objc private func showMetricSettings() { SystemMetricSettingsWindow.show() }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                              color: NSColor = InformationPalette.ink) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color
        return label
    }
    private func addRow(_ row: NSView) {
        content.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    func reloadMetrics() {
        for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }
        fields.removeAll(); captions.removeAll(); meters.removeAll(); aiSection = nil
        let enabled = preferences.enabled
        if enabled.contains(.model) {
            let model = Self.label(MacHardwareIdentity.name, size: 11, weight: .semibold)
            model.lineBreakMode = .byTruncatingTail
            model.toolTip = MacHardwareIdentity.name + " · " + MacHardwareIdentity.identifier
            let chip = Self.label(MacHardwareIdentity.chip, size: 10, color: InformationPalette.secondary)
            chip.lineBreakMode = .byTruncatingTail; chip.toolTip = chip.stringValue
            let column = NSStackView(views: [model, chip]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 2
            addRow(column)
            for text in [model, chip] { text.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        }
        let selectedTiles: [SystemMetric] = [.cpu, .gpu, .memory, .storage].filter { enabled.contains($0) }
        for offset in stride(from: 0, to: selectedTiles.count, by: 2) {
            let pair = NSStackView(); pair.orientation = .horizontal; pair.distribution = .fillEqually; pair.spacing = 8
            for metric in selectedTiles[offset..<min(offset + 2, selectedTiles.count)] { pair.addArrangedSubview(tile(metric)) }
            if pair.arrangedSubviews.count == 1 { pair.addArrangedSubview(NSView()) }
            addRow(pair)
        }
        if enabled.contains(.network) {
            let value = NSTextField(wrappingLabelWithString: "—")
            value.textColor = InformationPalette.ink
            value.alignment = .right
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            value.maximumNumberOfLines = 2; value.lineBreakMode = .byWordWrapping
            fields[.network] = value
            let row = NSStackView(views: [Self.label("网络", size: 10, color: InformationPalette.secondary), NSView(), value])
            row.orientation = .horizontal
            value.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.80).isActive = true
            addRow(row)
        }
        for metric in [SystemMetric.battery, .temperature] where enabled.contains(metric) {
            let value = NSTextField(wrappingLabelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); value.textColor = InformationPalette.ink
            value.alignment = .right
            fields[metric] = value
            let name = Self.label(metric == .battery ? "电池" : "温度", size: 10, color: InformationPalette.secondary)
            name.setContentCompressionResistancePriority(.required, for: .horizontal)
            let row = NSStackView(views: [name, NSView(), value]); row.orientation = .horizontal
            value.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.80).isActive = true
            addRow(row)
        }
        if enabled.isEmpty {
            let hint = Self.label("电脑信息已隐藏", size: 10, color: InformationPalette.secondary)
            addRow(hint)
        }
        if let aiStore, aiStore.sectionHeight > 0 {
            let line = NSBox(); line.boxType = .separator; addRow(line)
            let section = AIQuotaSectionView(store: aiStore); aiSection = section
            addRow(section)
            section.heightAnchor.constraint(equalToConstant: aiStore.sectionHeight).isActive = true
        }
        update(lastMetrics)
    }
    func reloadAI() { reloadMetrics() }
    private func tile(_ metric: SystemMetric) -> NSView {
        let card = NSView(); card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.38).cgColor; card.layer?.cornerRadius = 12
        let name: String = switch metric { case .cpu: "CPU"; case .gpu: "GPU"; case .memory: "内存"; default: "储存" }
        let value = Self.label("—", size: 23, weight: .semibold)
        value.font = .monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
        let caption = NSTextField(wrappingLabelWithString: "—")
        caption.font = .systemFont(ofSize: 10); caption.textColor = InformationPalette.secondary
        caption.maximumNumberOfLines = 2
        caption.lineBreakMode = .byWordWrapping
        let bar = StatusMeterView(); fields[metric] = value; captions[metric] = caption; meters[metric] = bar
        let stack = NSStackView(views: [Self.label(name, size: 10, weight: .medium, color: InformationPalette.secondary), value, bar, caption])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor), bar.heightAnchor.constraint(equalToConstant: 3),
            caption.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return card
    }

    static func formattedValues(_ metrics: SystemMetricsSnapshot) -> [String] {
        func bytes(_ value: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
        }
        func rate(_ value: Double?) -> String {
            guard let value, value.isFinite, value >= 0 else { return "—" }
            if value == 0 { return "0 KB/s" }
            return ByteCountFormatter.string(fromByteCount: Int64(min(value, Double(Int64.max / 2))), countStyle: .file) + "/s"
        }
        let cpu = metrics.cpuPercent.flatMap { $0.isFinite ? String(format: "%.0f%%", min(100, max(0, $0))) : nil } ?? "—"
        let memory = metrics.memoryReadingAvailable && metrics.memoryTotalBytes > 0 ? "\(bytes(metrics.memoryUsedBytes)) / \(bytes(metrics.memoryTotalBytes))" : "—"
        let battery = metrics.batteryPercent.map { "\(min(100, max(0, $0)))%" + (metrics.batteryCharging == true ? " · 充电" : "") } ?? "—"
        return [cpu, memory, rate(metrics.downloadBytesPerSecond), rate(metrics.uploadBytesPerSecond), battery]
    }

    func update(_ metrics: SystemMetricsSnapshot) {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if lastOpaqueFallback != opaque {
            glassBackground?.isHidden = opaque
            tintBackground?.needsDisplay = true
            lastOpaqueFallback = opaque
        }
        lastMetrics = metrics
        let values = Self.formattedValues(metrics)
        func percent(_ metric: SystemMetric, _ value: Double?, caption: String) {
            let valid = value.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
            fields[metric]?.stringValue = valid.map { String(format: "%.0f%%", $0) } ?? "—"
            captions[metric]?.stringValue = caption; captions[metric]?.toolTip = caption
            let alert = metric == .storage ? (valid ?? 0) >= 90 : (valid ?? 0) >= 85
            fields[metric]?.textColor = alert ? InformationPalette.warning : InformationPalette.ink
            meters[metric]?.fraction = (valid ?? 0) / 100
        }
        percent(.cpu, metrics.cpuPercent, caption: "实时使用率")
        percent(.memory, metrics.memoryReadingAvailable && metrics.memoryTotalBytes > 0 ? Double(metrics.memoryUsedBytes) / Double(metrics.memoryTotalBytes) * 100 : nil, caption: values[1].replacingOccurrences(of: " / ", with: "\n/ "))
        percent(.gpu, metrics.hardware.gpuPercent, caption: metrics.hardware.gpuPercent == nil ? (metrics.hardware.fetchedAt == nil ? "正在读取…" : "硬件未提供数据") : "最忙 GPU 使用率")
        fields[.gpu]?.toolTip = metrics.hardware.gpuName
        if let used = metrics.hardware.storageUsedBytes, let total = metrics.hardware.storageTotalBytes, total > 0 {
            let bytes: (UInt64) -> String = { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) }
            percent(.storage, Double(used) / Double(total) * 100, caption: bytes(used) + "\n/ " + bytes(total))
            fields[.storage]?.toolTip = "启动磁盘已用 / 总容量；APFS 共享空间，口径可能与系统设置分类不同。"
        } else { percent(.storage, nil, caption: metrics.hardware.fetchedAt == nil ? "正在读取…" : "暂未取得容量") }
        fields[.network]?.stringValue = "↓ " + values[2] + "\n↑ " + values[3]
        fields[.network]?.toolTip = "物理网络接口汇总，不重复累加 VPN 隧道"
        fields[.battery]?.stringValue = metrics.batteryPresent == false ? "无内置电池" : values[4]
        var temperatures: [String] = []
        if let value = metrics.hardware.cpuTemperature { temperatures.append(String(format: "CPU %.0f°C", value)) }
        if let value = metrics.hardware.gpuTemperature { temperatures.append(String(format: "GPU %.0f°C", value)) }
        fields[.temperature]?.stringValue = temperatures.isEmpty ? (metrics.hardware.fetchedAt == nil ? "正在读取…" : "传感器不可用\n热状态 · " + Self.thermalTitle) : temperatures.joined(separator: " · ")
        fields[.temperature]?.toolTip = "只读 CPU/GPU 传感器中的最高温；传感器可用性随机型与系统变化。热状态不是摄氏温度。"
    }
    static var thermalTitle: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "正常"
        case .fair: "温热"
        case .serious: "偏热"
        case .critical: "过热"
        @unknown default: "未知"
        }
    }

}

@MainActor
private final class StatusMeterView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.09, green: 0.28, blue: 0.41, alpha: 0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).fill()
        let amount = fraction.isFinite ? min(1, max(0, fraction)) : 0
        guard amount > 0 else { return }
        let fill = CGRect(x: 0, y: 0, width: bounds.width * amount, height: bounds.height)
        NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.37, blue: 0.69, alpha: 1),
                   ending: NSColor(srgbRed: 0.04, green: 0.61, blue: 0.76, alpha: 1))?.draw(in: fill, angle: 0)
    }
}


@MainActor
enum InformationPalette {
    static let ink = NSColor(srgbRed: 0.10, green: 0.18, blue: 0.26, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.33, green: 0.42, blue: 0.50, alpha: 1)
    static let blue = NSColor(srgbRed: 0.08, green: 0.44, blue: 0.75, alpha: 1)
    static let warning = NSColor(srgbRed: 0.65, green: 0.32, blue: 0.05, alpha: 1)
    static let rose = NSColor(srgbRed: 0.65, green: 0.34, blue: 0.46, alpha: 1)
}

@MainActor
private final class InformationGlassTint: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 20, yRadius: 20)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            NSColor(srgbRed: 0.88, green: 0.95, blue: 0.99, alpha: 1).setFill(); path.fill()
            NSColor(srgbRed: 0.56, green: 0.68, blue: 0.78, alpha: 1).setStroke(); path.stroke()
            return
        }
        NSGradient(starting: NSColor(srgbRed: 0.90, green: 0.97, blue: 1, alpha: 0.66),
                   ending: NSColor(srgbRed: 0.76, green: 0.90, blue: 0.99, alpha: 0.48))?.draw(in: path, angle: -70)
        NSColor.white.withAlphaComponent(0.80).setStroke()
        path.lineWidth = 1; path.stroke()
    }
}

@MainActor
private final class InformationDocumentView: NSView { override var isFlipped: Bool { true } }
