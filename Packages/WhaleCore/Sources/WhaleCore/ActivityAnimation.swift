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
