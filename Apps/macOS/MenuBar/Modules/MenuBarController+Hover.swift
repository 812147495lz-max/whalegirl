import AppKit
import QuartzCore
import WhaleCore

@MainActor
extension MenuBarController {
    // Explicit peek requests share the user's hanging animation with hover.
    // Never create a second, placeholder character window.
    func showPeek() {
        guard !informationController.isActive, !isHoverCoolingDown else { return }
        suppressHoverUntilExit = false
        isPeekPinned = true
        guard hoverAnimation == nil || hoverAnimation == .disappear else { return }
        guard !(scaledHoverFrames[.appear]?.isEmpty ?? true) else { return }
        beginHoverAnimation(.appear)
    }

    func hidePeek(animated: Bool = true, preserveCompletion: Bool = false) {
        if !preserveCompletion { incomingBubble.finish(.dismissed) }
        if !preserveCompletion { cancelCompletionPeek() }
        isPeekPinned = false
        winkTimer?.invalidate()
        winkTimer = nil
        guard hoverAnimation != nil else { return }
        if animated {
            beginHoverAnimation(.disappear)
        } else {
            hoverPlaybackTimer?.invalidate()
            hoverPlaybackTimer = nil
            hoverAnimation = nil
            pendingHoverSpeechLine = nil
            hoverCharacterPanel.dismissSpeechBubble()
            hoverCharacterPanel.hideCharacter()
        }
    }

    @objc func mouseEntered(with event: NSEvent) {
        statusItem?.button?.toolTip = nil
        guard !isPointerHovering else { return }
        isPointerHovering = true
        winkTimer?.invalidate()
        winkTimer = nil
        showHoverIfNeeded()
        if hoverPlaybackTimer == nil { scheduleWink() }
    }

    func startHoverCooldown() {
        hoverCooldownTask?.cancel()
        hoverCooldownUntil = ProcessInfo.processInfo.systemUptime + 1
        hoverCooldownTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.statusItem != nil else { return }
            self.hoverCooldownTask = nil
            if self.shouldKeepPeekVisible { self.showHoverIfNeeded() }
        }
    }

    func showHoverIfNeeded() {
        guard !informationController.isActive, !suppressHoverUntilExit, !isHoverCoolingDown,
              hoverAnimation == nil || hoverAnimation == .disappear,
              !(scaledHoverFrames[.appear]?.isEmpty ?? true) else { return }
        beginHoverAnimation(.appear)
    }

    @objc func mouseExited(with event: NSEvent) {
        statusItem?.button?.toolTip = informationController.isActive
            ? "WhaleGirl：右键收回信息，左键菜单" : "WhaleGirl：左键爱心，右键电脑信息；Option+右键菜单"
        guard isPointerHovering else { return }
        isPointerHovering = false
        suppressHoverUntilExit = false
        winkTimer?.invalidate()
        winkTimer = nil
        // A cooldown exit must not start disappearance from a full, hidden head.
        guard !informationController.isActive, !isHoverCoolingDown, hoverAnimation != nil else { return }
        if !shouldKeepPeekVisible {
            beginHoverAnimation(.disappear)
        } else if hoverPlaybackTimer == nil {
            scheduleWink()
        }
    }

    func beginHoverAnimation(_ kind: HoverAnimation) {
        hoverPlaybackTimer?.invalidate()
        hoverPlaybackTimer = nil
        hoverAnimation = kind
        hoverFramePosition = 0
        if kind == .disappear {
            pendingHoverSpeechLine = nil
            hoverCharacterPanel.dismissSpeechBubble()
        }
        guard let frames = scaledHoverFrames[kind], !frames.isEmpty else {
            finishHoverAnimation(kind)
            return
        }
        showHoverFrame(kind: kind, index: 0)
        if kind == .appear {
            let line = isCompletionPeekActive ? completionLine : DeepSeekChanDialog.randomLine(excluding: lastHoverSpeechLine)
            if !isCompletionPeekActive { lastHoverSpeechLine = line }
            pendingHoverSpeechLine = line
        }
        scheduleHoverFrame()
    }

    func scheduleHoverFrame() {
        hoverPlaybackTimer?.invalidate()
        let frameRate: Double = hoverAnimation == .wink ? 30 : 60
        let timer = Timer(timeInterval: 1.0 / frameRate,
                          target: self,
                          selector: #selector(advanceHoverFrame),
                          userInfo: nil,
                          repeats: false)
        hoverPlaybackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func advanceHoverFrame() {
        guard let kind = hoverAnimation,
              let frames = scaledHoverFrames[kind], !frames.isEmpty else { return }
        if hoverFramePosition + 1 < frames.count {
            hoverFramePosition += 1
            showHoverFrame(kind: kind, index: hoverFramePosition)
            if kind == .appear,
               let line = pendingHoverSpeechLine,
               hoverFramePosition >= Int(ceil(Double(frames.count - 1) * 2.0 / 3.0)) {
                pendingHoverSpeechLine = nil
                presentHoverSpeech(line)
            }
            scheduleHoverFrame()
        } else {
            finishHoverAnimation(kind)
        }
    }

    func finishHoverAnimation(_ kind: HoverAnimation) {
        hoverPlaybackTimer?.invalidate()
        hoverPlaybackTimer = nil
        switch kind {
        case .appear:
            if let line = pendingHoverSpeechLine {
                pendingHoverSpeechLine = nil
                presentHoverSpeech(line)
            }
            hoverAnimation = .appear
            hoverFramePosition = max(0, (scaledHoverFrames[.appear]?.count ?? 1) - 1)
            showHoverFrame(kind: .appear, index: hoverFramePosition)
            scheduleWink()
        case .wink:
            guard shouldKeepPeekVisible else {
                beginHoverAnimation(.disappear)
                return
            }
            hoverAnimation = .appear
            hoverFramePosition = max(0, (scaledHoverFrames[.appear]?.count ?? 1) - 1)
            showHoverFrame(kind: .appear, index: hoverFramePosition)
            scheduleWink()
        case .disappear:
            hoverAnimation = nil
            hoverFramePosition = 0
            hoverCharacterPanel.hideCharacter()
        }
    }

    func scheduleWink() {
        winkTimer?.invalidate()
        guard shouldKeepPeekVisible, hoverAnimation == .appear,
              !(scaledHoverFrames[.wink]?.isEmpty ?? true) else { return }
        let timer = Timer(timeInterval: Double.random(in: 2.0...3.0),
                          target: self,
                          selector: #selector(triggerWink),
                          userInfo: nil,
                          repeats: false)
        winkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func triggerWink() {
        winkTimer = nil
        guard shouldKeepPeekVisible, hoverAnimation == .appear else { return }
        beginHoverAnimation(.wink)
    }

    func showHoverFrame(kind: HoverAnimation, index: Int) {
        guard let frames = scaledHoverFrames[kind], frames.indices.contains(index) else { return }
        guard let anchor = buttonFrameOnScreen,
              let screen = self.screen ?? NSScreen.main else { return }
        hoverCharacterPanel.show(image: frames[index],
                                 anchor: anchor,
                                 screen: screen,
                                 scale: currentScale * 1.3)
    }
}
