import XCTest
@testable import WhaleCore

final class ActivityAnimationTests: XCTestCase {
    func testEightFramesPlayForwardThenBackwardWithoutRepeatingEndpoints() {
        XCTAssertEqual(
            ActivityAnimation.pingPongSequence(frameCount: 8),
            [0, 1, 2, 3, 4, 5, 6, 7, 6, 5, 4, 3, 2, 1]
        )
    }

    func testRequestedCPUToFrameRateAnchors() {
        XCTAssertEqual(ActivityAnimation.framesPerSecond(cpuPercent: 25), 15, accuracy: 0.001)
        XCTAssertEqual(ActivityAnimation.framesPerSecond(cpuPercent: 99), 45, accuracy: 0.001)
        XCTAssertEqual(ActivityAnimation.frameInterval(cpuPercent: 25), 1.0 / 15.0, accuracy: 0.001)
        XCTAssertEqual(ActivityAnimation.frameInterval(cpuPercent: 99), 1.0 / 45.0, accuracy: 0.001)
    }

    func testActivityIncreasesAnimationSpeedSmoothlyAndCapsAtTopAnchor() {
        XCTAssertLessThan(
            ActivityAnimation.frameInterval(cpuPercent: 80),
            ActivityAnimation.frameInterval(cpuPercent: 20)
        )
        XCTAssertEqual(ActivityAnimation.framesPerSecond(cpuPercent: 100), 45, accuracy: 0.001)
        XCTAssertEqual(ActivityAnimation.framesPerSecond(cpuPercent: 150), 45, accuracy: 0.001)
    }

    func testInvalidActivityUsesLowLoadAndValuesAreClamped() {
        XCTAssertEqual(ActivityAnimation.framesPerSecond(cpuPercent: nil), 15 - 25 * (30.0 / 74.0), accuracy: 0.001)
        XCTAssertEqual(ActivityAnimation.framesPerSecond(cpuPercent: .nan), 15 - 25 * (30.0 / 74.0), accuracy: 0.001)
        XCTAssertEqual(ActivityAnimation.framesPerSecond(cpuPercent: -10), 15 - 25 * (30.0 / 74.0), accuracy: 0.001)
    }
    func testClockUsesElapsedTimeAndSkipsLateFrames() {
        var clock = ActivityAnimationClock(sequenceLength: 76, at: 0)
        clock.updateCPU(25, at: 0)
        XCTAssertEqual(clock.advance(to: 0.35), 5)
        XCTAssertEqual(clock.delayUntilNextFrame(at: 0.35), 0.05, accuracy: 0.0001)
        XCTAssertEqual(clock.advance(to: 10), 74) // 150 elapsed frames, modulo76; no slow catch-up loop.
    }

    func testSamplingDoesNotRestartPartialFrame() {
        var clock = ActivityAnimationClock(sequenceLength: 76, at: 0)
        clock.updateCPU(25, at: 0)
        clock.updateCPU(25, at: 0.35)
        XCTAssertEqual(clock.frameIndex, 5)
        XCTAssertEqual(clock.delayUntilNextFrame(at: 0.35), 0.05, accuracy: 0.0001)
        XCTAssertEqual(clock.advance(to: 0.41), 6)
    }

    func testCPUChangeRespondsWithinTwoSamplesAndKeepsPhase() {
        var clock = ActivityAnimationClock(sequenceLength: 76, at: 0)
        clock.updateCPU(25, at: 0)
        clock.updateCPU(99, at: 1)
        XCTAssertEqual(clock.frameIndex, 15)
        XCTAssertGreaterThan(clock.framesPerSecond, 38)
        clock.updateCPU(99, at: 2)
        XCTAssertGreaterThan(clock.framesPerSecond, 43)
        var high = ActivityAnimationClock(sequenceLength: 76, at: 0)
        high.updateCPU(99, at: 0)
        XCTAssertEqual(high.framesPerSecond, 45, accuracy: 0.001)
    }

    func testMissingCPUAndBackwardsTimeDoNotResetMotion() {
        var clock = ActivityAnimationClock(sequenceLength: 76, at: 0)
        clock.updateCPU(99, at: 0)
        clock.updateCPU(nil, at: 1)
        XCTAssertEqual(clock.frameIndex, 45)
        XCTAssertEqual(clock.framesPerSecond, 45, accuracy: 0.001)
        XCTAssertEqual(clock.advance(to: 0.5), 45)
        XCTAssertEqual(clock.advance(to: .infinity), 45)
        clock.updateCPU(.nan, at: 1)
        XCTAssertEqual(clock.framesPerSecond, 45, accuracy: 0.001)
    }
}
