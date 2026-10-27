import AppKit
import QuartzCore
import WhaleCore

@MainActor
extension MenuBarController {
    func showHeartAboveStatusItem() {
        let startPoint = NSEvent.mouseLocation
        let heartSize: CGFloat = 12
        let panelSize = CGSize(width: 34, height: 42)
        let startY: CGFloat = 8
        let heartFrame = CGRect(
            x: startPoint.x - panelSize.width / 2,
            y: startPoint.y - startY - heartSize / 2,
            width: panelSize.width,
            height: panelSize.height
        )
        let (panel, imageView) = makeHeartPanel(size: panelSize, heartSize: heartSize)
        let effect = HeartEffect(panel: panel, imageView: imageView)
        heartEffects.append(effect)
        panel.setFrame(heartFrame, display: true)
        panel.alphaValue = 1
        let endY: CGFloat = 30
        let centerX = (panelSize.width - heartSize) / 2
        let startFrame = CGRect(x: centerX, y: startY,
                                width: heartSize, height: heartSize)
        let popFrame = CGRect(x: (panelSize.width - heartSize * 1.08) / 2,
                              y: startY - heartSize * 0.04,
                              width: heartSize * 1.08,
                              height: heartSize * 1.08)
        let smallFrame = CGRect(x: (panelSize.width - heartSize * 0.88) / 2,
                                y: startY + heartSize * 0.06,
                                width: heartSize * 0.88,
                                height: heartSize * 0.88)
        imageView.frame = smallFrame
        imageView.alphaValue = 0
        panel.orderFrontRegardless()

        // A quick, soft pop establishes the reaction before the slow upward drift.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            imageView.animator().frame = popFrame
            imageView.animator().alphaValue = 1
        }

        let riseDelay: CFTimeInterval = 0.26
        let riseDuration: CFTimeInterval = 1.64
        let fadeDelay: CFTimeInterval = 1.13
        let fadeDuration: CFTimeInterval = 0.77
        let duration = riseDelay + riseDuration
        let swayAmplitude: CGFloat = 22.0

        let riseTask = DispatchWorkItem { [weak effect] in
            guard let effect else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                effect.imageView.animator().frame = startFrame
            } completionHandler: {
                Task { @MainActor in
                    let sway = CAKeyframeAnimation(keyPath: "position.x")
                    sway.values = [0, swayAmplitude, 0, -swayAmplitude, 0,
                                   swayAmplitude, 0, -swayAmplitude, 0]
                    sway.keyTimes = [0, 0.125, 0.25, 0.375, 0.5,
                                     0.625, 0.75, 0.875, 1]
                    sway.calculationMode = .cubic
                    sway.duration = riseDuration
                    sway.isAdditive = true
                    effect.imageView.layer?.add(sway, forKey: "heart-sway")

                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = riseDuration
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        effect.imageView.animator().frame = CGRect(
                            x: (panelSize.width - heartSize * 0.95) / 2,
                            y: endY,
                            width: heartSize * 0.95,
                            height: heartSize * 0.95
                        )
                    }
                    effect.riseTask = nil
                }
            }
        }
        effect.riseTask = riseTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: riseTask)

        // Keep the heart legible through most of the rise, then fade it away.
        let fadeTask = DispatchWorkItem { [weak effect] in
            guard let effect else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                effect.imageView.animator().alphaValue = 0
            }
            effect.fadeTask = nil
        }
        effect.fadeTask = fadeTask
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDelay, execute: fadeTask)

        let task = DispatchWorkItem { [weak self] in
            effect.panel.orderOut(nil)
            effect.riseTask?.cancel()
            effect.riseTask = nil
            effect.hideTask = nil
            effect.fadeTask?.cancel()
            effect.fadeTask = nil
            self?.heartEffects.removeAll { $0 === effect }
        }
        effect.hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }

    func makeHeartPanel(size: CGSize, heartSize: CGFloat) -> (NSPanel, NSView) {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenPrimary, .stationary]

        let imageView = NSView(frame: CGRect(
            x: (size.width - heartSize) / 2,
            y: 0,
            width: heartSize,
            height: heartSize
        ))
        imageView.wantsLayer = true
        let symbol = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "爱心")
        let outlineView = NSImageView(frame: imageView.bounds.insetBy(dx: 0.15, dy: 0.15))
        outlineView.image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        )
        outlineView.contentTintColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        outlineView.imageScaling = .scaleProportionallyUpOrDown
        let fillView = NSImageView(frame: imageView.bounds.insetBy(dx: 1.15, dy: 1.15))
        fillView.image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        )
        fillView.contentTintColor = .systemRed
        fillView.imageScaling = .scaleProportionallyUpOrDown
        imageView.addSubview(outlineView)
        imageView.addSubview(fillView)
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.addSubview(imageView)
        panel.contentView = container

        return (panel, imageView)
    }
}
