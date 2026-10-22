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
}
