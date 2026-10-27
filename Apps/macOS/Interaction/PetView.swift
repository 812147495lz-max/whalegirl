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
    static let balanceBubbleHeadroom: CGFloat = 144
    static let minimumBubbleWidth: CGFloat = 268
    /// The controller keeps this canvas independent of the larger speech window.
    var artworkViewportSize: CGSize? { didSet { needsLayout = true } }
    var onBubbleHeadroomChanged: ((CGFloat) -> Void)?
    private(set) var isCharacterHovered = false
    private enum BubbleKind { case balance, hover, dialogue, usage }
    private var bubbleKind: BubbleKind = .dialogue
    private var pendingUsageSpeech: String?
    private var bubbleGeneration = UUID()

    var onContextMenu: ((NSEvent) -> Void)?
    var onRequestWander: (() -> Void)?
    var onCancelWander: (() -> Void)?
    weak var interactionDelegate: PetViewInteractionDelegate?
    private let spriteLayer = CALayer()
    private(set) var agentDepartureMask: CALayer?
    private(set) var agentHalo: CAShapeLayer?
    private let bubble = PetSpeechBubbleView()
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
        let viewport = artworkViewportSize ?? bounds.size
        let artworkBounds = CGRect(x: (bounds.width - viewport.width) / 2, y: Self.controlDockHeight,
                                   width: viewport.width, height: max(1, viewport.height - Self.controlDockHeight))
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
        let thought = bubbleKind == .balance || bubbleKind == .usage
        let size = bubble.arrange(bubbleLabel, balance: bubbleKind == .balance, thought: thought,
                                  maximumWidth: max(40, min(260, bounds.width - 8)))
        // The cropped sprite frame excludes the transparent animation canvas.
        // Keep the smallest thought circle close to the top of the character.
        let head = CGPoint(x: spriteLayer.frame.midX, y: spriteLayer.frame.maxY)
        if thought {
            let x = min(max(4, head.x - size.width / 2 - 12), max(4, bounds.width - size.width - 4))
            bubble.frame = CGRect(x: x, y: head.y + 3, width: size.width, height: size.height)
            bubble.thoughtHeadX = head.x - x
        } else {
            let y = artworkViewportSize.map { $0.height + 9 }
                ?? max(2, bounds.height - size.height - 3)
            bubble.frame = CGRect(x: (bounds.width - size.width) / 2, y: y,
                                  width: size.width, height: size.height)
        }
        if let viewport = artworkViewportSize {
            onBubbleHeadroomChanged?(max(Self.balanceBubbleHeadroom, bubble.frame.maxY - viewport.height + 6))
        }
        bubble.needsDisplay = true
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
            if bubbleKind == .usage, !bubble.isHidden {
                pendingUsageSpeech = bubbleLabel.string
                bubbleTask?.cancel(); bubbleTask = nil; bubbleGeneration = UUID()
            }
            isCharacterHovered = false
            bubble.isHidden = true
        } else if isHoldingFinishedAction, !isAnimationPaused {
            holdThenReturnToIdle()
        } else if isResting, !isAnimationPaused {
            scheduleRandomCommunityAction()
        }
        if !suppressed {
            if let line = pendingUsageSpeech { pendingUsageSpeech = nil; sayUsage(line) }
            else { restorePersistentAgentStatus() }
        }
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
        bubbleTask?.cancel(); bubbleTask = nil; bubbleGeneration = UUID()
        pendingUsageSpeech = nil; bubble.isHidden = true
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
        persistentAgentStatus = line
        if bubbleKind == .balance {
            if line == nil { bubble.isHidden = true }
            else { restorePersistentAgentStatus() }
        } else if bubble.isHidden, bubbleTask == nil {
            restorePersistentAgentStatus()
        }
    }
    private func restorePersistentAgentStatus(animated: Bool = false) {
        guard isCharacterHovered, let line = persistentAgentStatus, !isEnvironmentSuppressed else {
            if bubbleKind == .balance { bubble.isHidden = true }
            return
        }
        guard bubbleTask == nil else { return }
        bubbleKind = .balance
        bubbleLabel.string = line; layoutBubble(); bubble.isHidden = false
        bubble.layer?.removeAnimation(forKey: "hoverFloat")
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let float = CABasicAnimation(keyPath: "transform.translation.y")
            float.fromValue = -7; float.toValue = 0; float.duration = 0.22
            float.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bubble.layer?.add(float, forKey: "hoverFloat")
        }
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
        showSpeech(line, kind: .dialogue, duration: max(2.4, min(7, 1.2 + Double(line.count) * 0.18)))
    }

    /// Real usage reports stay readable without requiring pointer hover.
    func sayUsage(_ line: String) {
        guard !isEnvironmentSuppressed else { pendingUsageSpeech = line; return }
        showSpeech(line, kind: .usage, duration: 8)
    }

    private func showSpeech(_ line: String, kind: BubbleKind, duration: Double) {
        guard !isEnvironmentSuppressed else { return }
        bubbleTask?.cancel()
        let generation = UUID(); bubbleGeneration = generation
        bubbleKind = kind
        bubbleLabel.string = line
        layoutBubble()
        bubble.layer?.removeAnimation(forKey: "hoverFloat")
        bubble.isHidden = false
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.bubbleGeneration == generation else { return }
            self.bubbleTask = nil
            self.bubble.isHidden = true
            self.restorePersistentAgentStatus()
        }
        bubbleTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }

    /// Called by the shared pointer poll even while the transparent panel ignores
    /// events. Rectangular tracking areas alone cannot describe the sprite alpha.
    func updateCharacterHover(at point: CGPoint?) {
        let hovered = !isEnvironmentSuppressed && point.map(containsCharacter(at:)) == true
        guard hovered != isCharacterHovered else { return }
        isCharacterHovered = hovered
        if hovered {
            guard bubbleTask == nil else { return }
            if persistentAgentStatus != nil { restorePersistentAgentStatus(animated: true); return }
            let candidates = DeepSeekChanDialog.lines.filter {
                $0 != lastHoverSpeechLine && $0 != Self.lastDesktopSpeechLine
            }
            let line = candidates.randomElement() ?? DeepSeekChanDialog.randomLine(excluding: lastHoverSpeechLine)
            lastHoverSpeechLine = line
            Self.lastDesktopSpeechLine = line
            showSpeech(line, kind: .hover, duration: max(2.4, min(7, 1.2 + Double(line.count) * 0.18)))
            if currentVariant == "full" { return }
            play("peek.wave", looping: false) { [weak self] in self?.play("peek.idle") }
        } else if bubbleKind == .balance || bubbleKind == .hover {
            if bubbleKind == .hover {
                bubbleTask?.cancel(); bubbleTask = nil; bubbleGeneration = UUID()
            }
            bubble.isHidden = true
        }
    }

    override func mouseEntered(with event: NSEvent) {
        updateCharacterHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        updateCharacterHover(at: nil)
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
        if local.y > spriteLayer.frame.minY + spriteLayer.frame.height * 0.62 {
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


/// Native thought bubble inspired by the reference widget's white body, blue ink
/// and two small thought dots. Original geometry; no web code or artwork is bundled.
@MainActor
final class PetSpeechBubbleView: NSView {
    private(set) var isBalance = false
    private var isThought = false
    var thoughtHeadX: CGFloat?
    private let ink = NSColor(srgbRed: 0.23, green: 0.32, blue: 0.53, alpha: 1)

    func arrange(_ text: NSTextView, balance: Bool, thought: Bool = false, maximumWidth: CGFloat) -> CGSize {
        isBalance = balance
        isThought = balance || thought
        let inset: CGFloat = isThought && maximumWidth >= 180 ? 20 : 12
        let tail: CGFloat = isThought ? 33 : 0
        let vertical: CGFloat = isThought ? 9 : 6
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = isThought ? 2 : 0
        let content = NSMutableAttributedString(string: text.string, attributes: [
            .font: font, .foregroundColor: isThought ? ink : NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        if balance {
            let lines = text.string.components(separatedBy: "\n")
            var location = 0
            for (index, line) in lines.enumerated() {
                let range = NSRange(location: location, length: (line as NSString).length)
                content.addAttributes([
                    .font: index == 0 ? NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
                        : NSFont.systemFont(ofSize: 10.5, weight: .medium),
                    .foregroundColor: index < 2 ? ink : NSColor(srgbRed: 0.36, green: 0.43, blue: 0.61, alpha: 1)
                ], range: range)
                if index == 0, line.hasPrefix("余额 ") {
                    content.addAttribute(.font, value: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                                         range: NSRange(location: 0, length: 3))
                }
                location += range.length + 1
            }
        }
        text.textStorage?.setAttributedString(content)
        let natural = ceil(content.size().width) + 2
        let width = max(1, min(natural, maximumWidth - inset * 2))
        guard let container = text.textContainer, let manager = text.layoutManager else { return .zero }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = max(14, ceil(manager.usedRect(for: container).height)) + 2
        let size = CGSize(width: width + inset * 2, height: height + vertical * 2 + tail)
        text.frame = CGRect(x: inset, y: vertical + tail, width: width, height: height)
        needsDisplay = true
        return size
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if !isThought {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill(); shape.fill()
            NSColor.separatorColor.setStroke(); shape.lineWidth = 1; shape.stroke()
            return
        }
        // A soft scalloped cloud, followed by three circles shrinking toward the head.
        let body = CGRect(x: 4, y: 33, width: max(1, bounds.width - 8), height: max(1, bounds.height - 37))
        let outline = NSBezierPath()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: body.minX + body.width * x, y: body.minY + body.height * y)
        }
        func curve(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) {
            outline.curve(to: point(x, y), controlPoint1: point(a, b), controlPoint2: point(c, d))
        }
        outline.move(to: point(0.08, 0.22))
        curve(0.04, 0.63, -0.03, 0.24, -0.02, 0.52)
        curve(0.20, 0.94, 0.00, 0.88, 0.11, 1.02)
        curve(0.44, 0.98, 0.24, 1.07, 0.38, 1.04)
        curve(0.70, 0.98, 0.50, 1.07, 0.63, 1.07)
        curve(0.94, 0.75, 0.85, 1.08, 1.00, 0.98)
        curve(0.95, 0.30, 1.04, 0.68, 1.02, 0.42)
        curve(0.77, 0.04, 1.00, 0.09, 0.88, -0.04)
        curve(0.50, 0.04, 0.69, -0.06, 0.57, -0.02)
        curve(0.24, 0.03, 0.42, -0.04, 0.30, -0.05)
        curve(0.08, 0.22, 0.12, -0.03, 0.04, 0.07)
        outline.close()
        let fill = NSColor(srgbRed: 0.98, green: 0.99, blue: 1, alpha: 1)
        let border = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? ink
            : NSColor(srgbRed: 0.57, green: 0.67, blue: 0.85, alpha: 1)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.32, green: 0.45, blue: 0.70, alpha: 0.16)
        shadow.shadowBlurRadius = 3; shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.set()
        fill.setFill(); outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        border.setStroke(); outline.lineWidth = 1.35; outline.stroke()
        let headX = min(max(20, thoughtHeadX ?? bounds.midX), bounds.width - 20)
        for dot in [CGRect(x: headX - 18.5, y: 22, width: 11, height: 9),
                    CGRect(x: headX - 9, y: 11, width: 7, height: 6),
                    CGRect(x: headX - 2, y: 1, width: 4, height: 4)] {
            let path = NSBezierPath(ovalIn: dot)
            fill.setFill(); path.fill(); border.setStroke(); path.lineWidth = 1.15; path.stroke()
        }
    }
}
