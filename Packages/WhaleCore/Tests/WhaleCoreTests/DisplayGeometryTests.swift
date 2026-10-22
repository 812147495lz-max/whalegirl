import CoreGraphics
import Testing
@testable import WhaleCore

struct DisplayGeometryTests {
    @Test func usesRequiredDisplayRatios() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        #expect(abs(DisplayGeometry.peekHeight(screenFrame: screen, userScale: 1) - 78.392) < 0.001)
        #expect(abs(DisplayGeometry.fullHeight(screenFrame: screen, userScale: 1) - 143.4) < 0.001)
    }

    @Test func clampsScaleAndWindowToVisibleDisplay() {
        #expect(DisplayGeometry.clampedScale(0.1) == 0.8)
        #expect(DisplayGeometry.clampedScale(2.0) == 1.95)
        #expect(DisplayGeometry.clampedPreferenceScale(2.0) == 1.5)
        let visible = CGRect(x: 100, y: 50, width: 900, height: 600)
        let result = DisplayGeometry.frameCentered(
            on: CGPoint(x: 1500, y: -100),
            size: CGSize(width: 180, height: 200),
            visibleFrame: visible
        )
        #expect(visible.contains(result))
    }

    @Test func migratesPreviousScaleToNew130PercentBaseline() {
        #expect(DisplayGeometry.migratedScale(from: nil) == 1.0)
        #expect(DisplayGeometry.migratedScale(from: 1.0) == 1.0)
        #expect(DisplayGeometry.migratedScale(from: 1.15) == 0.9)
        #expect(DisplayGeometry.migratedScale(from: 1.3) == 1.0)
        #expect(DisplayGeometry.migratedScale(from: 0.8) == 0.8)
    }
    @Test func wanderRoutesStayHorizontalAtScreenEdgesAndDistanceCaps() {
        let bounds = CGRect(x: -1200, y: -200, width: 1000, height: 700)
        for start in [CGPoint(x: -1200, y: -200), CGPoint(x: -200, y: 500),
                      CGPoint(x: -700, y: 150)] {
            for x in stride(from: -1500.0, through: 100, by: 100) {
                for y in [-500.0, 0, 800] {
                    let target = DisplayGeometry.horizontalWanderTarget(from: start,
                        proposed: CGPoint(x: x, y: y), originBounds: bounds, maxDistance: 240)
                    #expect(target != nil)
                    if let target {
                        let dx = abs(target.x - start.x), dy = abs(target.y - start.y)
                        #expect(dx > 1.732 * dy)
                        #expect(hypot(dx, dy) <= 240.000001)
                        #expect(target.x >= bounds.minX && target.x <= bounds.maxX)
                        #expect(target.y >= bounds.minY && target.y <= bounds.maxY)
                        for progress in [0.01, 0.5, 1.0] {
                            #expect(dx * progress > 1.732 * dy * progress)
                        }
                    }
                }
            }
        }
        #expect(DisplayGeometry.horizontalWanderTarget(from: .zero, proposed: .zero,
            originBounds: CGRect(x: 0, y: 0, width: 0, height: 100), maxDistance: 200) == nil)
    }

}
