import AppKit
import QuartzCore
import WhaleCore

@MainActor
extension MenuBarController {
    func displayMenuBarImage(_ image: NSImage) {
        guard let button = statusItem?.button else { return }
        if animationImageView?.isHidden == false {
            animationImageView?.image = image
            button.image = nil
        } else {
            button.image = image
        }
    }

    func loadActivityFrames() {
        guard let resourceURL = Bundle.main.resourceURL else { return }
        frameLoadingTask = Task { [weak self] in
            // Make the head available before the independent tail-frame interpolation finishes.
            let hover = await Task.detached(priority: .userInitiated) {
                MenuBarFramePipeline.prepareHoverFrames(resourceURL: resourceURL)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.hoverFrames = Dictionary(uniqueKeysWithValues: HoverAnimation.allCases.map {
                ($0, hover[$0.rawValue] ?? [])
            })
            self.refreshScaledHoverFrames()
            if self.shouldKeepPeekVisible { self.showHoverIfNeeded() }
            let prepared = await Task.detached(priority: .utility) {
                MenuBarFramePipeline.prepareMenuBarFrames(resourceURL: resourceURL)
            }.value
            guard !Task.isCancelled else { return }
            self.activityFrames = prepared.activity
            self.frameSequence = ActivityAnimation.pingPongSequence(frameCount: self.activityFrames.count)
            self.refreshScaledActivityFrames()
            self.startActivityAnimation()
        }
    }

    func showInitialActivityFrame() {
        let directory = Bundle.main.resourceURL?.appendingPathComponent("MenuBarFrames", isDirectory: true)
        guard let url = directory?.appendingPathComponent("png_1.png"),
              let image = NSImage(contentsOf: url),
              let fitted = MenuBarFramePipeline.fittedActivityFrames([image]).first else { return }
        displayMenuBarImage(fitted)
    }

    func refreshScaledActivityFrames() {
        scaledActivityFrames = activityFrames.map(scaledImage)
        if let frameWidth = scaledActivityFrames.first?.size.width {
            statusItem?.length = max(28, frameWidth)
        }
        refreshScaledHoverFrames()
    }

    func refreshScaledHoverFrames() {
        scaledHoverFrames = hoverFrames.mapValues { $0.map(scaledImage) }
    }

    func scaledImage(_ image: NSImage) -> NSImage {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return image }
        let scale = currentScale * 1.3
        return NSImage(cgImage: cgImage, size: NSSize(width: image.size.width * scale, height: image.size.height * scale))
    }

    func startActivityAnimation() {
        animationTimer?.invalidate(); metricsTimer?.invalidate()
        let now = ProcessInfo.processInfo.systemUptime
        activityClock = ActivityAnimationClock(sequenceLength: frameSequence.count, at: now)
        sequencePosition = 0
        showCurrentActivityFrame()
        if ProcessInfo.processInfo.arguments.contains("--trace-menu-animation") {
            activityTraceStart = now; activityTraceFrames = 0; activityTraceSamples = 0
        }
        _ = metricsSampler.sampleCPUUsage() // Establish the first CPU tick baseline.
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(sampleActivity), userInfo: nil, repeats: true)
        metricsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        scheduleNextFrame()
    }

    @objc func sampleActivity() {
        let snapshot = metricsSampler.sample()
        SystemMetricsHistory.shared.record(snapshot, at: Date())
        let now = ProcessInfo.processInfo.systemUptime
        if let start = activityTraceStart, now > start {
            let line = String(format: "menu-animation target=%.2f submitted=%.2f interval=%.3f\n", activityClock?.framesPerSecond ?? 0, Double(activityTraceFrames) / (now - start), now - start)
            try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
            activityTraceSamples += 1; activityTraceFrames = 0
            activityTraceStart = activityTraceSamples < 8 ? now : nil
        }
        activityClock?.updateCPU(snapshot.cpuPercent, at: now)
        advanceActivityFrame()
    }

    func scheduleNextFrame() {
        guard !frameSequence.isEmpty, activityClock != nil else { return }
        animationTimer?.invalidate()
        // Compensate for time already spent drawing. Late callbacks advance to the
        // real current phase instead of adding their own delay to every future frame.
        let interval = activityClock!.delayUntilNextFrame(at: ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(advanceActivityFrame), userInfo: nil, repeats: false)
        timer.tolerance = min(0.001, interval * 0.03)
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func advanceActivityFrame() {
        guard !frameSequence.isEmpty, let position = activityClock?.advance(to: ProcessInfo.processInfo.systemUptime) else { return }
        if sequencePosition != position {
            sequencePosition = position
            showCurrentActivityFrame()
        }
        scheduleNextFrame()
    }

    func showCurrentActivityFrame() {
        guard let button = statusItem?.button else { return }
        if frameSequence.indices.contains(sequencePosition) {
            let image = scaledActivityFrames[frameSequence[sequencePosition]]
            displayMenuBarImage(image)
            if activityTraceStart != nil { activityTraceFrames += 1 }
        } else {
            let image = repository.firstFrameImage(clipID: "mini.idle", targetSize: NSSize(width: 24, height: 24))
            animationImageView?.image = image
            button.image = image
        }
    }
}
