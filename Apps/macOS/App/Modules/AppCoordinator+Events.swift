import AppKit
import WhaleCore
import os

@MainActor
extension AppCoordinator {
    func startEventServer() {
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

    func receiveEventFrame(_ frame: Data) async {
        do {
            let event = try WhaleEventCodec.decode(frame)
            let result = await eventHub.ingest(event)
            if result.disposition == .accepted {
                AIMonitorStore.shared.recordActivity(event)
                if let name = replyCompletions.ingest(event), !quietMode {
                    let id = UUID()
                    completionTasks[id] = Task { [weak self] in
                        let quota = await AIMonitorStore.shared.quotaForCompletion(event)
                        guard let self else { return }
                        defer { self.completionTasks.removeValue(forKey: id) }
                        guard !Task.isCancelled, !self.quietMode else { return }
                        self.menuBar.showReplyCompletion(sourceName: name, quotaSummary: quota)
                    }
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

    func recordEventFailure() async {
        await eventHub.recordDecodeFailure()
        persistEventState()
        refreshDashboard()
    }

    func persistEventState() {
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
