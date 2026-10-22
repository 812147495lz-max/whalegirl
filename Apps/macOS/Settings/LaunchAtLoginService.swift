import ServiceManagement

@MainActor
final class LaunchAtLoginService {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "已启用"
        case .requiresApproval: "需要在系统设置中批准"
        case .notFound: "当前构建无法注册"
        case .notRegistered: "未启用"
        @unknown default: "状态未知"
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
