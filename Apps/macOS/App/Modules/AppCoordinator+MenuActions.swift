import AppKit
import WhaleCore
import os


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
