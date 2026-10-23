import AppKit
import QuartzCore
import WhaleCore

enum ActivityFrameMorpher {
    private struct Raster {
        let width: Int
        let height: Int
        var pixels: [UInt8]
    }

    private struct Vector {
        var x: Double
        var y: Double
    }

    private static let meshStep = 8
    private static let searchRadius = 14
    private static let patchRadius = 3

    static func midpoint(from first: NSImage, to second: NSImage) -> NSImage? {
        guard let a = raster(from: first), let b = raster(from: second),
              a.width == b.width, a.height == b.height else { return nil }
        guard let changedBounds = changedBounds(a, b) else { return first }

        let padding = patchRadius + 2
        let minX = max(0, Int(changedBounds.minX) - padding)
        let minY = max(0, Int(changedBounds.minY) - padding)
        let maxX = min(a.width - 1, Int(changedBounds.maxX) + padding)
        let maxY = min(a.height - 1, Int(changedBounds.maxY) + padding)
        guard maxX > minX, maxY > minY else { return nil }

        let xCoordinates = meshCoordinates(from: minX, through: maxX)
        let yCoordinates = meshCoordinates(from: minY, through: maxY)
        let columns = xCoordinates.count
        let rows = yCoordinates.count
        guard columns > 1, rows > 1 else { return nil }

        var flow = [Vector](repeating: Vector(x: 0, y: 0), count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                flow[row * columns + column] = estimateFlow(
                    atX: xCoordinates[column],
                    y: yCoordinates[row],
                    from: a,
                    to: b
                )
            }
        }
        flow = medianSmoothed(flow, columns: columns, rows: rows)

        var output = a
        for y in minY...maxY {
            for x in minX...maxX {
                let pixel = pixelIndex(x: x, y: y, width: a.width)
                // Reuse unchanged visible pixels exactly. Transparent pixels are still
                // sampled so a moving tail can enter space that was empty in both keys.
                if a.pixels[pixel + 3] > 0,
                   (0..<4).allSatisfy({ a.pixels[pixel + $0] == b.pixels[pixel + $0] }) {
                    continue
                }

                let displacement = interpolatedFlow(
                    x: Double(x), y: Double(y),
                    xCoordinates: xCoordinates,
                    yCoordinates: yCoordinates,
                    flow: flow
                )
                let fromA = sample(a, x: Double(x) - displacement.x * 0.5,
                                   y: Double(y) - displacement.y * 0.5)
                let fromB = sample(b, x: Double(x) + displacement.x * 0.5,
                                   y: Double(y) + displacement.y * 0.5)
                for channel in 0..<4 {
                    output.pixels[pixel + channel] = UInt8(max(0, min(255,
                        (fromA[channel] * 0.5 + fromB[channel] * 0.5).rounded()
                    )))
                }
            }
        }

        guard let image = cgImage(from: output) else { return nil }
        return NSImage(cgImage: image, size: first.size)
    }

    private static func raster(from image: NSImage) -> Raster? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        guard rendered else { return nil }
        return Raster(width: cgImage.width, height: cgImage.height, pixels: pixels)
    }

    private static func cgImage(from raster: Raster) -> CGImage? {
        raster.pixels.withUnsafeBytes { buffer in
            guard let context = CGContext(
                data: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
                width: raster.width,
                height: raster.height,
                bitsPerComponent: 8,
                bytesPerRow: raster.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    private static func changedBounds(_ a: Raster, _ b: Raster) -> CGRect? {
        var minX = a.width
        var minY = a.height
        var maxX = -1
        var maxY = -1
        for y in 0..<a.height {
            for x in 0..<a.width {
                let pixel = pixelIndex(x: x, y: y, width: a.width)
                guard (0..<4).contains(where: { a.pixels[pixel + $0] != b.pixels[pixel + $0] }),
                      a.pixels[pixel + 3] > 0 || b.pixels[pixel + 3] > 0 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func meshCoordinates(from start: Int, through end: Int) -> [Int] {
        var coordinates = Array(stride(from: start, through: end, by: meshStep))
        if coordinates.last != end { coordinates.append(end) }
        return coordinates
    }

    private static func estimateFlow(atX centerX: Int, y centerY: Int, from a: Raster, to b: Raster) -> Vector {
        var bestCost = Double.greatestFiniteMagnitude
        var bestX = 0
        var bestY = 0
        for dy in -searchRadius...searchRadius {
            for dx in -searchRadius...searchRadius {
                var cost = 0.0
                var weight = 0.0
                for offsetY in -patchRadius...patchRadius {
                    for offsetX in -patchRadius...patchRadius {
                        let ax = centerX + offsetX
                        let ay = centerY + offsetY
                        let bx = ax + dx
                        let by = ay + dy
                        guard ax >= 0, ay >= 0, bx >= 0, by >= 0,
                              ax < a.width, bx < b.width, ay < a.height, by < b.height else { continue }
                        let aPixel = pixelIndex(x: ax, y: ay, width: a.width)
                        let bPixel = pixelIndex(x: bx, y: by, width: b.width)
                        let aAlpha = Double(a.pixels[aPixel + 3]) / 255
                        let bAlpha = Double(b.pixels[bPixel + 3]) / 255
                        if aAlpha == 0 && bAlpha == 0 { continue }
                        let visibleWeight = max(aAlpha, bAlpha)
                        weight += visibleWeight
                        for channel in 0..<3 {
                            cost += abs(Double(a.pixels[aPixel + channel]) - Double(b.pixels[bPixel + channel])) * visibleWeight
                        }
                        cost += abs(aAlpha - bAlpha) * 255
                    }
                }
                if weight > 0 { cost /= weight }
                cost += Double(dx * dx + dy * dy) * 0.002
                if cost < bestCost {
                    bestCost = cost
                    bestX = dx
                    bestY = dy
                }
            }
        }
        return Vector(x: Double(bestX), y: Double(bestY))
    }

    private static func medianSmoothed(_ flow: [Vector], columns: Int, rows: Int) -> [Vector] {
        var smoothed = flow
        for row in 0..<rows {
            for column in 0..<columns {
                var horizontal: [Double] = []
                var vertical: [Double] = []
                for neighborRow in max(0, row - 1)...min(rows - 1, row + 1) {
                    for neighborColumn in max(0, column - 1)...min(columns - 1, column + 1) {
                        let displacement = flow[neighborRow * columns + neighborColumn]
                        horizontal.append(displacement.x)
                        vertical.append(displacement.y)
                    }
                }
                horizontal.sort()
                vertical.sort()
                smoothed[row * columns + column] = Vector(
                    x: horizontal[horizontal.count / 2],
                    y: vertical[vertical.count / 2]
                )
            }
        }
        return smoothed
    }

    private static func interpolatedFlow(
        x: Double,
        y: Double,
        xCoordinates: [Int],
        yCoordinates: [Int],
        flow: [Vector]
    ) -> Vector {
        let columns = xCoordinates.count
        let column = max(0, min(columns - 2, xCoordinates.lastIndex(where: { Double($0) <= x }) ?? 0))
        let row = max(0, min(yCoordinates.count - 2, yCoordinates.lastIndex(where: { Double($0) <= y }) ?? 0))
        let left = Double(xCoordinates[column])
        let right = Double(xCoordinates[column + 1])
        let top = Double(yCoordinates[row])
        let bottom = Double(yCoordinates[row + 1])
        let u = max(0, min(1, (x - left) / (right - left)))
        let v = max(0, min(1, (y - top) / (bottom - top)))
        let topLeft = flow[row * columns + column]
        let topRight = flow[row * columns + column + 1]
        let bottomLeft = flow[(row + 1) * columns + column]
        let bottomRight = flow[(row + 1) * columns + column + 1]

        // Two affine triangles per mesh cell keep the displacement local and stable.
        if v <= u {
            return Vector(
                x: topLeft.x * (1 - u) + topRight.x * (u - v) + bottomRight.x * v,
                y: topLeft.y * (1 - u) + topRight.y * (u - v) + bottomRight.y * v
            )
        }
        return Vector(
            x: topLeft.x * (1 - v) + bottomLeft.x * (v - u) + bottomRight.x * u,
            y: topLeft.y * (1 - v) + bottomLeft.y * (v - u) + bottomRight.y * u
        )
    }

    private static func sample(_ raster: Raster, x: Double, y: Double) -> [Double] {
        let sampleX = max(0, min(Double(raster.width - 1), x))
        let sampleY = max(0, min(Double(raster.height - 1), y))
        let x0 = Int(sampleX)
        let y0 = Int(sampleY)
        let x1 = min(raster.width - 1, x0 + 1)
        let y1 = min(raster.height - 1, y0 + 1)
        let fractionX = sampleX - Double(x0)
        let fractionY = sampleY - Double(y0)
        return (0..<4).map { channel in
            let topLeft = Double(raster.pixels[pixelIndex(x: x0, y: y0, width: raster.width) + channel])
            let topRight = Double(raster.pixels[pixelIndex(x: x1, y: y0, width: raster.width) + channel])
            let bottomLeft = Double(raster.pixels[pixelIndex(x: x0, y: y1, width: raster.width) + channel])
            let bottomRight = Double(raster.pixels[pixelIndex(x: x1, y: y1, width: raster.width) + channel])
            let top = topLeft * (1 - fractionX) + topRight * fractionX
            let bottom = bottomLeft * (1 - fractionX) + bottomRight * fractionX
            return top * (1 - fractionY) + bottom * fractionY
        }
    }

    private static func pixelIndex(x: Int, y: Int, width: Int) -> Int { (y * width + x) * 4 }
}

@MainActor
private final class PassthroughImageView: NSImageView {
    var onMouseEntered: ((NSEvent) -> Void)?
    var onMouseExited: ((NSEvent) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?(event) }
    override func mouseExited(with event: NSEvent) { onMouseExited?(event) }
}

// Own the gesture instead of relying on NSStatusBarButton's click-tracking loop.
@MainActor
final class StatusIconInputView: NSView {
    var onPointerEvent: ((NSEvent) -> Void)?
    var onClick: ((NSEvent) -> Void)?
    var onEntered: ((NSEvent) -> Void)?
    var onExited: ((NSEvent) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPointerEvent?(event) }
    override func mouseDragged(with event: NSEvent) { onPointerEvent?(event) }
    override func mouseUp(with event: NSEvent) {
        onPointerEvent?(event)
        onClick?(event)
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) { onClick?(event) }
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) { onClick?(event) }
    override func mouseEntered(with event: NSEvent) { onEntered?(event) }
    override func mouseExited(with event: NSEvent) { onExited?(event) }
}

@MainActor
private final class HoverCharacterPanel {
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

@MainActor
protocol MenuBarControllerDelegate: AnyObject {
    func menuBarDidRequestDashboard()
    func menuBarDidRequestTogglePeek()
    func menuBarDidDragCharacter(to point: CGPoint, isNew: Bool)
    func menuBarDidFinishDraggingCharacter()
    func menuBarDidRequestCloseAllCharacters()
    func menuBarDidRequestFull()
    func menuBarDidRequestAction(_ clipID: String)
    func menuBarDidSelectSkin(_ skin: SpriteRepository.Skin)
    func menuBarDidChangeScale(_ scale: Double)
    func menuBarDidRequestQuit()
}

@MainActor
final class MenuBarController: NSObject {
    private var iconInputView: StatusIconInputView?
    private var iconDragStart: CGPoint?
    private var didDragCharacter = false

    private enum HoverAnimation: String, CaseIterable, Sendable {
        case appear
        case disappear
        case wink
    }

    private struct PreparedMenuBarFrames: @unchecked Sendable {
        let activity: [NSImage]
        let hover: [String: [NSImage]]
    }

    weak var delegate: MenuBarControllerDelegate?
    private let repository: SpriteRepository
    private let metricsSampler: SystemMetricsSampler
    private var completionNames: [String] = []
    private var completionQuotas: [String: String] = [:]
    private var completionDismissal: Task<Void, Never>?
    private var completionGeneration = UUID()
    private let completionHoldDuration: Duration
    private let peekSuppression: @MainActor (NSScreen) -> Bool
    var completionSpeechLine: String? { hoverCharacterPanel.currentSpeechLine }
    var completionSpeechPanel: NSPanel? { hoverCharacterPanel.currentSpeechPanel }
    private var networkCompletionLine: String?
    var isCompletionPeekActive: Bool { !completionNames.isEmpty || networkCompletionLine != nil }
    private var completionLine: String {
        networkCompletionLine ?? completionNames.map { name in name + " 回复完成啦" + (completionQuotas[name].map { "\n" + $0 } ?? "") }.joined(separator: "\n")
    }

    private let informationController: MenuBarInformationController
    private let aiStore: AIMonitorStore?
    private let contextMenuPresenter: @MainActor (NSMenu, NSEvent, NSView) -> Void
    private var suppressHoverUntilExit = false
    private var hoverCooldownUntil: TimeInterval = 0
    private var hoverCooldownTask: Task<Void, Never>?
    var isHoverCoolingDown: Bool { ProcessInfo.processInfo.systemUptime < hoverCooldownUntil }
    var isHoverCharacterVisible: Bool { hoverCharacterPanel.handoffPose() != nil }
    var informationState: MenuBarInformationController.State { informationController.state }
    private var statusItem: NSStatusItem?
    private var animationImageView: PassthroughImageView?
    private var trackingArea: NSTrackingArea?
    private var animationTimer: Timer?
    private var hoverPlaybackTimer: Timer?
    private var winkTimer: Timer?
    private var metricsTimer: Timer?
    private var frameLoadingTask: Task<Void, Never>?
    private var activityFrames: [NSImage] = []
    private var scaledActivityFrames: [NSImage] = []
    private var hoverFrames: [HoverAnimation: [NSImage]] = [:]
    private var scaledHoverFrames: [HoverAnimation: [NSImage]] = [:]
    private let hoverCharacterPanel: HoverCharacterPanel
    private var frameSequence: [Int] = []
    private var sequencePosition = 0
    private var hoverAnimation: HoverAnimation?
    private var hoverFramePosition = 0
    private var isPointerHovering = false
    private(set) var isPeekPinned = false
    private var shouldKeepPeekVisible: Bool { isPointerHovering || isPeekPinned || isCompletionPeekActive }
    private var lastHoverSpeechLine: String?
    private var pendingHoverSpeechLine: String?
    private var activityClock: ActivityAnimationClock?
    // Opt-in, eight-line numeric timing probe; no account/event content and no default logging.
    private var activityTraceStart: TimeInterval?
    private var activityTraceFrames = 0
    private var activityTraceSamples = 0
    private var heartEffects: [HeartEffect] = []
    private var currentScale = 1.0
    private weak var scaleValueLabel: NSTextField?

    @MainActor
    private final class HeartEffect {
        let panel: NSPanel
        let imageView: NSView
        var riseTask: DispatchWorkItem?
        var hideTask: DispatchWorkItem?
        var fadeTask: DispatchWorkItem?

        init(panel: NSPanel, imageView: NSView) {
            self.panel = panel
            self.imageView = imageView
        }
    }

    init(repository: SpriteRepository, metricsSampler: SystemMetricsSampler, aiStore: AIMonitorStore? = nil,
         completionHoldDuration: Duration = .seconds(10),
         peekSuppression: @escaping @MainActor (NSScreen) -> Bool = { screen in
             FullScreenAvoidance.shared.refreshIfNeeded()
             return FullScreenAvoidance.shared.shouldSuppress(on: screen)
         },
         contextMenuPresenter: @escaping @MainActor (NSMenu, NSEvent, NSView) -> Void = {
            NSMenu.popUpContextMenu($0, with: $1, for: $2)
         }) {
        self.completionHoldDuration = completionHoldDuration
        self.peekSuppression = peekSuppression
        hoverCharacterPanel = HoverCharacterPanel(shouldSuppress: peekSuppression)
        self.repository = repository
        self.metricsSampler = metricsSampler
        self.aiStore = aiStore
        self.contextMenuPresenter = contextMenuPresenter
        informationController = MenuBarInformationController(aiStore: aiStore)
        super.init()
        NetworkDiagnosticsStore.shared.onQuickCompletion = { [weak self] line in self?.showNetworkTestResult(line) }
        informationController.onClosed = { [weak self] in
            guard let self else { return }
            self.hidePeek(animated: false, preserveCompletion: true)
            self.hoverCharacterPanel.shutdown()
            self.suppressHoverUntilExit = false
            self.startHoverCooldown()
        }
        informationController.onPresentationReady = { [weak self] in
            self?.hidePeek(animated: false, preserveCompletion: true)
            self?.hoverCharacterPanel.shutdown()
        }
        informationController.onLoadFailure = { [weak self] in
            self?.statusItem?.button?.toolTip = "信息动画加载失败，请重新打开应用"
        }
    }

    var buttonFrameOnScreen: CGRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func showQuotaRecovery(_ line: String) { showNetworkTestResult(line) }

    func showNetworkTestResult(_ line: String) {
        guard let screen = self.screen, !peekSuppression(screen) else { return }
        if informationController.state == .showing { informationController.showNetworkResult(line); return }
        guard !informationController.isActive else { return }
        networkCompletionLine = line
        suppressHoverUntilExit = false
        if hoverAnimation == nil || hoverAnimation == .disappear { showHoverIfNeeded() }
        else if hoverAnimation == .appear && hoverPlaybackTimer != nil { pendingHoverSpeechLine = line }
        else { pendingHoverSpeechLine = nil; presentHoverSpeech(line) }
    }

    func showReplyCompletion(sourceName: String, quotaSummary: String? = nil) {
        guard statusItem != nil, let screen = self.screen ?? NSScreen.main ?? NSScreen.screens.first,
              !peekSuppression(screen) else { return }
        networkCompletionLine = nil
        let name = String(sourceName.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let quotaSummary { completionQuotas[name] = quotaSummary }
        if !completionNames.contains(name) {
            if completionNames.count >= 10 { completionNames.removeFirst() }
            completionNames.append(name)
        }
        // Defer while the user is reading the rope information panel; never overlay two characters.
        guard !informationController.isActive else { return }
        suppressHoverUntilExit = false
        if hoverAnimation == nil || hoverAnimation == .disappear {
            showHoverIfNeeded()
        } else if hoverAnimation == .appear && hoverPlaybackTimer != nil {
            pendingHoverSpeechLine = completionLine
        } else {
            pendingHoverSpeechLine = nil
            presentHoverSpeech(completionLine)
        }
    }

    private func presentHoverSpeech(_ line: String) {
        hoverCharacterPanel.showSpeechBubble(line, autoDismiss: !isCompletionPeekActive)
        guard isCompletionPeekActive else { return }
        completionDismissal?.cancel()
        completionGeneration = UUID(); let generation = completionGeneration
        completionDismissal = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now.advanced(by: self.completionHoldDuration)
            while ContinuousClock.now < deadline {
                do { try await Task.sleep(for: min(.milliseconds(500), deadline - ContinuousClock.now)) } catch { return }
                guard self.completionGeneration == generation else { return }
                if let screen = self.screen, self.peekSuppression(screen) {
                    self.hidePeek(animated: false)
                    self.hoverCharacterPanel.shutdown()
                    return
                }
            }
            guard !Task.isCancelled, self.completionGeneration == generation else { return }
            self.cancelCompletionPeek()
            if !self.isPeekPinned {
                self.suppressHoverUntilExit = self.isPointerHovering
                self.winkTimer?.invalidate(); self.winkTimer = nil
                self.beginHoverAnimation(.disappear)
            } else {
                self.hoverCharacterPanel.dismissSpeechBubble()
            }
        }
    }

    private func cancelCompletionPeek() {
        completionDismissal?.cancel(); completionDismissal = nil
        completionGeneration = UUID(); completionNames.removeAll(); completionQuotas.removeAll(); networkCompletionLine = nil
    }

    var screen: NSScreen? { statusItem?.button?.window?.screen }

    func install(scale: Double) {
        currentScale = scale
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 28)
        statusItem = item
        guard let button = item.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = nil
        let imageView = PassthroughImageView(frame: button.bounds)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignBottom
        imageView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: button.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        animationImageView = imageView
        imageView.onMouseEntered = { [weak self] event in self?.mouseEntered(with: event) }
        imageView.onMouseExited = { [weak self] event in self?.mouseExited(with: event) }
        button.toolTip = "WhaleGirl：悬停探头，右键电脑信息，中键菜单"
        button.target = self
        button.action = #selector(statusClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp, .otherMouseUp])
        let input = StatusIconInputView(frame: button.bounds)
        input.autoresizingMask = [.width, .height]
        input.onPointerEvent = { [weak self] event in self?.trackIconDrag(event) }
        input.onClick = { [weak self] event in self?.handleStatusClick(event) }
        input.onEntered = { [weak self] event in self?.mouseEntered(with: event) }
        input.onExited = { [weak self] event in self?.mouseExited(with: event) }
        button.addSubview(input, positioned: .above, relativeTo: imageView)
        iconInputView = input
        showInitialActivityFrame()
        loadActivityFrames()
        let area = NSTrackingArea(rect: input.bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: input)
        input.addTrackingArea(area)
        trackingArea = area
    }

    private func trackIconDrag(_ event: NSEvent) {
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            didDragCharacter = false
            iconDragStart = !informationController.isActive && buttonFrameOnScreen?.contains(point) == true ? point : nil
        case .leftMouseDragged:
            guard let start = iconDragStart else { return }
            guard didDragCharacter || start.y - point.y >= 12 else { return }
            let isNew = !didDragCharacter
            didDragCharacter = true
            if isNew { hidePeek(animated: false) }
            delegate?.menuBarDidDragCharacter(to: point, isNew: isNew)
        case .leftMouseUp:
            if didDragCharacter {
                delegate?.menuBarDidDragCharacter(to: point, isNew: false)
                delegate?.menuBarDidFinishDraggingCharacter()
            }
            iconDragStart = nil
        default: break
        }
    }

    func uninstall() {
        cancelCompletionPeek()
        informationController.shutdown()
        hoverCooldownTask?.cancel()
        hoverCooldownTask = nil
        hoverCooldownUntil = 0
        isPointerHovering = false
        suppressHoverUntilExit = false
        iconInputView?.removeFromSuperview()
        iconInputView = nil
        animationTimer?.invalidate()
        animationTimer = nil
        activityClock = nil; activityTraceStart = nil
        frameLoadingTask?.cancel()
        frameLoadingTask = nil
        hoverPlaybackTimer?.invalidate()
        hoverPlaybackTimer = nil
        winkTimer?.invalidate()
        winkTimer = nil
        hoverCharacterPanel.shutdown()
        metricsTimer?.invalidate()
        metricsTimer = nil
        for effect in heartEffects {
            effect.riseTask?.cancel()
            effect.hideTask?.cancel()
            effect.fadeTask?.cancel()
            effect.panel.orderOut(nil)
            effect.riseTask = nil
            effect.hideTask = nil
            effect.fadeTask = nil
        }
        heartEffects.removeAll()
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        animationImageView = nil
    }

    func updateScale(_ scale: Double) {
        currentScale = scale
        refreshScaledActivityFrames()
        if let anchor = buttonFrameOnScreen, let screen = self.screen {
            informationController.updateLayout(anchor: anchor, screen: screen, scale: scale)
        }
        if let hoverAnimation {
            showHoverFrame(kind: hoverAnimation, index: hoverFramePosition)
        } else {
            showCurrentActivityFrame()
        }
    }

    func updateAttentionCount(_ count: Int) {
        guard let button = statusItem?.button else { return }
        if count > 0 {
            button.title = count > 99 ? "99+" : String(count)
            button.imagePosition = .imageLeading
            animationImageView?.isHidden = true
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            animationImageView?.isHidden = false
        }
        showCurrentActivityFrame()
    }

    @objc private func statusClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        handleStatusClick(event)
    }

    func showComputerInformation() {
        guard !informationController.isActive, let anchor = buttonFrameOnScreen, let screen = self.screen ?? NSScreen.main else { return }
        cancelCompletionPeek()
        suppressHoverUntilExit = true
        hoverPlaybackTimer?.invalidate()
        hoverPlaybackTimer = nil
        winkTimer?.invalidate()
        winkTimer = nil
        if let frames = scaledHoverFrames[.appear], !frames.isEmpty {
            hoverAnimation = .appear
            hoverFramePosition = frames.count - 1
            showHoverFrame(kind: .appear, index: hoverFramePosition)
        }
        let pose = hoverCharacterPanel.handoffPose()
        hoverCharacterPanel.dismissSpeechBubble()
        informationController.open(anchor: anchor, screen: screen, scale: currentScale, handoffPose: pose)
    }

    func handleStatusClick(_ event: NSEvent) {
        if event.type == .otherMouseUp, event.buttonNumber == 2 {
            showContextMenu(event: event)
            return
        }
        if event.type == .rightMouseUp {
            if event.modifierFlags.contains(.option) {
                showContextMenu(event: event)
            } else if informationController.isActive {
                informationController.close()
            } else {
                showComputerInformation()
            }
        } else if event.type == .leftMouseUp {
            guard !didDragCharacter else { return }
            if informationController.isActive { showContextMenu(event: event) }
            else { showHeartAboveStatusItem() }
        }
    }

    private func showHeartAboveStatusItem() {
        let startPoint = NSEvent.mouseLocation
        let heartSize: CGFloat = 12
        let panelSize = CGSize(width: 34, height: 42)
        let startY: CGFloat = 8
        let heartFrame = CGRect(
            x: startPoint.x - panelSize.width / 2,
            y: startPoint.y - startY - heartSize / 2,
            width: panelSize.width,
            height: panelSize.height
        )
        let (panel, imageView) = makeHeartPanel(size: panelSize, heartSize: heartSize)
        let effect = HeartEffect(panel: panel, imageView: imageView)
        heartEffects.append(effect)
        panel.setFrame(heartFrame, display: true)
        panel.alphaValue = 1
        let endY: CGFloat = 30
        let centerX = (panelSize.width - heartSize) / 2
        let startFrame = CGRect(x: centerX, y: startY,
                                width: heartSize, height: heartSize)
        let popFrame = CGRect(x: (panelSize.width - heartSize * 1.08) / 2,
                              y: startY - heartSize * 0.04,
                              width: heartSize * 1.08,
                              height: heartSize * 1.08)
        let smallFrame = CGRect(x: (panelSize.width - heartSize * 0.88) / 2,
                                y: startY + heartSize * 0.06,
                                width: heartSize * 0.88,
                                height: heartSize * 0.88)
        imageView.frame = smallFrame
        imageView.alphaValue = 0
        panel.orderFrontRegardless()

        // A quick, soft pop establishes the reaction before the slow upward drift.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            imageView.animator().frame = popFrame
            imageView.animator().alphaValue = 1
        }

        let riseDelay: CFTimeInterval = 0.26
        let riseDuration: CFTimeInterval = 1.64
        let fadeDelay: CFTimeInterval = 1.13
        let fadeDuration: CFTimeInterval = 0.77
        let duration = riseDelay + riseDuration
        let swayAmplitude: CGFloat = 22.0

        let riseTask = DispatchWorkItem { [weak effect] in
            guard let effect else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                effect.imageView.animator().frame = startFrame
            } completionHandler: {
                Task { @MainActor in
                    let sway = CAKeyframeAnimation(keyPath: "position.x")
                    sway.values = [0, swayAmplitude, 0, -swayAmplitude, 0,
                                   swayAmplitude, 0, -swayAmplitude, 0]
                    sway.keyTimes = [0, 0.125, 0.25, 0.375, 0.5,
                                     0.625, 0.75, 0.875, 1]
                    sway.calculationMode = .cubic
                    sway.duration = riseDuration
                    sway.isAdditive = true
                    effect.imageView.layer?.add(sway, forKey: "heart-sway")

                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = riseDuration
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        effect.imageView.animator().frame = CGRect(
                            x: (panelSize.width - heartSize * 0.95) / 2,
                            y: endY,
                            width: heartSize * 0.95,
                            height: heartSize * 0.95
                        )
                    }
                    effect.riseTask = nil
                }
            }
        }
        effect.riseTask = riseTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: riseTask)

        // Keep the heart legible through most of the rise, then fade it away.
        let fadeTask = DispatchWorkItem { [weak effect] in
            guard let effect else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                effect.imageView.animator().alphaValue = 0
            }
            effect.fadeTask = nil
        }
        effect.fadeTask = fadeTask
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDelay, execute: fadeTask)

        let task = DispatchWorkItem { [weak self] in
            effect.panel.orderOut(nil)
            effect.riseTask?.cancel()
            effect.riseTask = nil
            effect.hideTask = nil
            effect.fadeTask?.cancel()
            effect.fadeTask = nil
            self?.heartEffects.removeAll { $0 === effect }
        }
        effect.hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }

    private func makeHeartPanel(size: CGSize, heartSize: CGFloat) -> (NSPanel, NSView) {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenPrimary, .stationary]

        let imageView = NSView(frame: CGRect(
            x: (size.width - heartSize) / 2,
            y: 0,
            width: heartSize,
            height: heartSize
        ))
        imageView.wantsLayer = true
        let symbol = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "爱心")
        let outlineView = NSImageView(frame: imageView.bounds.insetBy(dx: 0.15, dy: 0.15))
        outlineView.image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        )
        outlineView.contentTintColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        outlineView.imageScaling = .scaleProportionallyUpOrDown
        let fillView = NSImageView(frame: imageView.bounds.insetBy(dx: 1.15, dy: 1.15))
        fillView.image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        )
        fillView.contentTintColor = .systemRed
        fillView.imageScaling = .scaleProportionallyUpOrDown
        imageView.addSubview(outlineView)
        imageView.addSubview(fillView)
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.addSubview(imageView)
        panel.contentView = container

        return (panel, imageView)
    }

    private func showContextMenu(event explicitEvent: NSEvent? = nil) {
        guard let button = statusItem?.button, let event = explicitEvent ?? NSApp.currentEvent else { return }
        let menu = NSMenu()
        menu.addItem(item("打开 Dashboard", action: #selector(showDashboard)))
        menu.addItem(item("探头 / 收回", action: #selector(togglePeek)))
        menu.addItem(item("拖出全身", action: #selector(showFull)))
        menu.addItem(item("一键关闭所有鲸鱼娘", action: #selector(closeAllCharacters)))
        menu.addItem(item("选择电脑信息…", action: #selector(showSystemMetricSettings)))
        menu.addItem(item("网络诊断与测速…", action: #selector(showNetworkDiagnostics)))
        menu.addItem(item("编辑气泡文案 CSV", action: #selector(editSpeechCSV)))
        if let aiStore {
            let quota = item("显示 AI 额度", action: #selector(toggleAIQuotas))
            quota.state = aiStore.preferences.showQuotas ? .on : .off; menu.addItem(quota)
            let agents = item("子 Agent 自动生成鲸鱼娘", action: #selector(toggleAgentCompanions))
            agents.state = aiStore.preferences.autoAgentPets ? .on : .off; menu.addItem(agents)
            menu.addItem(item("选择 AI 工具…", action: #selector(showAISettings)))
        }
        let skinItem = NSMenuItem(title: "桌宠皮肤", action: nil, keyEquivalent: "")
        let skinMenu = NSMenu()
        for skin in SpriteRepository.Skin.allCases {
            let entry = item(skin.title, action: #selector(selectSkin(_:)))
            entry.representedObject = skin.rawValue
            entry.state = repository.selectedSkin == skin ? .on : .off
            skinMenu.addItem(entry)
        }
        skinItem.submenu = skinMenu
        menu.addItem(skinItem)
        if !repository.communityActions.isEmpty {
            let actionItem = NSMenuItem(title: "桌面动作", action: nil, keyEquivalent: "")
            let actionMenu = NSMenu()
            actionMenu.addItem(item("随机播放全部动作", action: #selector(showFull)))
            actionMenu.addItem(.separator())
            let categories = Dictionary(grouping: repository.communityActions, by: \.category)
            for category in categories.keys.sorted() {
                let categoryItem = NSMenuItem(title: category, action: nil, keyEquivalent: "")
                let categoryMenu = NSMenu()
                for action in categories[category] ?? [] {
                    let entry = item(action.title, action: #selector(playCommunityAction(_:)))
                    entry.representedObject = action.clipID
                    categoryMenu.addItem(entry)
                }
                actionMenu.setSubmenu(categoryMenu, for: categoryItem)
                actionMenu.addItem(categoryItem)
            }
            menu.setSubmenu(actionMenu, for: actionItem)
            menu.addItem(actionItem)
        }
        menu.addItem(.separator())

        let scaleItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let scaleMenu = NSMenu()
        let scaleControlItem = NSMenuItem()
        let scaleControl = makeScaleControl()
        scaleControlItem.view = scaleControl
        scaleMenu.addItem(scaleControlItem)
        menu.setSubmenu(scaleMenu, for: scaleItem)
        menu.addItem(scaleItem)
        let sound = NSMenuItem(title: "声音", action: nil, keyEquivalent: "")
        sound.state = .off
        sound.isEnabled = false
        menu.addItem(sound)
        menu.addItem(.separator())
        menu.addItem(item("退出 WhaleGirl", action: #selector(quit)))
        contextMenuPresenter(menu, event, button)
    }

    @objc private func selectSkin(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let skin = SpriteRepository.Skin(rawValue: raw) else { return }
        delegate?.menuBarDidSelectSkin(skin)
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func makeScaleControl() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 54))
        let valueLabel = NSTextField(labelWithString: "\(Int((currentScale * 100).rounded()))%")
        valueLabel.font = .systemFont(ofSize: 13, weight: .medium)
        valueLabel.alignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider(value: currentScale * 100,
                              minValue: 80,
                              maxValue: 150,
                              target: self,
                              action: #selector(changeScale(_:)))
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(valueLabel)
        container.addSubview(slider)
        NSLayoutConstraint.activate([
            valueLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            valueLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            slider.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 1),
            slider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            slider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            slider.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5)
        ])
        scaleValueLabel = valueLabel
        return container
    }

    @objc private func toggleAIQuotas() { if let aiStore { aiStore.setShowQuotas(!aiStore.preferences.showQuotas) } }
    @objc private func toggleAgentCompanions() { if let aiStore { aiStore.setAutoAgentPets(!aiStore.preferences.autoAgentPets) } }
    @objc private func showSystemMetricSettings() { SystemMetricSettingsWindow.show() }
    @objc private func showNetworkDiagnostics() { NetworkDiagnosticsWindow.show() }
    @objc private func showAISettings() { aiStore?.showSettings() }

    @objc private func editSpeechCSV() {
        do {
            try DeepSeekChanDialog.prepareFile()
            let url = DeepSeekChanDialog.fileURL
            if let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
                NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
            } else { NSWorkspace.shared.open(url) }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法打开气泡文案 CSV"
            alert.runModal()
        }
    }

    @objc private func togglePeek() { delegate?.menuBarDidRequestTogglePeek() }
    @objc private func showDashboard() { delegate?.menuBarDidRequestDashboard() }
    @objc private func closeAllCharacters() { delegate?.menuBarDidRequestCloseAllCharacters() }
    @objc private func showFull() { delegate?.menuBarDidRequestFull() }
    @objc private func playCommunityAction(_ sender: NSMenuItem) {
        guard let clipID = sender.representedObject as? String else { return }
        delegate?.menuBarDidRequestAction(clipID)
    }
    @objc private func quit() { delegate?.menuBarDidRequestQuit() }

    @objc private func changeScale(_ sender: NSSlider) {
        let value = sender.doubleValue / 100
        currentScale = value
        scaleValueLabel?.stringValue = "\(Int(sender.doubleValue.rounded()))%"
        delegate?.menuBarDidChangeScale(value)
    }

    // Explicit peek requests share the user's hanging animation with hover.
    // Never create a second, placeholder character window.
    func showPeek() {
        guard !informationController.isActive, !isHoverCoolingDown else { return }
        suppressHoverUntilExit = false
        isPeekPinned = true
        guard hoverAnimation == nil || hoverAnimation == .disappear else { return }
        guard !(scaledHoverFrames[.appear]?.isEmpty ?? true) else { return }
        beginHoverAnimation(.appear)
    }

    func hidePeek(animated: Bool = true, preserveCompletion: Bool = false) {
        if !preserveCompletion { cancelCompletionPeek() }
        isPeekPinned = false
        winkTimer?.invalidate()
        winkTimer = nil
        guard hoverAnimation != nil else { return }
        if animated {
            beginHoverAnimation(.disappear)
        } else {
            hoverPlaybackTimer?.invalidate()
            hoverPlaybackTimer = nil
            hoverAnimation = nil
            pendingHoverSpeechLine = nil
            hoverCharacterPanel.dismissSpeechBubble()
            hoverCharacterPanel.hideCharacter()
        }
    }

    @objc func mouseEntered(with event: NSEvent) {
        statusItem?.button?.toolTip = nil
        guard !isPointerHovering else { return }
        isPointerHovering = true
        winkTimer?.invalidate()
        winkTimer = nil
        showHoverIfNeeded()
        if hoverPlaybackTimer == nil { scheduleWink() }
    }

    private func startHoverCooldown() {
        hoverCooldownTask?.cancel()
        hoverCooldownUntil = ProcessInfo.processInfo.systemUptime + 1
        hoverCooldownTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.statusItem != nil else { return }
            self.hoverCooldownTask = nil
            if self.shouldKeepPeekVisible { self.showHoverIfNeeded() }
        }
    }

    private func showHoverIfNeeded() {
        guard !informationController.isActive, !suppressHoverUntilExit, !isHoverCoolingDown,
              hoverAnimation == nil || hoverAnimation == .disappear,
              !(scaledHoverFrames[.appear]?.isEmpty ?? true) else { return }
        beginHoverAnimation(.appear)
    }

    @objc func mouseExited(with event: NSEvent) {
        statusItem?.button?.toolTip = informationController.isActive
            ? "WhaleGirl：右键收回信息，左键菜单" : "WhaleGirl：左键爱心，右键电脑信息；Option+右键菜单"
        guard isPointerHovering else { return }
        isPointerHovering = false
        suppressHoverUntilExit = false
        winkTimer?.invalidate()
        winkTimer = nil
        // A cooldown exit must not start disappearance from a full, hidden head.
        guard !informationController.isActive, !isHoverCoolingDown, hoverAnimation != nil else { return }
        if !shouldKeepPeekVisible {
            beginHoverAnimation(.disappear)
        } else if hoverPlaybackTimer == nil {
            scheduleWink()
        }
    }

    private func beginHoverAnimation(_ kind: HoverAnimation) {
        hoverPlaybackTimer?.invalidate()
        hoverPlaybackTimer = nil
        hoverAnimation = kind
        hoverFramePosition = 0
        if kind == .disappear {
            pendingHoverSpeechLine = nil
            hoverCharacterPanel.dismissSpeechBubble()
        }
        guard let frames = scaledHoverFrames[kind], !frames.isEmpty else {
            finishHoverAnimation(kind)
            return
        }
        showHoverFrame(kind: kind, index: 0)
        if kind == .appear {
            let line = isCompletionPeekActive ? completionLine : DeepSeekChanDialog.randomLine(excluding: lastHoverSpeechLine)
            if !isCompletionPeekActive { lastHoverSpeechLine = line }
            pendingHoverSpeechLine = line
        }
        scheduleHoverFrame()
    }

    private func scheduleHoverFrame() {
        hoverPlaybackTimer?.invalidate()
        let frameRate: Double = hoverAnimation == .wink ? 30 : 60
        let timer = Timer(timeInterval: 1.0 / frameRate,
                          target: self,
                          selector: #selector(advanceHoverFrame),
                          userInfo: nil,
                          repeats: false)
        hoverPlaybackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func advanceHoverFrame() {
        guard let kind = hoverAnimation,
              let frames = scaledHoverFrames[kind], !frames.isEmpty else { return }
        if hoverFramePosition + 1 < frames.count {
            hoverFramePosition += 1
            showHoverFrame(kind: kind, index: hoverFramePosition)
            if kind == .appear,
               let line = pendingHoverSpeechLine,
               hoverFramePosition >= Int(ceil(Double(frames.count - 1) * 2.0 / 3.0)) {
                pendingHoverSpeechLine = nil
                presentHoverSpeech(line)
            }
            scheduleHoverFrame()
        } else {
            finishHoverAnimation(kind)
        }
    }

    private func finishHoverAnimation(_ kind: HoverAnimation) {
        hoverPlaybackTimer?.invalidate()
        hoverPlaybackTimer = nil
        switch kind {
        case .appear:
            if let line = pendingHoverSpeechLine {
                pendingHoverSpeechLine = nil
                presentHoverSpeech(line)
            }
            hoverAnimation = .appear
            hoverFramePosition = max(0, (scaledHoverFrames[.appear]?.count ?? 1) - 1)
            showHoverFrame(kind: .appear, index: hoverFramePosition)
            scheduleWink()
        case .wink:
            guard shouldKeepPeekVisible else {
                beginHoverAnimation(.disappear)
                return
            }
            hoverAnimation = .appear
            hoverFramePosition = max(0, (scaledHoverFrames[.appear]?.count ?? 1) - 1)
            showHoverFrame(kind: .appear, index: hoverFramePosition)
            scheduleWink()
        case .disappear:
            hoverAnimation = nil
            hoverFramePosition = 0
            hoverCharacterPanel.hideCharacter()
        }
    }

    private func scheduleWink() {
        winkTimer?.invalidate()
        guard shouldKeepPeekVisible, hoverAnimation == .appear,
              !(scaledHoverFrames[.wink]?.isEmpty ?? true) else { return }
        let timer = Timer(timeInterval: Double.random(in: 2.0...3.0),
                          target: self,
                          selector: #selector(triggerWink),
                          userInfo: nil,
                          repeats: false)
        winkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func triggerWink() {
        winkTimer = nil
        guard shouldKeepPeekVisible, hoverAnimation == .appear else { return }
        beginHoverAnimation(.wink)
    }

    private func showHoverFrame(kind: HoverAnimation, index: Int) {
        guard let frames = scaledHoverFrames[kind], frames.indices.contains(index) else { return }
        guard let anchor = buttonFrameOnScreen,
              let screen = self.screen ?? NSScreen.main else { return }
        hoverCharacterPanel.show(image: frames[index],
                                 anchor: anchor,
                                 screen: screen,
                                 scale: currentScale * 1.3)
    }

    private func displayMenuBarImage(_ image: NSImage) {
        guard let button = statusItem?.button else { return }
        if animationImageView?.isHidden == false {
            animationImageView?.image = image
            button.image = nil
        } else {
            button.image = image
        }
    }

    private func loadActivityFrames() {
        guard let resourceURL = Bundle.main.resourceURL else { return }
        frameLoadingTask = Task { [weak self] in
            // Make the head available before the independent tail-frame interpolation finishes.
            let hover = await Task.detached(priority: .userInitiated) {
                Self.prepareHoverFrames(resourceURL: resourceURL)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.hoverFrames = Dictionary(uniqueKeysWithValues: HoverAnimation.allCases.map {
                ($0, hover[$0.rawValue] ?? [])
            })
            self.refreshScaledHoverFrames()
            if self.shouldKeepPeekVisible { self.showHoverIfNeeded() }
            let prepared = await Task.detached(priority: .utility) {
                Self.prepareMenuBarFrames(resourceURL: resourceURL)
            }.value
            guard !Task.isCancelled else { return }
            self.activityFrames = prepared.activity
            self.frameSequence = ActivityAnimation.pingPongSequence(frameCount: self.activityFrames.count)
            self.refreshScaledActivityFrames()
            self.startActivityAnimation()
        }
    }

    private func showInitialActivityFrame() {
        let directory = Bundle.main.resourceURL?.appendingPathComponent("MenuBarFrames", isDirectory: true)
        guard let url = directory?.appendingPathComponent("png_1.png"),
              let image = NSImage(contentsOf: url),
              let fitted = Self.fittedActivityFrames([image]).first else { return }
        displayMenuBarImage(fitted)
    }

    nonisolated private static func prepareHoverFrames(resourceURL: URL) -> [String: [NSImage]] {
        var loadedHoverFrames: [String: [NSImage]] = [:]
        let kinds = ["appear", "disappear", "wink"]
        for kind in kinds {
            let folderURL = resourceURL
                .appendingPathComponent("HoverAnimations", isDirectory: true)
                .appendingPathComponent(kind, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            loadedHoverFrames[kind] = files.compactMap(NSImage.init(contentsOf:))
        }
        let flattened = kinds.flatMap { loadedHoverFrames[$0] ?? [] }
        let fittedHoverFrames = fittedActivityFrames(flattened)
        var offset = 0
        for kind in kinds {
            let count = loadedHoverFrames[kind]?.count ?? 0
            loadedHoverFrames[kind] = Array(fittedHoverFrames.dropFirst(offset).prefix(count))
            offset += count
        }

        return loadedHoverFrames
    }

    nonisolated private static func prepareMenuBarFrames(resourceURL: URL) -> PreparedMenuBarFrames {
        let directory = resourceURL.appendingPathComponent("MenuBarFrames", isDirectory: true)
        let sourceFrames: [NSImage] = (1...20).compactMap { index in
            NSImage(contentsOf: directory.appendingPathComponent("png_\(index).png"))
        }
        guard sourceFrames.count > 1 else {
            return PreparedMenuBarFrames(activity: sourceFrames, hover: [:])
        }
        var interpolatedFrames: [NSImage] = []
        for index in sourceFrames.indices {
            interpolatedFrames.append(sourceFrames[index])
            if index + 1 < sourceFrames.count {
                let tween = ActivityFrameMorpher.midpoint(from: sourceFrames[index], to: sourceFrames[index + 1])
                interpolatedFrames.append(tween ?? sourceFrames[index])
            }
        }
        return PreparedMenuBarFrames(activity: fittedActivityFrames(interpolatedFrames),
                                     hover: [:])
    }

    private func refreshScaledActivityFrames() {
        scaledActivityFrames = activityFrames.map { image in
            var proposedRect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                return image
            }
            let iconScale = currentScale * 1.3
            let displaySize = NSSize(width: image.size.width * iconScale,
                                     height: image.size.height * iconScale)
            return NSImage(cgImage: cgImage, size: displaySize)
        }
        if let frameWidth = scaledActivityFrames.first?.size.width {
            statusItem?.length = max(28, frameWidth)
        }
        refreshScaledHoverFrames()
    }

    private func refreshScaledHoverFrames() {
        scaledHoverFrames = hoverFrames.mapValues { images in
            images.map { image in
                var proposedRect = CGRect(origin: .zero, size: image.size)
                guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                    return image
                }
                let iconScale = currentScale * 1.3
                let displaySize = NSSize(width: image.size.width * iconScale,
                                         height: image.size.height * iconScale)
                return NSImage(cgImage: cgImage, size: displaySize)
            }
        }
    }

    nonisolated private static func fittedActivityFrames(_ images: [NSImage]) -> [NSImage] {
        let decoded = images.compactMap { image -> (NSImage, CGImage)? in
            var proposedRect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                return nil
            }
            return (image, cgImage)
        }
        guard decoded.count == images.count,
              let first = decoded.first?.1,
              decoded.allSatisfy({ $0.1.width == first.width && $0.1.height == first.height }) else {
            return images
        }

        let fullImageBounds = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        let frameBounds = decoded.compactMap { alphaBounds(of: $0.1) }
        guard frameBounds.count == decoded.count else { return images }
        let commonContentBounds = frameBounds
            .reduce(CGRect.null) { $0.union($1) }
            .integral
            .intersection(fullImageBounds)
        guard !commonContentBounds.isNull, !commonContentBounds.isEmpty else { return images }

        // Fit the union of every frame's visible pixels into the menu bar button.
        // Applying this one crop and scale to all frames keeps the body steady while
        // still reserving room for the tail's full range of motion.
        let targetSize = CGSize(width: 28, height: 24)
        let scale = min(targetSize.width / commonContentBounds.width,
                        targetSize.height / commonContentBounds.height)
        let displaySize = NSSize(width: commonContentBounds.width * scale,
                                 height: commonContentBounds.height * scale)

        var fitted: [NSImage] = []
        for (_, cgImage) in decoded {
            guard let cropped = cgImage.cropping(to: commonContentBounds) else { return images }
            fitted.append(NSImage(cgImage: cropped, size: displaySize))
        }
        return fitted
    }

    nonisolated private static func alphaBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where rgba[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func startActivityAnimation() {
        animationTimer?.invalidate(); metricsTimer?.invalidate()
        let now = ProcessInfo.processInfo.systemUptime
        activityClock = ActivityAnimationClock(sequenceLength: frameSequence.count, at: now)
        sequencePosition = 0
        showCurrentActivityFrame()
        if ProcessInfo.processInfo.arguments.contains("--trace-menu-animation") {
            activityTraceStart = now; activityTraceFrames = 0; activityTraceSamples = 0
        }
        _ = metricsSampler.sampleCPUUsage() // Establish the first CPU tick baseline.
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(sampleActivity), userInfo: nil, repeats: true)
        metricsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        scheduleNextFrame()
    }

    @objc private func sampleActivity() {
        let snapshot = metricsSampler.sample()
        SystemMetricsHistory.shared.record(snapshot, at: Date())
        let now = ProcessInfo.processInfo.systemUptime
        if let start = activityTraceStart, now > start {
            let line = String(format: "menu-animation target=%.2f submitted=%.2f interval=%.3f\n", activityClock?.framesPerSecond ?? 0, Double(activityTraceFrames) / (now - start), now - start)
            try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
            activityTraceSamples += 1; activityTraceFrames = 0
            activityTraceStart = activityTraceSamples < 8 ? now : nil
        }
        activityClock?.updateCPU(snapshot.cpuPercent, at: now)
        advanceActivityFrame()
    }

    private func scheduleNextFrame() {
        guard !frameSequence.isEmpty, activityClock != nil else { return }
        animationTimer?.invalidate()
        // Compensate for time already spent drawing. Late callbacks advance to the
        // real current phase instead of adding their own delay to every future frame.
        let interval = activityClock!.delayUntilNextFrame(at: ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(advanceActivityFrame), userInfo: nil, repeats: false)
        timer.tolerance = min(0.001, interval * 0.03)
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func advanceActivityFrame() {
        guard !frameSequence.isEmpty, let position = activityClock?.advance(to: ProcessInfo.processInfo.systemUptime) else { return }
        if sequencePosition != position {
            sequencePosition = position
            showCurrentActivityFrame()
        }
        scheduleNextFrame()
    }

    private func showCurrentActivityFrame() {
        guard let button = statusItem?.button else { return }
        if frameSequence.indices.contains(sequencePosition) {
            let image = scaledActivityFrames[frameSequence[sequencePosition]]
            displayMenuBarImage(image)
            if activityTraceStart != nil { activityTraceFrames += 1 }
        } else {
            let image = repository.firstFrameImage(clipID: "mini.idle", targetSize: NSSize(width: 24, height: 24))
            animationImageView?.image = image
            button.image = image
        }
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
