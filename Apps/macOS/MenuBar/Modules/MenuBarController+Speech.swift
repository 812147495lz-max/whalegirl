import AppKit
import QuartzCore
import WhaleCore

@MainActor
extension MenuBarController {
    func showQuotaRecovery(_ line: String) { showNetworkTestResult(line) }

    func showNetworkTestResult(_ line: String) {
        guard let screen = self.screen, !peekSuppression(screen) else { return }
        if informationController.state == .showing { informationController.showNetworkResult(line); return }
        guard !informationController.isActive else { return }
        networkCompletionLine = line
        suppressHoverUntilExit = false
        if hoverAnimation == nil || hoverAnimation == .disappear { showHoverIfNeeded() }
        else if hoverAnimation == .appear && hoverPlaybackTimer != nil { pendingHoverSpeechLine = line }
        else { pendingHoverSpeechLine = nil; presentHoverSpeech(line) }
    }

    func showReplyCompletion(sourceName: String, quotaSummary: String? = nil) {
        guard statusItem != nil, let screen = self.screen ?? NSScreen.main ?? NSScreen.screens.first,
              !peekSuppression(screen) else { return }
        networkCompletionLine = nil
        let name = String(sourceName.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let quotaSummary { completionQuotas[name] = quotaSummary }
        if !completionNames.contains(name) {
            if completionNames.count >= 10 { completionNames.removeFirst() }
            completionNames.append(name)
        }
        // Defer while the user is reading the rope information panel; never overlay two characters.
        guard !informationController.isActive else { return }
        suppressHoverUntilExit = false
        if hoverAnimation == nil || hoverAnimation == .disappear {
            showHoverIfNeeded()
        } else if hoverAnimation == .appear && hoverPlaybackTimer != nil {
            pendingHoverSpeechLine = completionLine
        } else {
            pendingHoverSpeechLine = nil
            presentHoverSpeech(completionLine)
        }
    }

    func presentHoverSpeech(_ line: String) {
        hoverCharacterPanel.showSpeechBubble(line, autoDismiss: !isCompletionPeekActive)
        guard isCompletionPeekActive else { return }
        completionDismissal?.cancel()
        completionGeneration = UUID(); let generation = completionGeneration
        completionDismissal = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now.advanced(by: self.completionHoldDuration)
            while ContinuousClock.now < deadline {
                do { try await Task.sleep(for: min(.milliseconds(500), deadline - ContinuousClock.now)) } catch { return }
                guard self.completionGeneration == generation else { return }
                if let screen = self.screen, self.peekSuppression(screen) {
                    self.hidePeek(animated: false)
                    self.hoverCharacterPanel.shutdown()
                    return
                }
            }
            guard !Task.isCancelled, self.completionGeneration == generation else { return }
            self.cancelCompletionPeek()
            if !self.isPeekPinned {
                self.suppressHoverUntilExit = self.isPointerHovering
                self.winkTimer?.invalidate(); self.winkTimer = nil
                self.beginHoverAnimation(.disappear)
            } else {
                self.hoverCharacterPanel.dismissSpeechBubble()
            }
        }
    }

    func cancelCompletionPeek() {
        completionDismissal?.cancel(); completionDismissal = nil
        completionGeneration = UUID(); completionNames.removeAll(); completionQuotas.removeAll(); networkCompletionLine = nil
    }
}
