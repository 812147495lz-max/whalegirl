import AppKit
import WhaleCore
import os

@MainActor
extension AppCoordinator {
    func dispatch(_ interaction: PetInteraction) {
        let effects = reducer.reduce(state: &state, interaction: interaction)
        for effect in effects { apply(effect) }
    }

    func apply(_ effect: PetEffect) {
        switch effect {
        case .showPeek:
            roamPanel.hide()
            menuBar.showPeek()
            scheduleAutoHide()

        case .showFull:
            hideTask?.cancel()
            let point = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
            guard let screen else { return }
            menuBar.hidePeek(animated: false)
            roamPanel.show(centeredAt: point, screen: screen, scale: displayScale, clipID: "full.dragged")

        case .hideOverlays:
            hideTask?.cancel()
            menuBar.hidePeek()
            roamPanel.hide()

        case .returnToMenuBar:
            roamPanel.play("full.return", looping: false) { [weak self] in
                guard let self else { return }
                self.roamPanel.hide()
                self.dispatch(.returnFinished)
            }

        case let .play(id):
            activePanel?.play(id, looping: nil, completion: nil)

        case let .say(line):
            activePanel?.say(line)
        }
    }

    var activePanel: OverlayPanelController? {
        if roamPanel.isVisible { return roamPanel }
        return nil
    }

    func scheduleAutoHide() {
        guard !ProcessInfo.processInfo.arguments.contains("--demo-hold") else { return }
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.dispatch(.idleTimedOut) }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    @objc func workspaceWillSleep() {
        hideTask?.cancel()
        roamPanel.pauseAnimation()
        desktopPets.forEach { $0.pauseAnimation() }
    }

    @objc func workspaceDidWake() {
        activePanel?.resumeAnimation()
        desktopPets.forEach { $0.resumeAnimation() }
        if state.mode == .peeking { scheduleAutoHide() }
    }
}

@MainActor
extension AppCoordinator: PetViewInteractionDelegate {
    func petViewDidPetHead(_ view: PetView) {
        if let pet = desktopPet(for: view) { pet.play("full.happy", looping: false); return }
        scheduleAutoHide()
        dispatch(.headPetted)
    }

    func petViewDidPokeFace(_ view: PetView) {
        if let pet = desktopPet(for: view) { pet.play("full.poke", looping: false); return }
        scheduleAutoHide()
        dispatch(.facePoked)
    }

    func petViewDidRequestFull(_ view: PetView) {
        hideTask?.cancel()
        if state.mode != .peeking { dispatch(.statusTapped) }
        dispatch(.draggedDown(distance: 100))
    }

    func petViewDidRequestReturn(_ view: PetView) {
        if let pet = desktopPet(for: view) { closeDesktopPet(pet); return }
        if state.mode == .interacting { dispatch(.dragEnded) }
    }

    func petViewDidRequestDismiss(_ view: PetView) {
        if let pet = desktopPet(for: view) { closeDesktopPet(pet); return }
        hideTask?.cancel()
        dispatch(.dismissRequested)
    }

    func petView(_ view: PetView, didDragTo screenPoint: CGPoint, downwardDistance: Double) {
        if let pet = desktopPet(for: view) { pet.move(centeredAt: screenPoint); return }
        if state.mode == .peeking {
            dispatch(.draggedDown(distance: downwardDistance))
        } else if state.mode == .interacting {
            roamPanel.move(centeredAt: screenPoint)
        }
    }

    func petViewDidEndDrag(_ view: PetView) {
        // Desktop characters stay where released. Return is an explicit control.
        if desktopPet(for: view) != nil || roamPanel.petView === view { return }
        dispatch(.dragEnded)
    }
}
