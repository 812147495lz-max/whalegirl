import Foundation

public enum NotificationPolicy {
    /// Routine completion uses the root peek or the child's own lifecycle, never Notification Center.
    public static func shouldDeliverSystemNotification(for event: WhaleEvent) -> Bool {
        guard !["agent.turn_completed", "agent.session_completed"].contains(event.eventType) else { return false }
        return priority(for: event) >= 75
    }

    public static func priority(for event: WhaleEvent) -> Int {
        switch event.eventType {
        case "agent.waiting_input", "agent.waiting_approval": 100
        case "agent.failed": 90
        case "agent.turn_completed", "agent.session_completed": 75
        case "mail.new": event.severity == .warning || event.severity == .action_required ? 65 : 40
        case "agent.session_started", "agent.working", "agent.tool_started", "agent.tool_finished": 20
        default: 0
        }
    }
}
