import Foundation
import UserNotifications
import WhaleCore

@MainActor
final class UserNotificationService {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func deliver(_ result: EventIngestResult) async {
        guard NotificationPolicy.shouldDeliverSystemNotification(for: result.event) else { return }
        let content = UNMutableNotificationContent()
        content.title = title(for: result.event)
        content.body = result.event.summary ?? fallbackBody(for: result.event)
        content.sound = .default
        let request = UNNotificationRequest(identifier: result.event.id, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            // Delivery failures are reflected by macOS notification settings; Agent work must continue.
        }
    }

    private func title(for event: WhaleEvent) -> String {
        switch event.eventType {
        case "agent.waiting_approval": "WhaleGirl · 等待授权"
        case "agent.waiting_input": "WhaleGirl · 等待输入"
        case "agent.failed": "WhaleGirl · Agent 失败"
        case "agent.turn_completed": "WhaleGirl · 完成一轮回复"
        case "agent.session_completed": "WhaleGirl · 会话完成"
        default: "WhaleGirl"
        }
    }

    private func fallbackBody(for event: WhaleEvent) -> String {
        let source = event.source.rawValue.uppercased()
        let project = event.projectKey ?? "未命名项目"
        return "\(source) · \(project)"
    }
}
