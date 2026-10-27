import AppKit
import QuartzCore
import WhaleCore

@MainActor
final class HoverCharacterPanel {
    private var panel: NSPanel?
    private let imageView = NSImageView(frame: .zero)
    private var speechPanel: NSPanel?
    private let speechLabel = NSTextField(labelWithString: "")
    private var speechLine: String?
    private var characterFrame: CGRect?
    private var visibleFrame: CGRect?
    private var speechFadeTask: Task<Void, Never>?
    private var speechGeneration = UUID()
    private let shouldSuppress: @MainActor (NSScreen) -> Bool
    init(shouldSuppress: @escaping @MainActor (NSScreen) -> Bool) { self.shouldSuppress = shouldSuppress }
    var currentSpeechLine: String? { speechLine }
    var currentSpeechPanel: NSPanel? { speechPanel }


    func show(image: NSImage, anchor: CGRect, screen: NSScreen, scale: Double) {
        guard !shouldSuppress(screen) else {
            if panel?.isVisible == true || speechPanel?.isVisible == true { shutdown() }
            return
        }
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return }

        // The visible artwork should occupy roughly the marked menu-bar area
        // from the supplied screenshot, while still following the size slider.
        let panelFrame = MenuBarInformationController.hoverPresentationFrame(anchor: anchor,
            visibleFrame: screen.visibleFrame, sourceSize: CGSize(width: cgImage.width, height: cgImage.height),
            displayScale: scale)
        let imageSize = panelFrame.size
        let imageFrame = CGRect(origin: .zero, size: imageSize)
        let frameChanged = characterFrame != panelFrame
        characterFrame = panelFrame
        visibleFrame = screen.visibleFrame
        if panel == nil {
            let newPanel = NSPanel(contentRect: panelFrame,
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered,
                                   defer: false)
            newPanel.backgroundColor = .clear
            newPanel.isOpaque = false
            newPanel.hasShadow = false
            newPanel.level = .statusBar
            newPanel.hidesOnDeactivate = false
            newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
            newPanel.ignoresMouseEvents = true
            newPanel.contentView = imageView
            panel = newPanel
        }

        imageView.frame = imageFrame
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.image = NSImage(cgImage: cgImage, size: imageSize)
        panel?.setFrame(panelFrame, display: true)
        panel?.orderFrontRegardless()
        if frameChanged, speechLine != nil { layoutSpeechBubble() }
    }

    func showSpeechBubble(_ line: String, autoDismiss: Bool = true) {
        if let frame = characterFrame,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }),
           shouldSuppress(screen) { return }
        speechFadeTask?.cancel()
        speechFadeTask = nil
        speechGeneration = UUID()
        let generation = speechGeneration
        speechLine = line
        layoutSpeechBubble()
        guard let speechPanel else { return }

        let finalFrame = speechPanel.frame
        let startFrame = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? finalFrame : finalFrame.offsetBy(dx: 0, dy: -8)
        speechPanel.setFrame(startFrame, display: false)
        speechPanel.alphaValue = 0
        speechPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            speechPanel.animator().alphaValue = 1
            speechPanel.animator().setFrame(finalFrame.offsetBy(dx: 0, dy: 2), display: true)
        } completionHandler: { [weak self, weak speechPanel] in
            guard let self, self.speechGeneration == generation,
                  let speechPanel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.10
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                speechPanel.animator().setFrame(finalFrame, display: true)
            }
        }

        guard autoDismiss else { return }
        speechFadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.fadeSpeechBubble()
        }
    }

    func hideCharacter() {
        panel?.orderOut(nil)
    }

    func handoffPose() -> MenuBarInformationController.HandoffPose? {
        guard panel?.isVisible == true, let frame = characterFrame, let image = imageView.image else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let bitmap = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return .init(image: bitmap, frame: frame)
    }

    func dismissSpeechBubble() {
        speechFadeTask?.cancel()
        speechFadeTask = nil
        animateSpeechBubbleExit(drift: -18, duration: 0.45)
    }

    func shutdown() {
        speechFadeTask?.cancel()
        speechFadeTask = nil
        speechGeneration = UUID()
        panel?.orderOut(nil)
        speechPanel?.orderOut(nil)
        speechLine = nil
    }

    private func fadeSpeechBubble() {
        speechFadeTask = nil
        animateSpeechBubbleExit(drift: -18, duration: 0.45)
    }

    private func animateSpeechBubbleExit(drift: CGFloat, duration: TimeInterval) {
        guard let speechPanel, speechLine != nil else { return }
        speechGeneration = UUID()
        let generation = speechGeneration
        let endFrame = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? speechPanel.frame : speechPanel.frame.offsetBy(dx: 0, dy: drift)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            speechPanel.animator().alphaValue = 0
            speechPanel.animator().setFrame(endFrame, display: true)
        } completionHandler: { [weak self, weak speechPanel] in
            Task { @MainActor in
                guard let self, self.speechGeneration == generation else { return }
                speechPanel?.orderOut(nil)
                self.speechLine = nil
            }
        }
    }

    private func layoutSpeechBubble() {
        guard let line = speechLine, let characterFrame, let visibleFrame else { return }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = min(204, ceil((line as NSString).size(withAttributes: [.font: font]).width) + 2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let textRect = (line as NSString).boundingRect(
            with: CGSize(width: max(1, textWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph])
        let bubbleSize = CGSize(width: max(28, textWidth + 28), height: max(16, ceil(textRect.height)) + 12 + HoverSpeechBubbleView.tailHeight)
        let desiredFrame = CGRect(x: characterFrame.midX - bubbleSize.width / 2,
                                  y: characterFrame.minY - bubbleSize.height - 7,
                                  width: bubbleSize.width,
                                  height: bubbleSize.height)
        let bubbleFrame = DisplayGeometry.clamp(desiredFrame, to: visibleFrame)

        if speechPanel == nil {
            let newPanel = NSPanel(contentRect: bubbleFrame,
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered,
                                   defer: false)
            newPanel.backgroundColor = .clear
            newPanel.isOpaque = false
            newPanel.hasShadow = true
            newPanel.level = .statusBar
            newPanel.hidesOnDeactivate = false
            newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
            newPanel.ignoresMouseEvents = true

            let background = HoverSpeechBubbleView(frame: CGRect(origin: .zero, size: bubbleFrame.size))
            background.material = .popover
            background.blendingMode = .withinWindow
            background.state = .active
            background.autoresizingMask = [.width, .height]
            background.wantsLayer = true
            speechLabel.font = font
            speechLabel.textColor = InformationPalette.ink
            speechLabel.alignment = .center
            speechLabel.lineBreakMode = .byWordWrapping
            speechLabel.maximumNumberOfLines = 0
            speechLabel.cell?.wraps = true
            speechLabel.cell?.isScrollable = false
            speechLabel.frame = CGRect(x: 10, y: 5,
                                       width: bubbleFrame.width - 20,
                                       height: bubbleFrame.height - 10 - HoverSpeechBubbleView.tailHeight)
            background.addSubview(speechLabel)
            newPanel.contentView = background
            speechPanel = newPanel
        }

        speechLabel.stringValue = line
        speechLabel.frame = CGRect(x: 10, y: 5,
                                   width: bubbleFrame.width - 20,
                                   height: bubbleFrame.height - 10 - HoverSpeechBubbleView.tailHeight)
        speechPanel?.setFrame(bubbleFrame, display: true)
        (speechPanel?.contentView as? HoverSpeechBubbleView)?.tailX = characterFrame.midX - bubbleFrame.minX
    }
}


/// The hover and completion messages share one clipped glass bubble with an upward-pointing tail.
@MainActor
final class HoverSpeechBubbleView: NSVisualEffectView {
    static let tailHeight: CGFloat = 7
    var tailX: CGFloat = 40 { didSet { needsLayout = true; needsDisplay = true } }
    private let shapeMask = CAShapeLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shapeMask.fillColor = NSColor.black.cgColor
        layer?.mask = shapeMask
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let path = Self.bubblePath(in: bounds.insetBy(dx: 0.5, dy: 0.5), tailX: tailX)
        shapeMask.frame = bounds; shapeMask.path = path
        CATransaction.commit()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(Self.bubblePath(in: bounds.insetBy(dx: 0.5, dy: 0.5), tailX: tailX))
        context.setFillColor(InformationPalette.surface.withAlphaComponent(0.94).cgColor)
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1); context.drawPath(using: .fillStroke)
    }
    static func bubblePath(in rect: CGRect, tailX: CGFloat) -> CGPath {
        let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY - tailHeight
        let radius: CGFloat = min(12, rect.width / 4, (y1 - y0) / 2)
        let tip = min(x1 - radius - 7, max(x0 + radius + 7, tailX))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0 + radius, y: y0))
        path.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y1), radius: radius)
        path.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: tip + 6, y: y1), radius: radius)
        path.addLine(to: CGPoint(x: tip + 6, y: y1))
        path.addLine(to: CGPoint(x: tip, y: rect.maxY))
        path.addLine(to: CGPoint(x: tip - 6, y: y1))
        path.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y0), radius: radius)
        path.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x1, y: y0), radius: radius)
        path.closeSubpath(); return path
    }
}
