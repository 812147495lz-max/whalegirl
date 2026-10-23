import AppKit

@MainActor
final class PetView: HitRegionView {
    struct AutonomyConfiguration {
        var drawActionCount: () -> Int = { Int.random(in: 0...3) }
        var idleDelay: ClosedRange<Double> = 6...10
        var finishedPoseDelay: Double = 1
        var agentBirthDelay: Double? = nil
        var dshBalanceCompanion = false
    }

    static let controlDockHeight: CGFloat = 0
    static let minimumDockWidth: CGFloat = 1

    var onContextMenu: ((NSEvent) -> Void)?
    var onRequestWander: (() -> Void)?
    var onCancelWander: (() -> Void)?
    weak var interactionDelegate: PetViewInteractionDelegate?
    private let spriteLayer = CALayer()
    private(set) var agentDepartureMask: CALayer?
    private(set) var agentHalo: CAShapeLayer?
    private let bubble = NSView()
    private let bubbleLabel = NSTextView(frame: .zero)
    private var lastHoverSpeechLine: String?
    private static var lastDesktopSpeechLine: String?
    private var isEnvironmentSuppressed = false
    private var alphaMask: SpriteAlphaMask?
    var isDraggingCharacter: Bool { dragStart != nil }
    private let repository: SpriteRepository
    private let animator: SpriteAnimator
    private var tracking: NSTrackingArea?
    private var dragStart: CGPoint?
    private var bubbleTask: DispatchWorkItem?
    private var currentVariant = "peek"
    private(set) var currentClipID = "peek.idle"
    private var communityActionBag: [String] = []
    private var isResting = false
    private var displayedStationaryClipID: String?
    private var displayedClipID = "peek.idle"
    private var randomActionTask: Task<Void, Never>?
    private var returnToIdleTask: Task<Void, Never>?
    private(set) var isHoldingFinishedAction = false
    private var isAnimationPaused = false
    private(set) var isUserInteracting = false
    private(set) var isWandering = false
    private var isWalkingRight = false
    private(set) var randomActionsUntilWalk: Int
    private let autonomy: AutonomyConfiguration
    private var agentBirthTask: Task<Void, Never>?
    private var awaitingAgentBirth: Bool
    private var pendingAgentSpeech: String?
    private var persistentAgentStatus: String?

    init(frame: NSRect, repository: SpriteRepository, autonomy: AutonomyConfiguration = .init()) {
        self.autonomy = autonomy
        awaitingAgentBirth = autonomy.agentBirthDelay != nil
        randomActionsUntilWalk = min(3, max(0, autonomy.drawActionCount()))
        self.repository = repository
        animator = SpriteAnimator(layer: spriteLayer, repository: repository)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(spriteLayer)
        spriteLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        animator.shouldAnimate = { [weak self] in
            guard let window = self?.window else { return true }
            return window.isVisible && window.isOnActiveSpace
        }
        animator.onFrameDisplayed = { [weak self] mask in
            guard let self else { return }
            self.alphaMask = mask
            if !self.isEnvironmentSuppressed, let line = self.pendingAgentSpeech {
                self.pendingAgentSpeech = nil; self.say(line)
            }
            let actual = self.animator.displayedClipID ?? self.currentClipID
            if actual != self.displayedClipID {
                self.displayedClipID = actual
                self.needsLayout = true
                self.layoutSubtreeIfNeeded()
            }
            let displayed = actual.hasPrefix("full.community.")
                && actual != self.repository.resolvedClipID("full.idle") ? actual : nil
            if displayed != self.displayedStationaryClipID {
                self.displayedStationaryClipID = displayed
                self.repository.retainStationaryAction(displayed, owner: self)
            }
            if self.isResting, actual == self.currentClipID, self.randomActionTask == nil {
                self.scheduleRandomCommunityAction()
            }
        }

        bubbleLabel.alignment = .center
        bubbleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        bubbleLabel.textColor = .labelColor
        bubbleLabel.isEditable = false
        bubbleLabel.isSelectable = false
        bubbleLabel.drawsBackground = false
        bubbleLabel.textContainerInset = .zero
        bubbleLabel.textContainer?.lineFragmentPadding = 0
        bubbleLabel.textContainer?.widthTracksTextView = false
        bubbleLabel.textContainer?.heightTracksTextView = false
        bubble.identifier = NSUserInterfaceItemIdentifier("character.speech-bubble")
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        bubble.layer?.cornerRadius = 9
        bubble.layer?.borderWidth = 1
        bubble.layer?.borderColor = NSColor.separatorColor.cgColor
        bubble.addSubview(bubbleLabel)
        bubble.isHidden = true
        addSubview(bubble)
    }

    required init?(coder: NSCoder) { nil }

    func refreshSkin() {
        communityActionBag.removeAll()
        randomActionsUntilWalk = min(3, max(0, autonomy.drawActionCount()))
        let wasPaused = isAnimationPaused
        play("full.idle")
        if wasPaused { pauseAnimation() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let artworkBounds = CGRect(x: 0, y: Self.controlDockHeight, width: bounds.width,
                                   height: max(1, bounds.height - Self.controlDockHeight))
        let aspect = repository.canvasAspect(for: "\(currentVariant).idle")
        let artworkWidth = min(artworkBounds.width, artworkBounds.height * aspect)
        let artworkHeight = min(artworkBounds.height, artworkWidth / max(0.01, aspect))
        let canvas = CGRect(x: artworkBounds.midX - artworkWidth / 2,
                            y: artworkBounds.midY - artworkHeight / 2,
                            width: artworkWidth, height: artworkHeight)
        let region = repository.renderLayout(for: displayedClipID)?.normalized
            ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let x = isWalkingRight ? 1 - region.maxX : region.minX
        let spriteFrame = CGRect(x: canvas.minX + x * canvas.width,
                                 y: canvas.minY + region.minY * canvas.height,
                                 width: region.width * canvas.width, height: region.height * canvas.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // bounds/position are independent of the horizontal mirror transform.
        spriteLayer.bounds = CGRect(origin: .zero, size: spriteFrame.size)
        spriteLayer.position = CGPoint(x: spriteFrame.midX, y: spriteFrame.midY)
        CATransaction.commit()
        layoutBubble()
    }

    private func layoutBubble() {
        let font = bubbleLabel.font ?? .systemFont(ofSize: 11)
        let maxWidth = max(24, min(240, bounds.width - 8))
        let naturalWidth = ceil((bubbleLabel.string as NSString).size(withAttributes: [.font: font]).width)
        let textWidth = max(1, min(naturalWidth + 2, maxWidth - 24))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        // Measure with the same TextKit container that draws the text, including
        // CJK fallback fonts. A separate NSString estimate can miss a wrapped row.
        bubbleLabel.textStorage?.setAttributes([.font: font, .foregroundColor: NSColor.labelColor,
                                               .paragraphStyle: paragraph],
                                              range: NSRange(location: 0, length: (bubbleLabel.string as NSString).length))
        guard let container = bubbleLabel.textContainer, let manager = bubbleLabel.layoutManager else { return }
        container.containerSize = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let textHeight = max(14, ceil(manager.usedRect(for: container).height)) + 2
        let size = CGSize(width: textWidth + 24, height: textHeight + 12)
        bubble.frame = CGRect(x: (bounds.width - size.width) / 2,
                              y: max(2, bounds.height - size.height - 3),
                              width: size.width, height: size.height)
        bubbleLabel.frame = CGRect(x: 12, y: 6, width: textWidth, height: textHeight)
    }

    func containsCharacter(at point: CGPoint) -> Bool {
        let frame = spriteLayer.frame
        guard frame.width > 0, frame.height > 0, frame.contains(point), let alphaMask else { return false }
        let x = (point.x - frame.minX) / frame.width
        return alphaMask.contains(normalized: CGPoint(x: isWalkingRight ? min(1 - x, 1 - .ulpOfOne) : x,
                                                     y: (point.y - frame.minY) / frame.height))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        containsCharacter(at: convert(point, from: superview)) ? self : nil
    }

    override var hitRegionBounds: CGRect { spriteLayer.frame }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next)
        tracking = next
        super.updateTrackingAreas()
    }

    func play(_ clipID: String, looping: Bool? = nil, allowSharedAction: Bool = false, completion: (() -> Void)? = nil) {
        randomActionTask?.cancel()
        randomActionTask = nil
        returnToIdleTask?.cancel()
        returnToIdleTask = nil
        isHoldingFinishedAction = false
        cancelWander()
        isAnimationPaused = false
        currentVariant = clipID.hasPrefix("full") ? "full" : "peek"
        repository.retainStationaryAction(displayedStationaryClipID, owner: self)
        let requested = repository.resolvedClipID(clipID)
        isResting = clipID == "full.idle"
        if !isResting { agentBirthTask?.cancel(); agentBirthTask = nil; awaitingAgentBirth = false }
        if requested.hasPrefix("full.community."), !isResting, !allowSharedAction {
            guard let selected = repository.claimStationaryAction(requested,
                candidates: communityActionBag + randomActionCandidates.shuffled(), owner: self) else {
                // No duplicates when the finite library is exhausted; wait for a free action.
                randomActionTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard !Task.isCancelled, let self, !self.isAnimationPaused else { return }
                    self.play(clipID, looping: looping, completion: completion)
                }
                return
            }
            currentClipID = selected
        } else {
            currentClipID = requested
        }
        if let hitbox = repository.clip(clipID)?.frames.first?.hitbox {
            normalizedHitRegion = CGRect(x: hitbox.x, y: hitbox.y, width: hitbox.width, height: hitbox.height)
        }
        if currentClipID.hasPrefix("full.community.") {
            // Idle is a neutral held pose, shared by resting pets. It must never
            // substitute an occupied random action and loop that reaction forever.
            let shouldHold = isResting && completion == nil && looping != false
            let shouldLoop = looping ?? (clipID == "full.dragged")
            animator.play(currentClipID, looping: shouldLoop, holdingPose: shouldHold) { [weak self] in
                if let completion {
                    completion()
                } else if let self, !self.isAnimationPaused {
                    self.holdThenReturnToIdle()
                }
            }
        } else {
            animator.play(clipID, looping: looping) { [weak self] in
                if let completion { completion() }
                else if clipID.hasPrefix("full.walk"), let self, !self.isAnimationPaused {
                    self.play("full.idle")
                }
            }
        }
        needsLayout = true
    }

    private var randomActionCandidates: [String] {
        let idle = repository.resolvedClipID("full.idle")
        let actions = repository.communityActions.filter {
            !autonomy.dshBalanceCompanion || $0.category == "工作与表情" || $0.title.lowercased().replacingOccurrences(of: " ", with: "") == "偷吃token"
        }
        return actions.map(\.clipID).filter { $0 != idle }
    }

    private func preferredAgentAction(fallback: String?) -> String? {
        if autonomy.dshBalanceCompanion, Double.random(in: 0..<1) < 0.35,
           let token = repository.communityActions.first(where: { $0.title.lowercased().replacingOccurrences(of: " ", with: "") == "偷吃token" }) {
            return token.clipID
        }
        return fallback
    }

    private func holdThenReturnToIdle() {
        isHoldingFinishedAction = true
        returnToIdleTask?.cancel()
        returnToIdleTask = Task { @MainActor [weak self] in
            guard let delay = self?.autonomy.finishedPoseDelay else { return }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self, !self.isAnimationPaused,
                  !self.isEnvironmentSuppressed else { return }
            self.play("full.idle")
        }
    }

    private func scheduleRandomCommunityAction() {
        guard !awaitingAgentBirth else { return }
        guard !repository.communityActions.isEmpty, !isAnimationPaused,
              !isUserInteracting, !isWandering, !isEnvironmentSuppressed,
              isResting, animator.displayedClipID == currentClipID else { return }
        let shouldWalk = !autonomy.dshBalanceCompanion && randomActionsUntilWalk == 0 && onRequestWander != nil && !repository.walkingActions.isEmpty
        if communityActionBag.isEmpty {
            communityActionBag = randomActionCandidates.shuffled()
        }
        randomActionTask?.cancel()
        repository.retainStationaryAction(displayedStationaryClipID, owner: self)
        guard let preferred = shouldWalk ? repository.walkingActions.randomElement()?.clipID : preferredAgentAction(fallback: communityActionBag.last) else { return }
        // Reserve before decoding; never predecode a busy action and then discard it.
        guard let next = shouldWalk ? preferred : repository.claimStationaryAction(preferred,
            candidates: communityActionBag, owner: self) else { return }
        let delay = Double.random(in: autonomy.idleDelay)
        randomActionTask = Task { @MainActor [weak self] in
            guard let repository = self?.repository else { return }
            let ready = await repository.prepareClip(next)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self, !self.isAnimationPaused,
                  !self.isUserInteracting, !self.isEnvironmentSuppressed, self.currentVariant == "full" else { return }
            guard ready else {
                self.scheduleRandomCommunityAction()
                return
            }
            if shouldWalk {
                self.play(next, looping: true)
                self.isWandering = true
                self.onRequestWander?()
            } else {
                self.communityActionBag.removeAll { $0 == next }
                self.play(next, looping: false) { [weak self] in
                    guard let self else { return }
                    self.randomActionsUntilWalk = max(0, self.randomActionsUntilWalk - 1)
                    if !self.isAnimationPaused { self.holdThenReturnToIdle() }
                }
            }
        }
    }

    func setWalkingDirection(toRight: Bool) {
        isWalkingRight = toRight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.transform = CATransform3DMakeScale(toRight ? -1 : 1, 1, 1)
        CATransaction.commit()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func cancelWander() {
        guard isWandering else { return }
        isWandering = false
        onCancelWander?()
        setWalkingDirection(toRight: false)
    }

    func finishAutonomousWalk() {
        guard isWandering else { return }
        randomActionsUntilWalk = min(3, max(0, autonomy.drawActionCount()))
        play("full.idle")
    }

    func beginUserInteraction() {
        isUserInteracting = true
        randomActionTask?.cancel()
        randomActionTask = nil
        repository.retainStationaryAction(displayedStationaryClipID, owner: self)
        if isWandering || isHoldingFinishedAction { play("full.idle") }
    }

    func endUserInteraction() {
        isUserInteracting = false
        if !isAnimationPaused, currentVariant == "full",
           isResting {
            scheduleRandomCommunityAction()
        }
    }

    func pauseAnimation() {
        agentBirthTask?.cancel(); agentBirthTask = nil; awaitingAgentBirth = false
        if isWandering { play("full.idle") }
        isAnimationPaused = true
        returnToIdleTask?.cancel()
        returnToIdleTask = nil
        randomActionTask?.cancel()
        randomActionTask = nil
        repository.retainStationaryAction(displayedStationaryClipID, owner: self)
        animator.pause()
    }

    func releaseStationaryAction() {
        repository.retainStationaryAction(nil, owner: self)
    }

    func resumeAnimation() {
        isAnimationPaused = false
        animator.resume()
        if isHoldingFinishedAction {
            holdThenReturnToIdle()
        } else if currentVariant == "full", isResting {
            scheduleRandomCommunityAction()
        }
    }

    func setEnvironmentSuppressed(_ suppressed: Bool) {
        guard isEnvironmentSuppressed != suppressed else { return }
        isEnvironmentSuppressed = suppressed
        if suppressed {
            returnToIdleTask?.cancel()
            returnToIdleTask = nil
            randomActionTask?.cancel()
            randomActionTask = nil
            repository.retainStationaryAction(displayedStationaryClipID, owner: self)
            if isWandering { finishAutonomousWalk() }
            bubble.isHidden = true
        } else if isHoldingFinishedAction, !isAnimationPaused {
            holdThenReturnToIdle()
        } else if isResting, !isAnimationPaused {
            scheduleRandomCommunityAction()
        }
        if !suppressed { restorePersistentAgentStatus() }
    }

    func beginAgentLife(introduction: String) {
        sayAgent(introduction)
        agentBirthTask?.cancel()
        randomActionTask?.cancel()
        agentBirthTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(self?.autonomy.agentBirthDelay ?? 2)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.randomActionsUntilWalk = max(1, self.randomActionsUntilWalk)
            guard let preferred = self.preferredAgentAction(fallback: self.randomActionCandidates.randomElement()),
                  let first = self.repository.claimStationaryAction(preferred, candidates: self.randomActionCandidates.shuffled(), owner: self) else {
                self.awaitingAgentBirth = false; self.scheduleRandomCommunityAction(); return
            }
            let ready = await self.repository.prepareClip(first)
            guard ready, !Task.isCancelled, !self.isAnimationPaused, !self.isEnvironmentSuppressed else {
                self.awaitingAgentBirth = false
                self.repository.retainStationaryAction(self.displayedStationaryClipID, owner: self)
                if !Task.isCancelled { self.scheduleRandomCommunityAction() }
                return
            }
            self.play(first, looping: false)
        }
    }
    func resumeAgentLife() { agentBirthTask?.cancel(); agentBirthTask = nil; awaitingAgentBirth = false; play("full.idle") }
    private static let departureMaskCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 8; cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    /// A broad downward-bulging circular edge, with smooth alpha across the lip.
    private static func curvedDepartureImage(width: Int, height: Int, bodyHeight: CGFloat,
                                             feather: CGFloat, radius: CGFloat) -> CGImage? {
        let key = "\(width)|\(height)|\(bodyHeight)|\(feather)|\(radius)" as NSString
        if let image = departureMaskCache.object(forKey: key) { return image }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let center = CGFloat(width) / 2
        let offsets = (0..<width).map { x in
            let dx = CGFloat(x) + 0.5 - center
            return radius - sqrt(max(0, radius * radius - dx * dx))
        }
        for row in 0..<height {
            let y = CGFloat(height - row) - 0.5
            for x in 0..<width {
                let boundary = 2 * bodyHeight + feather / 2 + offsets[x]
                let t = max(0, min(1, (boundary - y + feather / 2) / feather))
                pixels[(row * width + x) * 4 + 3] = UInt8((t * t * (3 - 2 * t) * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        departureMaskCache.setObject(image, forKey: key, cost: pixels.count)
        return image
    }
    /// The halo and character share the same curved, feathered pipe-mouth mask.
    func beginAngelDeparture(duration: Double, reducedMotion: Bool) -> CGFloat {
        cancelAngelDeparture()
        bubbleTask?.cancel(); bubble.isHidden = true
        layoutSubtreeIfNeeded()
        let halo = CAShapeLayer()
        halo.name = "agent.departure.halo"
        let width = min(72, max(30, spriteLayer.frame.width * 0.3))
        let centerY = min(bounds.maxY - 9, spriteLayer.frame.maxY + 7)
        let rect = CGRect(x: spriteLayer.frame.midX - width / 2, y: centerY - 5, width: width, height: 10)
        halo.path = CGPath(ellipseIn: rect, transform: nil)
        halo.fillColor = NSColor.clear.cgColor
        halo.strokeColor = NSColor(calibratedRed: 1, green: 0.94, blue: 0.65, alpha: 1).cgColor
        halo.lineWidth = 2.2
        halo.shadowColor = NSColor(calibratedRed: 1, green: 0.87, blue: 0.36, alpha: 1).cgColor
        halo.shadowOpacity = 0.9; halo.shadowRadius = 5; halo.shadowOffset = .zero
        halo.contentsScale = window?.backingScaleFactor ?? 2
        layer?.addSublayer(halo); agentHalo = halo
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0; appear.toValue = 1; appear.duration = 0.35
        halo.add(appear, forKey: "haloAppear")
        let height = bounds.height
        let feather = min(40, max(18, height * 0.12))
        let radius = max(bounds.width * 0.6, spriteLayer.frame.width * 1.4)
        let maxBow = radius - sqrt(max(0, radius * radius - bounds.width * bounds.width / 4))
        let distance = height + feather + maxBow
        guard !reducedMotion else { return distance }
        let mask = CALayer()
        mask.name = "agent.departure.curvedFeather"
        let maskHeight = ceil(2 * height + 2 * feather + maxBow)
        mask.frame = CGRect(x: 0, y: -height, width: bounds.width, height: maskHeight)
        mask.contents = Self.curvedDepartureImage(width: max(1, Int(ceil(bounds.width))), height: max(1, Int(maskHeight)),
            bodyHeight: height, feather: feather, radius: radius)
        layer?.mask = mask; agentDepartureMask = mask
        let animation = CABasicAnimation(keyPath: "position.y")
        animation.fromValue = mask.position.y; animation.toValue = mask.position.y - distance
        animation.duration = duration; animation.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.position.y -= distance
        mask.add(animation, forKey: "featheredDeparture")
        CATransaction.commit()
        return distance
    }
    func cancelAngelDeparture() {
        agentDepartureMask?.removeAllAnimations(); layer?.mask = nil; agentDepartureMask = nil
        agentHalo?.removeAllAnimations(); agentHalo?.removeFromSuperlayer(); agentHalo = nil
    }

    func setPersistentAgentStatus(_ line: String?) {
        let old = persistentAgentStatus
        persistentAgentStatus = line
        guard let line else {
            if bubbleLabel.string == old { bubbleTask?.cancel(); bubble.isHidden = true }
            return
        }
        if old != line || bubble.isHidden { restorePersistentAgentStatus() }
    }
    private func restorePersistentAgentStatus() {
        guard let line = persistentAgentStatus, !isEnvironmentSuppressed else { return }
        bubbleTask?.cancel(); bubbleTask = nil
        bubbleLabel.string = line; layoutBubble(); bubble.isHidden = false
    }

    func sayThinking(_ line: String) {
        guard !isEnvironmentSuppressed, !isAnimationPaused, bubble.isHidden else { return }
        say(line)
    }
    func sayAgent(_ line: String) {
        if isEnvironmentSuppressed { pendingAgentSpeech = line }
        else { say(line) }
    }

    func say(_ line: String) {
        guard !isEnvironmentSuppressed else { return }
        bubbleTask?.cancel()
        bubbleLabel.string = line
        layoutBubble()
        bubble.isHidden = false
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.persistentAgentStatus != nil { self.restorePersistentAgentStatus() }
            else { self.bubble.isHidden = true }
        }
        bubbleTask = task
        let duration = max(2.4, min(7, 1.2 + Double(line.count) * 0.18))
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }

    override func mouseEntered(with event: NSEvent) {
        if persistentAgentStatus != nil { restorePersistentAgentStatus(); return }
        let candidates = DeepSeekChanDialog.lines.filter {
            $0 != lastHoverSpeechLine && $0 != Self.lastDesktopSpeechLine
        }
        let line = candidates.randomElement() ?? DeepSeekChanDialog.randomLine(excluding: lastHoverSpeechLine)
        lastHoverSpeechLine = line
        Self.lastDesktopSpeechLine = line
        say(line)
        if currentVariant == "full" { return }
        let greetingClip = currentVariant == "peek" ? "peek.wave" : "full.happy"
        play(greetingClip, looping: false) { [weak self] in
            guard let self else { return }
            self.play("\(self.currentVariant).idle")
        }
    }

    override func mouseExited(with event: NSEvent) {
        if persistentAgentStatus != nil { restorePersistentAgentStatus(); return }
        bubble.isHidden = true
    }

    override func rightMouseDown(with event: NSEvent) {
        beginUserInteraction()
        defer { endUserInteraction() }
        onContextMenu?(event)
    }

    override func mouseDown(with event: NSEvent) {
        beginUserInteraction()
        dragStart = screenPoint(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = screenPoint(for: event)
        interactionDelegate?.petView(self, didDragTo: point, downwardDistance: max(0, start.y - point.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer { endUserInteraction() }
        guard let start = dragStart else { return }
        let end = screenPoint(for: event)
        dragStart = nil
        let distance = hypot(end.x - start.x, end.y - start.y)
        if distance >= 8 {
            interactionDelegate?.petViewDidEndDrag(self)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        if local.y > bounds.height * 0.62 {
            interactionDelegate?.petViewDidPetHead(self)
        } else {
            interactionDelegate?.petViewDidPokeFace(self)
        }
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}
