import AppKit
import QuartzCore
import WhaleCore

@MainActor
final class SpriteAnimator {
    var onFrameDisplayed: ((SpriteAlphaMask) -> Void)?
    var shouldAnimate: (() -> Bool)?
    private let layer: CALayer
    private let repository: SpriteRepository
    private var nextFrameAt: CFTimeInterval?
    private var pausedRemaining: Double = 0
    var displayedClipID: String? { clip?.id }
    private var clip: SpriteManifest.Clip?
    private var frameIndex = 0
    private var completion: (() -> Void)?
    private var loadingTask: Task<Void, Never>?
    private var isPaused = false
    private var isHoldingPose = false
    private var currentAtlas: SpriteRepository.DecodedAtlas?

    init(layer: CALayer, repository: SpriteRepository) {
        self.layer = layer
        self.repository = repository
        // contentsRect selects one frame from the horizontal atlas. Using resizeAspect here
        // would preserve the aspect ratio of the whole atlas instead of the selected frame.
        layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .trilinear
    }

    func play(_ clipID: String, looping overrideLooping: Bool? = nil, holdingPose: Bool = false,
              completion: (() -> Void)? = nil) {
        stop()
        isPaused = false
        isHoldingPose = holdingPose
        guard var next = repository.clip(clipID) else { return }
        if let overrideLooping {
            next = SpriteManifest.Clip(id: next.id, atlasID: next.atlasID, looping: overrideLooping, frames: next.frames)
        }
        if next.atlasID.hasPrefix("community."), repository.cgImage(atlasID: next.atlasID) == nil {
            let requestedClip = next
            loadingTask = Task { [weak self] in
                guard let self else { return }
                let prepared = await self.repository.prepareClip(requestedClip.id)
                guard !Task.isCancelled, prepared else { return }
                self.begin(requestedClip, completion: completion)
            }
            return
        }
        begin(next, completion: completion)
    }

    private func begin(_ next: SpriteManifest.Clip, completion: (() -> Void)?) {
        guard let atlas = repository.decodedAtlas(atlasID: next.atlasID) else { return }
        currentAtlas = atlas
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = atlas.image
        CATransaction.commit()
        clip = next
        self.completion = completion
        frameIndex = 0
        displayCurrentFrame()
        if !isPaused, !isHoldingPose { scheduleNextFrame() }
    }

    func pause() {
        isPaused = true
        pausedRemaining = max(0, (nextFrameAt ?? CACurrentMediaTime()) - CACurrentMediaTime())
        nextFrameAt = nil
        SpritePlaybackClock.shared.remove(self)
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        guard clip != nil, !isHoldingPose else { return }
        nextFrameAt = CACurrentMediaTime() + max(0.001, pausedRemaining)
        SpritePlaybackClock.shared.add(self)
    }

    func stop() {
        loadingTask?.cancel()
        loadingTask = nil
        nextFrameAt = nil
        SpritePlaybackClock.shared.remove(self)
        clip = nil
        // Keep the displayed bitmap shared until the replacement texture arrives.
        completion = nil
    }

    private func scheduleNextFrame() {
        guard let clip, !clip.frames.isEmpty else { return }
        nextFrameAt = CACurrentMediaTime() + clip.frames[frameIndex].duration
        SpritePlaybackClock.shared.add(self)
    }

    fileprivate func advanceFrame(at now: CFTimeInterval) {
        guard !isPaused, let clip, var deadline = nextFrameAt, now >= deadline else { return }
        if shouldAnimate?() == false {
            // Keep the same pose while its screen is showing another app fullscreen.
            nextFrameAt = now + clip.frames[frameIndex].duration
            return
        }
        var advanced = 0
        // Catch up to elapsed time, but never draw intermediate missed frames.
        while now >= deadline && advanced < 8 {
            if frameIndex + 1 < clip.frames.count { frameIndex += 1 }
            else if clip.looping { frameIndex = 0 }
            else {
                nextFrameAt = nil
                isHoldingPose = true
                SpritePlaybackClock.shared.remove(self)
                // A late tick can reach the end before drawing the final pose.
                displayCurrentFrame()
                let callback = completion
                completion = nil
                callback?()
                return
            }
            deadline += clip.frames[frameIndex].duration
            advanced += 1
        }
        nextFrameAt = deadline > now ? deadline : now + clip.frames[frameIndex].duration
        displayCurrentFrame()
    }

    private func displayCurrentFrame() {
        guard let clip, let atlas = repository.atlas(clip.atlasID),
              let currentAtlas else { return }
        let frame = clip.frames[frameIndex]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsRect = CGRect(
            x: frame.rect.x / Double(atlas.pixelWidth),
            // The manifest uses image-space top-left coordinates; CALayer uses bottom-left.
            y: 1 - ((frame.rect.y + frame.rect.height) / Double(atlas.pixelHeight)),
            width: frame.rect.width / Double(atlas.pixelWidth),
            height: frame.rect.height / Double(atlas.pixelHeight)
        )
        CATransaction.commit()
        onFrameDisplayed?(currentAtlas.mask(for: CGRect(x: frame.rect.x, y: frame.rect.y, width: frame.rect.width, height: frame.rect.height)))
    }
}

/// One bounded main-run-loop timer for all sprite players, independent of pet count.
@MainActor
private final class SpritePlaybackClock {
    static let shared = SpritePlaybackClock()
    private final class WeakPlayer {
        weak var value: SpriteAnimator?
        init(_ value: SpriteAnimator) { self.value = value }
    }
    private var players: [ObjectIdentifier: WeakPlayer] = [:]
    private var timer: Timer?

    func add(_ player: SpriteAnimator) {
        players[ObjectIdentifier(player)] = WeakPlayer(player)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.003
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func remove(_ player: SpriteAnimator) {
        players[ObjectIdentifier(player)] = nil
        stopIfEmpty()
    }

    private func tick() {
        players = players.filter { $0.value.value != nil }
        let now = CACurrentMediaTime()
        for player in players.values.compactMap(\.value) { player.advanceFrame(at: now) }
        stopIfEmpty()
    }

    private func stopIfEmpty() {
        guard players.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }
}
