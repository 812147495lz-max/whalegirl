import AppKit
import QuartzCore

@MainActor
class OverlayPanelController: NSObject {
    private(set) var panel: PetPanel?
    private(set) var petView: PetView?
    private(set) var shouldRemainVisible = false
    private var isFullScreenSuppressed = false
    let repository: SpriteRepository
    private let autonomy: PetView.AutonomyConfiguration
    weak var interactionDelegate: PetViewInteractionDelegate? {
        didSet { petView?.interactionDelegate = interactionDelegate }
    }

    init(repository: SpriteRepository, autonomy: PetView.AutonomyConfiguration = .init()) {
        self.autonomy = autonomy
        self.repository = repository
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }
    var screen: NSScreen? { panel?.screen }

    func show(frame: CGRect, clipID: String) {
        let panel = panel ?? makePanel(frame: frame)
        panel.setFrame(frame, display: true)
        self.panel = panel
        shouldRemainVisible = true
        FullScreenAvoidance.shared.refreshIfNeeded(force: true)
        updateFullScreenAvoidance()
        petView?.play(clipID)
        refreshMouseAcceptance(at: NSEvent.mouseLocation)
        DesktopOverlayCoordinator.shared.add(self)
    }

    func refreshMouseAcceptance(at screenPoint: CGPoint) {
        guard let panel, let petView, panel.isVisible else { return }
        if !panel.frame.contains(screenPoint), !petView.isDraggingCharacter {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            return
        }
        let local = petView.convert(panel.convertPoint(fromScreen: screenPoint), from: nil)
        let shouldIgnore = !(petView.isDraggingCharacter || petView.containsCharacter(at: local))
        if panel.ignoresMouseEvents != shouldIgnore { panel.ignoresMouseEvents = shouldIgnore }
    }

    func updateFullScreenAvoidance() {
        guard shouldRemainVisible, let panel else { return }
        // screen may be nil after orderOut; recover it from the unchanged window frame.
        let targetScreen = panel.screen ?? NSScreen.screens.first {
            $0.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY))
        }
        let suppressed = targetScreen.map { FullScreenAvoidance.shared.shouldSuppress(on: $0) } ?? true
        if suppressed {
            if panel.isVisible { panel.orderOut(nil) }
            panel.ignoresMouseEvents = true
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        if isFullScreenSuppressed != suppressed {
            isFullScreenSuppressed = suppressed
            petView?.setEnvironmentSuppressed(suppressed)
        }
    }

    func hide() {
        shouldRemainVisible = false
        DesktopOverlayCoordinator.shared.remove(self)
        petView?.pauseAnimation()
        panel?.orderOut(nil)
        petView?.releaseStationaryAction()
    }

    func play(_ clipID: String, looping: Bool? = nil, completion: (() -> Void)? = nil) {
        petView?.play(clipID, looping: looping, completion: completion)
    }

    func say(_ line: String) { petView?.say(line) }
    func pauseAnimation() { petView?.pauseAnimation() }
    func resumeAnimation() { petView?.resumeAnimation() }

    private func makePanel(frame: CGRect) -> PetPanel {
        let panel = PetPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Apple recommends fullScreenPrimary to keep all-app overlays out of other
        // apps' fullscreen Spaces. The borderless, nonresizable pet has no fullscreen UI.
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary,
                                    .fullScreenPrimary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        let view = PetView(frame: CGRect(origin: .zero, size: frame.size), repository: repository, autonomy: autonomy)
        view.autoresizingMask = [.width, .height]
        view.interactionDelegate = interactionDelegate
        panel.contentView = view
        petView = view
        return panel
    }
}

@MainActor
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Reuses the same windows across Spaces; shares pointer polling and workspace observers.
@MainActor
private final class DesktopOverlayCoordinator {
    static let shared = DesktopOverlayCoordinator()
    private final class WeakOverlay {
        weak var value: OverlayPanelController?
        init(_ value: OverlayPanelController) { self.value = value }
    }
    private var overlays: [ObjectIdentifier: WeakOverlay] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func add(_ overlay: OverlayPanelController) {
        overlays[ObjectIdentifier(overlay)] = WeakOverlay(overlay)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.003
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreWindowOrder() }
            })
        }
    }

    func remove(_ overlay: OverlayPanelController) {
        overlays[ObjectIdentifier(overlay)] = nil
        stopIfEmpty()
    }

    private func restoreWindowOrder() {
        FullScreenAvoidance.shared.refreshIfNeeded(force: true)
        for overlay in overlays.values.compactMap(\.value) {
            overlay.updateFullScreenAvoidance()
            guard let panel = overlay.panel, panel.isVisible, panel.isOnActiveSpace else { continue }
            // Normal floating level; do not join other apps' fullscreen spaces.
            panel.orderFrontRegardless()
        }
    }

    private func tick() {
        overlays = overlays.filter { $0.value.value != nil }
        FullScreenAvoidance.shared.refreshIfNeeded()
        let mouse = NSEvent.mouseLocation
        for overlay in overlays.values.compactMap(\.value) {
            overlay.updateFullScreenAvoidance()
            overlay.refreshMouseAcceptance(at: mouse)
        }
        stopIfEmpty()
    }

    private func stopIfEmpty() {
        guard overlays.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}

/// Geometry only: no window titles, images, Accessibility access or screen recording.
@MainActor
final class FullScreenAvoidance {
    static let shared = FullScreenAvoidance()
    private var coveredScreens: [CGRect] = []
    private var hasSnapshot = false
    private var lastRefresh: CFTimeInterval = 0
    private var refreshTask: Task<Void, Never>?

    func shouldSuppress(on screen: NSScreen) -> Bool {
        !hasSnapshot || coveredScreens.contains(screen.frame)
    }

    func waitForInitialSnapshot() async {
        guard !hasSnapshot else { return }
        refreshIfNeeded(force: true)
        await refreshTask?.value
    }

    func refreshIfNeeded(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard refreshTask == nil, force || now - lastRefresh >= 0.5 else { return }
        lastRefresh = now
        let screens = NSScreen.screens.map(\.frame)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        refreshTask = Task { [weak self] in
            let covered = await Task.detached(priority: .utility) {
                Self.readCoveredDisplays(screens, primaryTop: primaryTop, ownPID: ownPID)
            }.value
            guard let self else { return }
            self.coveredScreens = covered
            self.hasSnapshot = true
            self.refreshTask = nil
        }
    }

    nonisolated private static func readCoveredDisplays(_ displays: [CGRect], primaryTop: CGFloat,
                                                     ownPID: Int32) -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] else { return displays }
        return coveredDisplays(displays, windows: windows, primaryTop: primaryTop, ownPID: ownPID)
    }

    nonisolated static func coveredDisplays(_ displays: [CGRect], windows: [[String: Any]],
                                            primaryTop: CGFloat, ownPID _: Int32) -> [CGRect] {
        return displays.filter { display in
            let quartzDisplay = CGRect(x: display.minX, y: primaryTop - display.maxY,
                                       width: display.width, height: display.height)
            // Front-to-back: an ordinary foreground window must not be mistaken
            // for a fullscreen window merely because a large background window exists.
            var frontOwner: Int32?
            for window in windows {
                guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                      let value = window[kCGWindowBounds as String] as? [String: Any],
                      let bounds = CGRect(dictionaryRepresentation: value as CFDictionary) else { continue }
                let intersection = quartzDisplay.intersection(bounds)
                guard !intersection.isNull,
                      intersection.width * intersection.height >= min(16000, display.width * display.height * 0.05) else { continue }
                if frontOwner == nil { frontOwner = owner }
                guard owner == frontOwner else { continue }
                // A dialog belonging to the fullscreen app doesn't make it non-fullscreen.
                let tolerance: CGFloat = 2
                if bounds.minX <= quartzDisplay.minX + tolerance
                    && bounds.minY <= quartzDisplay.minY + tolerance
                    && bounds.maxX >= quartzDisplay.maxX - tolerance
                    && bounds.maxY >= quartzDisplay.maxY - tolerance { return true }
            }
            return false
        }
    }
}
