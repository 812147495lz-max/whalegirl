import AppKit
import WhaleCore
import os

@MainActor
extension AppCoordinator {
    func start() {
        AIMonitorStore.shared.start()
        UsageReportStore.shared.onNewRecord = { [weak self] record in
            self?.enqueueUsageAnnouncement(record)
        }
        UsageReportStore.shared.start()
        menuBar.install(scale: userScale)
        SoftwareUpdateController.shared.start()
        if ProcessInfo.processInfo.arguments.contains("--show-software-update") {
            SoftwareUpdateController.shared.showAndCheck()
        }
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
        } else if ProcessInfo.processInfo.arguments.contains("--show-information-window") {
            showInformationWindow()
        } else if ProcessInfo.processInfo.arguments.contains("--show-metric-settings") {
            SystemMetricSettingsWindow.show()
        } else if ProcessInfo.processInfo.arguments.contains("--show-information") || ProcessInfo.processInfo.arguments.contains("--show-network-options") {
            menuBar.showComputerInformation()
        } else if ProcessInfo.processInfo.arguments.contains("--show-network-diagnostics") {
            NetworkDiagnosticsWindow.show()
        } else if ProcessInfo.processInfo.arguments.contains("--show-usage-report") {
            UsageReportStore.shared.showReport()
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
        SoftwareUpdateController.shared.stop()
        usageAnnouncementTask?.cancel(); usageAnnouncementTask = nil
        usageAnnouncements.removeAll()
        UsageReportStore.shared.onNewRecord = nil
        UsageReportStore.shared.stop()
        NetworkDiagnosticsWindow.stop()
        NetworkAddressStore.shared.stop()
        informationWindowTask?.cancel(); informationWindowTask = nil; informationWindow?.close()
        completionTasks.values.forEach { $0.cancel() }; completionTasks.removeAll()
        dshStatusTask?.cancel(); dshStatusTask = nil; dshStatusBegins.removeAll()
        AIMonitorStore.shared.setDSHCompanionActive(false)
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
}
