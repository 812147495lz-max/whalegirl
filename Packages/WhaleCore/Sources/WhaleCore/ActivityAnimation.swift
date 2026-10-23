import Foundation

/// Timing and frame order for the menu bar animation, kept platform-independent for tests.
public enum ActivityAnimation {
    public static func pingPongSequence(frameCount: Int) -> [Int] {
        guard frameCount > 0 else { return [] }
        guard frameCount > 2 else { return Array(0..<frameCount) }
        return Array(0..<frameCount) + Array((1..<(frameCount - 1)).reversed())
    }

    /// Linearly maps CPU load through the requested 15 FPS at 25% and 45 FPS at 99% anchors.
    /// Loads below 25% continue the same slope; the top end is capped at the 99% anchor.
    public static func framesPerSecond(cpuPercent: Double?) -> Double {
        let cpu = cpuPercent.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let clampedCPU = min(99, max(0, cpu))
        return 15 + (clampedCPU - 25) * (30.0 / 74.0)
    }

    /// Duration for one displayed image, including synthesized in-between frames.
    public static func frameInterval(cpuPercent: Double?) -> TimeInterval {
        1.0 / framesPerSecond(cpuPercent: cpuPercent)
    }
}

/// Monotonic animation phase. Timer/rendering delays skip overdue images rather than slowing the motion.
public struct ActivityAnimationClock: Sendable {
    private let sequenceLength: Int
    private var position: Double = 0
    private var timestamp: TimeInterval
    private var cpuTimestamp: TimeInterval?
    public private(set) var smoothedCPUPercent: Double?
    public private(set) var framesPerSecond = ActivityAnimation.framesPerSecond(cpuPercent: nil)
    public var frameIndex: Int { Int(position.rounded(.down)) }

    public init(sequenceLength: Int, at timestamp: TimeInterval) {
        self.sequenceLength = max(1, sequenceLength)
        self.timestamp = timestamp.isFinite ? timestamp : 0
    }
    @discardableResult
    public mutating func advance(to now: TimeInterval) -> Int {
        guard now.isFinite, now >= timestamp else { return frameIndex }
        let distance = (now - timestamp) * framesPerSecond
        if distance.isFinite { position = (position + distance).truncatingRemainder(dividingBy: Double(sequenceLength)) }
        timestamp = now
        return frameIndex
    }
    public mutating func updateCPU(_ percent: Double?, at now: TimeInterval) {
        guard now.isFinite, now >= timestamp else { return }
        advance(to: now) // Finish the old rate before changing speed; never restart the frame phase.
        guard let percent, percent.isFinite else { return }
        let value = min(100, max(0, percent))
        if let previous = smoothedCPUPercent, let last = cpuTimestamp {
            let weight = 1 - exp(-max(0, now - last) / 0.65)
            smoothedCPUPercent = previous + (value - previous) * weight
        } else { smoothedCPUPercent = value }
        cpuTimestamp = now
        framesPerSecond = ActivityAnimation.framesPerSecond(cpuPercent: smoothedCPUPercent)
    }
    public mutating func delayUntilNextFrame(at now: TimeInterval) -> TimeInterval {
        advance(to: now)
        return max(0.001, (position.rounded(.down) + 1 - position) / framesPerSecond)
    }
}
