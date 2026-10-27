import AppKit
import WhaleCore
import os

@MainActor
final class AppCoordinator: NSObject {
    let logger = Logger(subsystem: "io.whalegirl.app", category: "coordinator")
    let repository: SpriteRepository
    let menuBar: MenuBarController
    var desktopPets: [RoamPanelController] = []
    let agentCompanions = AgentCompanionController()
    var replyCompletions = ReplyCompletionTracker()
    var completionTasks: [UUID: Task<Void, Never>] = [:]
    var agentBoundPets: [String: RoamPanelController] = [:]
    var usageAnnouncements: [UsageReportRecord] = []
    var usageAnnouncementTask: Task<Void, Never>?
    var dshStatusTask: Task<Void, Never>?
    var dshStatusBegins: [String: Date] = [:]
    var aiObservation: AIMonitorObservation?
    weak var draggedMenuPet: RoamPanelController?
    let roamPanel: RoamPanelController
    var informationWindow: NSWindow?
    var informationWindowTask: Task<Void, Never>?
    let dashboard: DashboardWindowController
    let metricsSampler: SystemMetricsSampler
    let eventHub = EventHub()
    let eventStateStore: EventStateStore
    let notificationService = UserNotificationService()
    let launchAtLoginService = LaunchAtLoginService()
    var eventServer: LocalEventServer?
    var eventServerStatus = "未启动"
    let reducer = PetInteractionReducer()
    var state = PetState()
    var hideTask: DispatchWorkItem?

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
        AIMonitorStore.shared.onQuotaRecovered = { [weak self] line in
            guard let self, !self.quietMode else { return }
            self.menuBar.showQuotaRecovery(line)
        }
        roamPanel.interactionDelegate = self
        roamPanel.onClose = { [weak self] in self?.dispatch(.dismissRequested) }
        roamPanel.onSelectSkin = { [weak self] in self?.menuBarDidSelectSkin($0) }
        dashboard.dashboardDelegate = self
        dashboard.onRefresh = { [weak self] in self?.refreshDashboard() }
        connectAgentModule()
    }

}
