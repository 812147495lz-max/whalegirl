import AppKit
import WhaleCore

@MainActor
extension AppCoordinator {
    func startMessageAPI() {
        MessageInboxController.shared.start(isQuiet: { [weak self] in self?.quietMode ?? true }) { [weak self] item, settings in
            guard let self else { return .cancelled }
            return await self.menuBar.presentIncomingMessage(item, settings: settings)
        }
    }
}
