import AppKit
import QuartzCore
import WhaleCore

@MainActor
final class RoamPanelController: OverlayPanelController {
    var onClose: (() -> Void)?
    var onSelectSkin: ((SpriteRepository.Skin) -> Void)?
    private(set) var characterScale: Double = 1.17
    private var sizeLabel: NSTextField?
    private struct WalkRoute {
        let start: CGPoint
        let target: CGPoint
        let began: CFTimeInterval
        let duration: Double
    }
    private var walkRoute: WalkRoute?
    private var agentDepartureTask: Task<Void, Never>?
    private var agentDepartureSafety: Task<Void, Never>?
    private var departureGeneration = UUID()
    private var departureInProgress = false
    private var departureClose: (() -> Void)?
    private var ascentTask: Task<Void, Never>?
    private var ascentOrigin: CGPoint?
    static let classicFarewell = "full.community.b5987c85ef9d"

    func beginAgentLife(introduction: String) {
        petView?.beginAgentLife(introduction: introduction)
        guard let panel, isVisible else { return }
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0.4
            panel.animator().alphaValue = 1
        }
    }
    func setAgentStatus(_ line: String?) {
        guard line == nil || (!departureInProgress && ascentTask == nil) else { return }
        petView?.setPersistentAgentStatus(line)
    }
    func sayThinking(_ line: String) {
        guard !departureInProgress, ascentTask == nil, isVisible else { return }
        petView?.sayThinking(line)
    }
    @discardableResult
    func sayUsage(_ line: String) -> Bool {
        guard !departureInProgress, ascentTask == nil, isVisible, let petView else { return false }
        petView.sayUsage(line)
        return true
    }
    func cancelAgentDeparture() {
        ascentTask?.cancel(); ascentTask = nil
        if let panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
                if let origin = ascentOrigin { panel.animator().setFrame(CGRect(origin: origin, size: panel.frame.size), display: true) }
            }
        }
        ascentOrigin = nil
        petView?.cancelAngelDeparture()
        agentDepartureTask?.cancel(); agentDepartureTask = nil
        agentDepartureSafety?.cancel(); agentDepartureSafety = nil
        departureGeneration = UUID(); departureInProgress = false; departureClose = nil
        petView?.resumeAgentLife()
    }
    func prepareAgentDeparture(summary: String, deadline: Date) {
        petView?.setPersistentAgentStatus(nil)
        agentDepartureTask?.cancel(); agentDepartureSafety?.cancel()
        departureGeneration = UUID(); let generation = departureGeneration
        departureClose = nil; departureInProgress = true
        petView?.sayAgent(summary)
        let farewell = repository.selectedSkin == .classic ? Self.classicFarewell : nil
        let duration = farewell.flatMap { repository.clip($0) }?.frames.reduce(0) { $0 + $1.duration } ?? 0
        agentDepartureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = if let farewell { await self.repository.prepareClip(farewell) } else { false }
            let delay = max(0, deadline.timeIntervalSinceNow - duration)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, self.departureGeneration == generation else { return }
            self.petView?.sayAgent(summary)
            guard ready, let farewell, self.isVisible else { self.finishAgentFarewell(generation); return }
            self.petView?.play(farewell, looping: false, allowSharedAction: true) { [weak self] in self?.finishAgentFarewell(generation) }
        }
    }
    private func finishAgentFarewell(_ generation: UUID) {
        guard departureGeneration == generation else { return }
        departureInProgress = false
        let close = departureClose; departureClose = nil
        agentDepartureSafety?.cancel(); agentDepartureSafety = nil
        if let close { beginAscent(close) }
    }
    func completeAgentDeparture(_ close: @escaping () -> Void) {
        guard isVisible else { close(); return }
        guard departureInProgress else { beginAscent(close); return }
        departureClose = close
        let generation = departureGeneration
        // A hidden/paused/missing renderer must not leave an orphan forever.
        agentDepartureSafety = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.finishAgentFarewell(generation)
        }
    }


    private func beginAscent(_ close: @escaping () -> Void) {
        guard ascentTask == nil, let panel, isVisible else { close(); return }
        cancelWanderMovement()
        petView?.pauseAnimation()
        ascentOrigin = panel.frame.origin
        let generation = departureGeneration
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduced ? 0.25 : 3.6
        let distance = petView?.beginAngelDeparture(duration: duration, reducedMotion: reduced) ?? panel.frame.height
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            if reduced { panel.animator().alphaValue = 0 }
            else { panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: distance), display: true) }
        }
        ascentTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, !Task.isCancelled, self.departureGeneration == generation else { return }
            self.ascentTask = nil
            close()
        }
    }


    private func beginWander() {
        guard let panel, panel.isVisible, let screen = panel.screen,
              panel.isOnActiveSpace else {
            petView?.finishAutonomousWalk()
            return
        }
        let area = screen.visibleFrame
        let frame = panel.frame
        let minX = area.minX, maxX = max(minX, area.maxX - frame.width)
        let minY = area.minY, maxY = max(minY, area.maxY - frame.height)
        let start = frame.origin
        let proposed = CGPoint(x: Double.random(in: minX...maxX), y: Double.random(in: minY...maxY))
        guard let target = DisplayGeometry.horizontalWanderTarget(from: start, proposed: proposed,
            originBounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            maxDistance: CGFloat.random(in: 180...360) * characterScale) else {
            petView?.finishAutonomousWalk()
            return
        }
        let duration = min(10, max(3, hypot(target.x - start.x, target.y - start.y) / (55 * characterScale)))
        walkRoute = WalkRoute(start: start, target: target, began: CACurrentMediaTime(), duration: duration)
        petView?.setWalkingDirection(toRight: target.x > start.x)
        DesktopWalkClock.shared.add(self)
    }

    private func cancelWanderMovement() {
        walkRoute = nil
        DesktopWalkClock.shared.remove(self)
    }

    func advanceWander(at now: CFTimeInterval) {
        guard let route = walkRoute, let panel, panel.isVisible, panel.isOnActiveSpace,
              let screen = panel.screen else {
            cancelWanderMovement()
            petView?.finishAutonomousWalk()
            return
        }
        let progress = min(1, max(0, (now - route.began) / route.duration))
        let eased = progress * progress * (3 - 2 * progress)
        let origin = CGPoint(x: route.start.x + (route.target.x - route.start.x) * eased,
                             y: route.start.y + (route.target.y - route.start.y) * eased)
        let frame = DisplayGeometry.clamp(CGRect(origin: origin, size: panel.frame.size), to: screen.visibleFrame)
        panel.setFrameOrigin(frame.origin)
        if progress >= 1 {
            cancelWanderMovement()
            petView?.finishAutonomousWalk()
        }
    }

    override func hide() {
        petView?.cancelAngelDeparture()
        ascentTask?.cancel(); ascentTask = nil
        agentDepartureTask?.cancel(); agentDepartureTask = nil
        agentDepartureSafety?.cancel(); agentDepartureSafety = nil
        departureGeneration = UUID(); departureClose = nil; departureInProgress = false
        cancelWanderMovement()
        super.hide()
    }

    override func pauseAnimation() {
        cancelWanderMovement()
        super.pauseAnimation()
    }

    func setCharacterScale(_ scale: Double) {
        if petView?.isWandering == true { petView?.finishAutonomousWalk() }
        characterScale = min(2.5, max(0.4, scale))
        if let screen { resize(screen: screen, scale: characterScale) }
    }

    private func contextItem(_ title: String, action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(contextItem("关闭这只鲸鱼娘", action: #selector(closeCharacter)))
        let skinItem = NSMenuItem(title: "桌宠皮肤", action: nil, keyEquivalent: "")
        let skins = NSMenu()
        for skin in SpriteRepository.Skin.allCases {
            let item = contextItem(skin.title, action: #selector(selectSkin(_:)))
            item.representedObject = skin.rawValue
            item.state = repository.selectedSkin == skin ? .on : .off
            skins.addItem(item)
        }
        skinItem.submenu = skins
        menu.addItem(skinItem)
        let size = NSMenuItem(title: "调整大小", action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        let row = NSMenuItem()
        let control = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 56))
        let label = NSTextField(labelWithString: "\(Int(characterScale / 1.3 * 100))%")
        label.alignment = .center
        label.frame = NSRect(x: 10, y: 30, width: 200, height: 20)
        sizeLabel = label
        let slider = NSSlider(value: characterScale / 1.3 * 100, minValue: 31, maxValue: 192,
                              target: self, action: #selector(changeCharacterSize(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 10, y: 5, width: 200, height: 24)
        control.addSubview(label)
        control.addSubview(slider)
        row.view = control
        sizes.addItem(row)
        size.submenu = sizes
        menu.addItem(size)
        let actions = NSMenuItem(title: "播放动画", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        choices.addItem(contextItem("随机播放全部动作", action: #selector(playRandom)))
        for (category, clips) in Dictionary(grouping: repository.communityActions + repository.walkingActions, by: \.category).sorted(by: { $0.key < $1.key }) {
            let group = NSMenuItem(title: category, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for clip in clips {
                let item = contextItem(clip.title, action: #selector(playChosen(_:)))
                item.representedObject = clip.clipID
                submenu.addItem(item)
            }
            group.submenu = submenu
            choices.addItem(group)
        }
        actions.submenu = choices
        menu.addItem(actions)
        menu.addItem(.separator())
        menu.addItem(contextItem("退出 WhaleGirl", action: #selector(quitApp)))
        return menu
    }

    @objc private func closeCharacter() { onClose?() }
    @objc private func selectSkin(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let skin = SpriteRepository.Skin(rawValue: value) else { return }
        onSelectSkin?(skin)
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func playRandom() { play("full.idle") }
    @objc private func playChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        play(id, looping: false)
    }
    @objc private func changeCharacterSize(_ slider: NSSlider) {
        setCharacterScale(slider.doubleValue / 100 * 1.3)
        sizeLabel?.stringValue = "\(Int((characterScale / 1.3 * 100).rounded()))%"
    }

    func show(centeredAt point: CGPoint, screen: NSScreen, scale: Double, clipID: String) {
        characterScale = scale
        let height = DisplayGeometry.fullHeight(screenFrame: screen.frame, userScale: scale)
        let aspect = repository.canvasAspect(for: "full.idle")
        let size = CGSize(width: max(height * aspect, PetView.minimumDockWidth),
                          height: height + PetView.controlDockHeight)
        let frame = DisplayGeometry.frameCentered(on: point, size: size, visibleFrame: screen.visibleFrame)
        show(frame: frame, clipID: clipID)
        petView?.onRequestWander = { [weak self] in self?.beginWander() }
        petView?.onCancelWander = { [weak self] in self?.cancelWanderMovement() }
        petView?.endUserInteraction()
        petView?.onContextMenu = { [weak self] event in
            guard let self, let view = self.petView else { return }
            NSMenu.popUpContextMenu(self.makeContextMenu(), with: event, for: view)
        }
    }

    func move(centeredAt point: CGPoint) {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? panel.screen else { return }
        let artwork = petView?.artworkViewportSize ?? CGSize(width: panel.frame.width, height: panel.frame.height - balanceBubbleHeadroom)
        resizeArtwork(to: artwork, centeredAt: point, screen: screen)
    }

    func resize(screen: NSScreen, scale: Double) {
        guard let panel else { return }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.minY + (panel.frame.height - balanceBubbleHeadroom) / 2)
        let height = DisplayGeometry.fullHeight(screenFrame: screen.frame, userScale: scale)
        let aspect = repository.canvasAspect(for: "full.idle")
        let size = CGSize(width: max(height * aspect, PetView.minimumDockWidth),
                          height: height + PetView.controlDockHeight)
        resizeArtwork(to: size, centeredAt: center, screen: screen)
    }
}

/// One clock for all moving characters, stopped whenever none are walking.
@MainActor
private final class DesktopWalkClock {
    static let shared = DesktopWalkClock()
    private final class WeakWalker {
        weak var controller: RoamPanelController?
        init(_ controller: RoamPanelController) { self.controller = controller }
    }
    private var walkers: [ObjectIdentifier: WeakWalker] = [:]
    private var timer: Timer?

    func add(_ controller: RoamPanelController) {
        walkers[ObjectIdentifier(controller)] = WeakWalker(controller)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.003
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func remove(_ controller: RoamPanelController) {
        walkers[ObjectIdentifier(controller)] = nil
        stopIfEmpty()
    }

    private func tick() {
        walkers = walkers.filter { $0.value.controller != nil }
        let active = walkers.values.compactMap(\.controller)
        let now = CACurrentMediaTime()
        for controller in active { controller.advanceWander(at: now) }
        stopIfEmpty()
    }

    private func stopIfEmpty() {
        guard walkers.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }
}
