import AppKit
import WhaleCore

@MainActor
extension MenuBarController {
    func presentIncomingMessage(_ message: IncomingMessage, settings: MessageAPISettings) async -> MessageDelivery {
        guard statusItem != nil, !informationController.isActive, !isCompletionPeekActive,
              !incomingMessageActive, !isHoverCoolingDown,
              let screen = self.screen ?? NSScreen.main, !peekSuppression(screen),
              !(scaledHoverFrames[.appear]?.isEmpty ?? true) else { return .deferred }
        incomingMessageActive = true
        defer {
            incomingBubble.finish(.cancelled)
            incomingMessageActive = false
            if statusItem != nil, !informationController.isActive {
                if isCompletionPeekActive { presentHoverSpeech(completionLine) }
                else if shouldKeepPeekVisible { scheduleWink() }
                else if hoverAnimation != nil { beginHoverAnimation(.disappear) }
            }
        }
        suppressHoverUntilExit = false
        if hoverAnimation == nil || hoverAnimation == .disappear { beginHoverAnimation(.appear) }
        pendingHoverSpeechLine = nil; hoverCharacterPanel.dismissSpeechBubble()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while hoverPlaybackTimer != nil, hoverAnimation == .appear {
            guard !Task.isCancelled, ContinuousClock.now < deadline, !informationController.isActive else { return .cancelled }
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return .cancelled }
        }
        guard !Task.isCancelled, !informationController.isActive, !peekSuppression(screen),
              let anchor = hoverCharacterPanel.handoffPose()?.frame else { return .deferred }
        let conversation = message.submission.conversationID ?? "default"
        return await incomingBubble.present(message, settings: settings, anchor: anchor, visibleFrame: screen.visibleFrame, onReply: { text in
            do {
                try MessageInboxController.shared.conversations.send(text: text, conversationID: conversation, replyTo: message.id)
                return true
            } catch { return false }
        }, onOpenConversation: {
            MessageInboxController.shared.showConversations(id: conversation)
        }, onStarted: {
            MessageInboxController.shared.beganPlaying(message)
        })
    }
}
