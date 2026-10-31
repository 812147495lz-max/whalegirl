import AppKit

@MainActor
extension MenuBarController {
    // Status-item hosts may forward clicks without forwarding mouseDragged.
    // Sample only the left-button state; a gesture can start only over our icon.
    @objc func pollIconPointer() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        guard down || wasIconLeftDown || iconDragStart != nil else { return }
        let point = NSEvent.mouseLocation
        let mayBegin = buttonFrameOnScreen?.contains(point) == true
            && !NSEvent.modifierFlags.contains(.command)
        sampleIconPointer(at: point, leftButtonDown: down, mayBegin: mayBegin)
    }

    func sampleIconPointer(at point: CGPoint, leftButtonDown down: Bool, mayBegin: Bool) {
        defer { wasIconLeftDown = down }
        if down {
            if !wasIconLeftDown, mayBegin, iconDragStart == nil {
                beginIconDrag(at: point)
            }
            if iconDragStart != nil { moveIconDrag(to: point) }
        } else if wasIconLeftDown, iconDragStart != nil {
            endIconDrag(at: point)
            if let click = pendingIconClick {
                pendingIconClick = nil
                handleStatusClick(click)
                suppressIconClickUntil = ProcessInfo.processInfo.systemUptime + 0.2
            }
        }
    }

    func trackIconDrag(_ event: NSEvent) {
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            guard !event.modifierFlags.contains(.command), iconDragStart == nil,
                  buttonFrameOnScreen?.contains(point) == true else { return }
            // Ignore a host's delayed click after a sampled drag has already ended.
            if didDragCharacter, NSEvent.pressedMouseButtons & 1 == 0 { return }
            beginIconDrag(at: point)
        case .leftMouseDragged:
            moveIconDrag(to: point)
        case .leftMouseUp:
            if NSEvent.pressedMouseButtons & 1 == 0 { endIconDrag(at: point) }
        default: break
        }
    }

    func beginIconDrag(at point: CGPoint) {
        didDragCharacter = false
        pendingIconClick = nil
        iconDragStart = point
    }

    func moveIconDrag(to point: CGPoint) {
        guard let start = iconDragStart, didDragCharacter || start.y - point.y >= 12 else { return }
        let isNew = !didDragCharacter
        didDragCharacter = true
        if isNew {
            if informationController.isActive { informationController.shutdown() }
            hidePeek(animated: false)
        }
        delegate?.menuBarDidDragCharacter(to: point, isNew: isNew)
    }

    func endIconDrag(at point: CGPoint) {
        guard iconDragStart != nil else { return }
        if didDragCharacter {
            delegate?.menuBarDidDragCharacter(to: point, isNew: false)
            delegate?.menuBarDidFinishDraggingCharacter()
        }
        iconDragStart = nil
    }

    func shouldHandleIconLeftClick(_ event: NSEvent) -> Bool {
        if iconDragStart != nil, NSEvent.pressedMouseButtons & 1 != 0 {
            pendingIconClick = event
            return false
        }
        return !didDragCharacter && ProcessInfo.processInfo.systemUptime >= suppressIconClickUntil
    }
}
