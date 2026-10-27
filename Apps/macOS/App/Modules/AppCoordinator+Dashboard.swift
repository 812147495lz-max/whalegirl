import AppKit
import WhaleCore
import os

@MainActor
extension AppCoordinator {
    func showInformationWindow() {
        let height = min(SystemMetricPreferences.shared.panelBaseHeight + AIMonitorStore.shared.sectionHeight, (NSScreen.main?.visibleFrame.height ?? 900) - 80)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 264, height: max(280, height)), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "运行概览"; window.isReleasedWhenClosed = false
        let view = ComputerInformationView(frame: window.contentView?.bounds ?? .zero, aiStore: .shared)
        view.autoresizingMask = [.width, .height]; window.contentView = view
        informationWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        informationWindowTask = Task { [weak self, weak window, weak view] in
            while !Task.isCancelled, let self, let window, window.isVisible, let view {
                view.update(self.metricsSampler.sample())
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func showDashboard() {
        dashboard.show(quietMode: quietMode, notificationsEnabled: notificationsEnabled)
        Task {
            await eventHub.markAllRead()
            persistEventState()
            refreshDashboard()
        }
    }

    func refreshDashboard() {
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
