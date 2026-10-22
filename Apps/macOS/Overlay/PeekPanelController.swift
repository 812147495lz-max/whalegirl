import AppKit
import WhaleCore

@MainActor
final class PeekPanelController: OverlayPanelController {
    func show(anchor: CGRect, screen: NSScreen, scale: Double, clipID: String) {
        let height = DisplayGeometry.peekHeight(screenFrame: screen.frame, userScale: scale)
        let firstFrame = repository.clip("peek.idle")?.frames.first?.rect
        let aspect = firstFrame.map { $0.width / $0.height } ?? 1.16
        let size = CGSize(width: max(height * aspect, PetView.minimumDockWidth),
                          height: height + PetView.controlDockHeight)
        let frame = DisplayGeometry.frameBelowMenuBar(anchor: anchor, size: size, visibleFrame: screen.visibleFrame)
        show(frame: frame, clipID: clipID)
    }
}
