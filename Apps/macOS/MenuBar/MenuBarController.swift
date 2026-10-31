import AppKit
import QuartzCore
import WhaleCore


@MainActor
final class PassthroughImageView: NSImageView {
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
    var iconInputView: StatusIconInputView?
    var iconPointerTimer: Timer?
    var wasIconLeftDown = false
    var pendingIconClick: NSEvent?
    var suppressIconClickUntil: TimeInterval = 0
    var iconDragStart: CGPoint?
    var didDragCharacter = false

    enum HoverAnimation: String, CaseIterable, Sendable {
        case appear
        case disappear
        case wink
    }



    weak var delegate: MenuBarControllerDelegate?
    let repository: SpriteRepository
    let metricsSampler: SystemMetricsSampler
    var completionNames: [String] = []
    var completionQuotas: [String: String] = [:]
    var completionDismissal: Task<Void, Never>?
    var completionGeneration = UUID()
    let completionHoldDuration: Duration
    let peekSuppression: @MainActor (NSScreen) -> Bool
    var completionSpeechLine: String? { hoverCharacterPanel.currentSpeechLine }
    var completionSpeechPanel: NSPanel? { hoverCharacterPanel.currentSpeechPanel }
    var networkCompletionLine: String?
    var isCompletionPeekActive: Bool { !completionNames.isEmpty || networkCompletionLine != nil }
    var completionLine: String {
        networkCompletionLine ?? completionNames.map { name in name + " 回复完成啦" + (completionQuotas[name].map { "\n" + $0 } ?? "") }.joined(separator: "\n")
    }

    let informationController: MenuBarInformationController
    let aiStore: AIMonitorStore?
    let contextMenuPresenter: @MainActor (NSMenu, NSEvent, NSView) -> Void
    var suppressHoverUntilExit = false
    var hoverCooldownUntil: TimeInterval = 0
    var hoverCooldownTask: Task<Void, Never>?
    var isHoverCoolingDown: Bool { ProcessInfo.processInfo.systemUptime < hoverCooldownUntil }
    var isHoverCharacterVisible: Bool { hoverCharacterPanel.handoffPose() != nil }
    var informationState: MenuBarInformationController.State { informationController.state }
    var statusItem: NSStatusItem?
    var animationImageView: PassthroughImageView?
    var trackingArea: NSTrackingArea?
    var animationTimer: Timer?
    var hoverPlaybackTimer: Timer?
    var winkTimer: Timer?
    var metricsTimer: Timer?
    var frameLoadingTask: Task<Void, Never>?
    var activityFrames: [NSImage] = []
    var scaledActivityFrames: [NSImage] = []
    var hoverFrames: [HoverAnimation: [NSImage]] = [:]
    var scaledHoverFrames: [HoverAnimation: [NSImage]] = [:]
    let hoverCharacterPanel: HoverCharacterPanel
    var frameSequence: [Int] = []
    var sequencePosition = 0
    var hoverAnimation: HoverAnimation?
    var hoverFramePosition = 0
    var isPointerHovering = false
    var isPeekPinned = false
    var incomingMessageActive = false
    let incomingBubble = MessageBubbleController()
    var shouldKeepPeekVisible: Bool { isPointerHovering || isPeekPinned || isCompletionPeekActive || incomingMessageActive }
    var lastHoverSpeechLine: String?
    var pendingHoverSpeechLine: String?
    var activityClock: ActivityAnimationClock?
    // Opt-in, eight-line numeric timing probe; no account/event content and no default logging.
    var activityTraceStart: TimeInterval?
    var activityTraceFrames = 0
    var activityTraceSamples = 0
    var heartEffects: [HeartEffect] = []
    var currentScale = 1.0
    weak var scaleValueLabel: NSTextField?

    @MainActor
    final class HeartEffect {
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
        wasIconLeftDown = NSEvent.pressedMouseButtons & 1 != 0
        let pointerTimer = Timer(timeInterval: 1.0 / 60, target: self,
                                 selector: #selector(pollIconPointer), userInfo: nil, repeats: true)
        pointerTimer.tolerance = 0.004
        iconPointerTimer = pointerTimer
        RunLoop.main.add(pointerTimer, forMode: .common)
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

    func uninstall() {
        incomingBubble.finish(.cancelled)
        cancelCompletionPeek()
        informationController.shutdown()
        hoverCooldownTask?.cancel()
        hoverCooldownTask = nil
        hoverCooldownUntil = 0
        isPointerHovering = false
        suppressHoverUntilExit = false
        iconPointerTimer?.invalidate()
        iconPointerTimer = nil
        pendingIconClick = nil
        wasIconLeftDown = false
        suppressIconClickUntil = 0
        iconDragStart = nil
        didDragCharacter = false
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

    @objc func statusClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        handleStatusClick(event)
    }

    func showComputerInformation() {
        guard !informationController.isActive, let anchor = buttonFrameOnScreen, let screen = self.screen ?? NSScreen.main else { return }
        incomingBubble.finish(.dismissed)
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
            guard shouldHandleIconLeftClick(event) else { return }
            if informationController.isActive { showContextMenu(event: event) }
            else { showHeartAboveStatusItem() }
        }
    }


}
