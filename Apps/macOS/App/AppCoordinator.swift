import AppKit
import WhaleCore
import os

@MainActor
final class AppCoordinator: NSObject {
    private let logger = Logger(subsystem: "io.whalegirl.app", category: "coordinator")
    private let repository: SpriteRepository
    private let menuBar: MenuBarController
    private var desktopPets: [RoamPanelController] = []
    private let agentCompanions = AgentCompanionController()
    private var replyCompletions = ReplyCompletionTracker()
    private var agentBoundPets: [String: RoamPanelController] = [:]
    private var aiObservation: AIMonitorObservation?
    private weak var draggedMenuPet: RoamPanelController?
    private let roamPanel: RoamPanelController
    private let dashboard: DashboardWindowController
    private let metricsSampler: SystemMetricsSampler
    private let eventHub = EventHub()
    private let eventStateStore: EventStateStore
    private let notificationService = UserNotificationService()
    private let launchAtLoginService = LaunchAtLoginService()
    private var eventServer: LocalEventServer?
    private var eventServerStatus = "未启动"
    private let reducer = PetInteractionReducer()
    private var state = PetState()
    private var hideTask: DispatchWorkItem?

    private var quietMode: Bool {
        get { UserDefaults.standard.bool(forKey: "quietMode") }
        set { UserDefaults.standard.set(newValue, forKey: "quietMode") }
    }

    private var notificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "notificationsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "notificationsEnabled") }
    }

    private var userScale: Double {
        get {
            let defaults = UserDefaults.standard
            if defaults.integer(forKey: "userScaleFormatVersion") >= 3 {
                let saved = defaults.double(forKey: "userScale")
                return saved == 0 ? 0.9 : DisplayGeometry.clampedPreferenceScale(saved)
            }

            // Previous releases stored absolute scale values up to 130%.
            // Normalize them, then make the new default 90% of the old appearance.
            let previous = defaults.object(forKey: "userScale") as? Double
            let previousFormat = defaults.integer(forKey: "userScaleFormatVersion")
            let normalized = DisplayGeometry.migratedScale(from: previous)
            let migrated = (previous == nil || (previousFormat >= 2 && abs(normalized - 1.0) < 0.001))
                ? 0.9
                : normalized
            defaults.set(migrated, forKey: "userScale")
            defaults.set(3, forKey: "userScaleFormatVersion")
            return migrated
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(DisplayGeometry.clampedPreferenceScale(newValue), forKey: "userScale")
            defaults.set(3, forKey: "userScaleFormatVersion")
        }
    }

    private var displayScale: Double { userScale * 1.3 }

    static func make() throws -> AppCoordinator {
        try AppCoordinator(
            repository: SpriteRepository(bundle: .main),
            eventStateStore: EventStateStore()
        )
    }

    private init(
        repository: SpriteRepository,
        eventStateStore: EventStateStore,
        metricsSampler: SystemMetricsSampler = SystemMetricsSampler()
    ) {
        self.repository = repository
        self.eventStateStore = eventStateStore
        self.metricsSampler = metricsSampler
        menuBar = MenuBarController(repository: repository, metricsSampler: metricsSampler, aiStore: .shared)
        roamPanel = RoamPanelController(repository: repository)
        dashboard = DashboardWindowController()
        super.init()
        menuBar.delegate = self
        roamPanel.interactionDelegate = self
        roamPanel.onClose = { [weak self] in self?.dispatch(.dismissRequested) }
        roamPanel.onSelectSkin = { [weak self] in self?.menuBarDidSelectSkin($0) }
        dashboard.dashboardDelegate = self
        dashboard.onRefresh = { [weak self] in self?.refreshDashboard() }
        agentCompanions.onSpawn = { [weak self] key in
            guard let self else { return }
            if let existing = self.agentBoundPets[key] { existing.cancelAgentDeparture(); return }
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                self.logger.error("Agent companion could not find a display")
                self.agentCompanions.dismiss(key); return
            }
            let area = screen.visibleFrame
            let point = CGPoint(x: area.minX + area.width * Double.random(in: 0.25...0.75),
                                y: area.minY + area.height * Double.random(in: 0.25...0.75))
            guard let pet = self.spawnDesktopPet(at: point, agentManaged: true) else { self.agentCompanions.dismiss(key); return }
            self.agentBoundPets[key] = pet
            let id = key.split(separator: "|").last.map(String.init) ?? "agent"
            let introduction = key.hasPrefix("root|")
                ? "\(self.agentCompanions.labels[key] ?? "主 Agent") 开始工作啦"
                : AgentCompanionSpeech.introduction(id: id, label: self.agentCompanions.labels[key])
            pet.beginAgentLife(introduction: introduction)
            self.logger.notice("Agent companion created; visible=\(pet.isVisible, privacy: .public), count=\(self.agentBoundPets.count, privacy: .public)")
        }
        agentCompanions.onThinking = { [weak self] key, line in self?.agentBoundPets[key]?.sayThinking(line) }
        agentCompanions.onFinished = { [weak self] key, connected in
            guard let self, let pet = self.agentBoundPets[key], let deadline = self.agentCompanions.roster.entries[key]?.retireAt else { return }
            let summary = AgentCompanionSpeech.ending(label: key.hasPrefix("root|") ? nil : self.agentCompanions.labels[key], disconnected: !connected)
            pet.prepareAgentDeparture(summary: summary, deadline: deadline)
        }
        agentCompanions.onResumed = { [weak self] key in self?.agentBoundPets[key]?.cancelAgentDeparture() }
        agentCompanions.onClose = { [weak self] key in
            guard let self, let pet = self.agentBoundPets[key] else { return }
            pet.completeAgentDeparture { [weak self, weak pet] in
                guard let self, let pet, self.agentBoundPets[key] === pet else { return }
                self.closeDesktopPet(pet)
            }
        }
        aiObservation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: AIMonitorStore.changed,
            object: AIMonitorStore.shared, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
                guard let self else { return }
                let enabled = AIMonitorStore.shared.preferences.autoAgentPets
                if !enabled { self.agentBoundPets.values.forEach { $0.cancelAgentDeparture() } }
                self.agentCompanions.setEnabled(enabled)
            } })
    }

    func start() {
        AIMonitorStore.shared.start()
        menuBar.install(scale: userScale)
        Task { [repository] in
            _ = await repository.prepareClip("full.idle")
        }
        Task {
            do {
                if let stored = try eventStateStore.load() { await eventHub.restore(stored) }
            } catch {
                logger.error("Failed to restore redacted event state: \(String(describing: type(of: error)), privacy: .public)")
            }
            startEventServer()
            refreshDashboard()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        if let option = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--demo-pets=") }),
           let count = Int(option.dropFirst("--demo-pets=".count)), let screen = NSScreen.main {
            // Reproducible multi-character profiling without synthesizing mouse events.
            let area = screen.visibleFrame
            for index in 0..<min(20, max(0, count)) {
                let point = CGPoint(x: area.minX + area.width * Double(index % 5 + 1) / 6,
                                    y: area.minY + area.height * Double(index / 5 + 1) / 5)
                spawnDesktopPet(at: point)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--show-dashboard") {
            showDashboard()
        } else if ProcessInfo.processInfo.arguments.contains("--show-peek") {
            dispatch(.statusTapped)
        } else if ProcessInfo.processInfo.arguments.contains("--show-full") {
            dispatch(.statusTapped)
            dispatch(.draggedDown(distance: 100))
        }
    }

    func stop() {
        AIMonitorStore.shared.stop()
        agentCompanions.closeAll()
        hideTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        closeAllDesktopPets()
        menuBar.uninstall()
        dashboard.close()
        eventServer?.stop()
        eventServer = nil
    }

    private func dispatch(_ interaction: PetInteraction) {
        let effects = reducer.reduce(state: &state, interaction: interaction)
        for effect in effects { apply(effect) }
    }

    private func apply(_ effect: PetEffect) {
        switch effect {
        case .showPeek:
            roamPanel.hide()
            menuBar.showPeek()
            scheduleAutoHide()

        case .showFull:
            hideTask?.cancel()
            let point = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
            guard let screen else { return }
            menuBar.hidePeek(animated: false)
            roamPanel.show(centeredAt: point, screen: screen, scale: displayScale, clipID: "full.dragged")

        case .hideOverlays:
            hideTask?.cancel()
            menuBar.hidePeek()
            roamPanel.hide()

        case .returnToMenuBar:
            roamPanel.play("full.return", looping: false) { [weak self] in
                guard let self else { return }
                self.roamPanel.hide()
                self.dispatch(.returnFinished)
            }

        case let .play(id):
            activePanel?.play(id, looping: nil, completion: nil)

        case let .say(line):
            activePanel?.say(line)
        }
    }

    private var activePanel: OverlayPanelController? {
        if roamPanel.isVisible { return roamPanel }
        return nil
    }

    private func scheduleAutoHide() {
        guard !ProcessInfo.processInfo.arguments.contains("--demo-hold") else { return }
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.dispatch(.idleTimedOut) }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    @objc private func workspaceWillSleep() {
        hideTask?.cancel()
        roamPanel.pauseAnimation()
        desktopPets.forEach { $0.pauseAnimation() }
    }

    @objc private func workspaceDidWake() {
        activePanel?.resumeAnimation()
        desktopPets.forEach { $0.resumeAnimation() }
        if state.mode == .peeking { scheduleAutoHide() }
    }

    @discardableResult
    private func spawnDesktopPet(at point: CGPoint, agentManaged: Bool = false) -> RoamPanelController? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return nil }
        var autonomy = PetView.AutonomyConfiguration()
        if agentManaged { autonomy.agentBirthDelay = 2 }
        let pet = RoamPanelController(repository: repository, autonomy: autonomy)
        pet.interactionDelegate = self
        pet.onSelectSkin = { [weak self] in self?.menuBarDidSelectSkin($0) }
        pet.onClose = { [weak self, weak pet] in
            guard let self, let pet else { return }
            self.closeDesktopPet(pet)
        }
        desktopPets.append(pet)
        pet.show(centeredAt: point, screen: screen, scale: displayScale, clipID: "full.idle")
        return pet
    }

    private func desktopPet(for view: PetView) -> RoamPanelController? {
        desktopPets.first { $0.petView === view }
    }

    private func closeDesktopPet(_ pet: RoamPanelController) {
        for key in agentBoundPets.filter({ $0.value === pet }).map(\.key) {
            agentCompanions.dismiss(key); agentBoundPets.removeValue(forKey: key)
        }
        pet.hide()
        desktopPets.removeAll { $0 === pet }
    }

    private func closeAllDesktopPets() {
        // Explicit close is immediate, even if a farewell is currently awaiting its final frame.
        agentBoundPets.removeAll()
        agentCompanions.closeAll()
        desktopPets.forEach { $0.hide() }
        desktopPets.removeAll()
        draggedMenuPet = nil
        roamPanel.hide()
    }

    private func showDashboard() {
        dashboard.show(quietMode: quietMode, notificationsEnabled: notificationsEnabled)
        Task {
            await eventHub.markAllRead()
            persistEventState()
            refreshDashboard()
        }
    }

    private func refreshDashboard() {
        let metrics = metricsSampler.sample()
        Task {
            let snapshot = await eventHub.snapshot()
            menuBar.updateAttentionCount(snapshot.sessions.reduce(0) {
                $0 + max($1.unreadCount, $1.needsAttention ? 1 : 0)
            })
            dashboard.updateSettings(
                quietMode: quietMode,
                notificationsEnabled: notificationsEnabled,
                launchAtLogin: launchAtLoginService.isEnabled
            )
            dashboard.update(
                metrics: metrics,
                eventState: snapshot,
                socketStatus: eventServerStatus,
                launchAtLoginStatus: launchAtLoginService.statusText
            )
        }
    }

    private func startEventServer() {
        do {
            let server = try LocalEventServer(
                frameHandler: { [weak self] frame in
                    Task { @MainActor [weak self] in await self?.receiveEventFrame(frame) }
                },
                failureHandler: { [weak self] in
                    Task { @MainActor [weak self] in await self?.recordEventFailure() }
                }
            )
            try server.start()
            eventServer = server
            eventServerStatus = "已监听本机 Socket"
        } catch {
            eventServerStatus = "不可用（\(String(describing: type(of: error)))）"
            logger.error("Local event server unavailable: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func receiveEventFrame(_ frame: Data) async {
        do {
            let event = try WhaleEventCodec.decode(frame)
            let result = await eventHub.ingest(event)
            if result.disposition == .accepted {
                AIMonitorStore.shared.recordActivity(event)
                if let name = replyCompletions.ingest(event), !quietMode {
                    menuBar.showReplyCompletion(sourceName: name)
                }
                if AIMonitorStore.shared.preferences.autoAgentPets {
                    agentCompanions.receive(event)
                    logger.notice("Companion event \(event.eventType, privacy: .public); roster=\(self.agentCompanions.roster.entries.count, privacy: .public), pets=\(self.agentBoundPets.count, privacy: .public)")
                }
                persistEventState()
                if NotificationPolicy.shouldDeliverSystemNotification(for: event), notificationsEnabled, !quietMode {
                    await notificationService.deliver(result)
                }
            }
        } catch {
            await eventHub.recordDecodeFailure()
            persistEventState()
            logger.warning("Rejected local WhaleEvent: \(String(describing: type(of: error)), privacy: .public)")
        }
        refreshDashboard()
    }

    private func recordEventFailure() async {
        await eventHub.recordDecodeFailure()
        persistEventState()
        refreshDashboard()
    }

    private func persistEventState() {
        Task {
            let snapshot = await eventHub.snapshot()
            do {
                try eventStateStore.save(snapshot)
            } catch {
                logger.error("Failed to save redacted event state: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }
}

@MainActor
extension AppCoordinator: MenuBarControllerDelegate {
    func menuBarDidRequestDashboard() { showDashboard() }

    func menuBarDidRequestTogglePeek() { dispatch(.statusTapped) }

    func menuBarDidRequestFull() {
        _ = spawnDesktopPet(at: NSEvent.mouseLocation)
    }

    func menuBarDidDragCharacter(to point: CGPoint, isNew: Bool) {
        if isNew {
            draggedMenuPet = spawnDesktopPet(at: point)
            draggedMenuPet?.petView?.beginUserInteraction()
        } else { draggedMenuPet?.move(centeredAt: point) }
    }

    func menuBarDidFinishDraggingCharacter() {
        draggedMenuPet?.petView?.endUserInteraction()
        draggedMenuPet = nil
    }

    func menuBarDidRequestCloseAllCharacters() {
        closeAllDesktopPets()
        dispatch(.dismissRequested)
    }

    func menuBarDidRequestAction(_ clipID: String) {
        guard repository.communityActions.contains(where: { $0.clipID == clipID }) else { return }
        let pet = desktopPets.last ?? spawnDesktopPet(at: NSEvent.mouseLocation)
        pet?.play(clipID, looping: false)
    }

    func menuBarDidSelectSkin(_ skin: SpriteRepository.Skin) {
        guard repository.selectSkin(skin) else { return }
        desktopPets.forEach { $0.petView?.refreshSkin() }
        roamPanel.petView?.refreshSkin()
    }

    func menuBarDidChangeScale(_ scale: Double) {
        userScale = scale
        menuBar.updateScale(scale)
        if state.mode == .peeking {
            apply(.showPeek)
        } else if state.mode == .interacting, let screen = roamPanel.screen {
            roamPanel.resize(screen: screen, scale: scale * 1.3)
        }
    }

    func menuBarDidRequestQuit() { NSApp.terminate(nil) }
}

@MainActor
extension AppCoordinator: DashboardWindowControllerDelegate {
    func dashboardDidRequestActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    func dashboardDidChangeQuietMode(_ enabled: Bool) { quietMode = enabled }

    func dashboardDidChangeNotifications(_ enabled: Bool) {
        guard enabled else {
            notificationsEnabled = false
            return
        }
        Task {
            notificationsEnabled = await notificationService.requestAuthorization()
            refreshDashboard()
        }
    }

    func dashboardDidChangeLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginService.setEnabled(enabled)
        } catch {
            logger.error("Launch-at-login update failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        refreshDashboard()
    }
}

@MainActor
extension AppCoordinator: PetViewInteractionDelegate {
    func petViewDidPetHead(_ view: PetView) {
        if let pet = desktopPet(for: view) { pet.play("full.happy", looping: false); return }
        scheduleAutoHide()
        dispatch(.headPetted)
    }

    func petViewDidPokeFace(_ view: PetView) {
        if let pet = desktopPet(for: view) { pet.play("full.poke", looping: false); return }
        scheduleAutoHide()
        dispatch(.facePoked)
    }

    func petViewDidRequestFull(_ view: PetView) {
        hideTask?.cancel()
        if state.mode != .peeking { dispatch(.statusTapped) }
        dispatch(.draggedDown(distance: 100))
    }

    func petViewDidRequestReturn(_ view: PetView) {
        if let pet = desktopPet(for: view) { closeDesktopPet(pet); return }
        if state.mode == .interacting { dispatch(.dragEnded) }
    }

    func petViewDidRequestDismiss(_ view: PetView) {
        if let pet = desktopPet(for: view) { closeDesktopPet(pet); return }
        hideTask?.cancel()
        dispatch(.dismissRequested)
    }

    func petView(_ view: PetView, didDragTo screenPoint: CGPoint, downwardDistance: Double) {
        if let pet = desktopPet(for: view) { pet.move(centeredAt: screenPoint); return }
        if state.mode == .peeking {
            dispatch(.draggedDown(distance: downwardDistance))
        } else if state.mode == .interacting {
            roamPanel.move(centeredAt: screenPoint)
        }
    }

    func petViewDidEndDrag(_ view: PetView) {
        // Desktop characters stay where released. Return is an explicit control.
        if desktopPet(for: view) != nil || roamPanel.petView === view { return }
        dispatch(.dragEnded)
    }
}
