import AppKit
import WhaleCore
import os

@MainActor
extension AppCoordinator {
    @discardableResult
    func spawnDesktopPet(at point: CGPoint, agentManaged: Bool = false, dshBalanceCompanion: Bool = false) -> RoamPanelController? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return nil }
        var autonomy = PetView.AutonomyConfiguration()
        if agentManaged { autonomy.agentBirthDelay = 2 }
        autonomy.dshBalanceCompanion = dshBalanceCompanion
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

    func desktopPet(for view: PetView) -> RoamPanelController? {
        desktopPets.first { $0.petView === view }
    }

    func closeDesktopPet(_ pet: RoamPanelController) {
        for key in agentBoundPets.filter({ $0.value === pet }).map(\.key) {
            agentCompanions.dismiss(key); agentBoundPets.removeValue(forKey: key)
        }
        pet.hide()
        desktopPets.removeAll { $0 === pet }
    }

    func closeAllDesktopPets() {
        // Explicit close is immediate, even if a farewell is currently awaiting its final frame.
        agentBoundPets.removeAll()
        agentCompanions.closeAll()
        desktopPets.forEach { $0.hide() }
        desktopPets.removeAll()
        draggedMenuPet = nil
        roamPanel.hide()
    }
}
