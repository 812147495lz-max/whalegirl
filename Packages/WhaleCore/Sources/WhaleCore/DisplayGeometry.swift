import CoreGraphics

public enum DisplayGeometry {
    public static func peekHeight(screenFrame: CGRect, userScale: Double) -> Double {
        screenFrame.height * 0.082 * clampedScale(userScale)
    }

    public static func fullHeight(screenFrame: CGRect, userScale: Double) -> Double {
        screenFrame.height * 0.15 * clampedScale(userScale)
    }

    public static func clampedScale(_ scale: Double) -> Double {
        min(max(scale, 0.8), 1.95)
    }

    public static func clampedPreferenceScale(_ scale: Double) -> Double {
        min(max(scale, 0.8), 1.5)
    }

    public static func migratedScale(from previousScale: Double?) -> Double {
        guard let previousScale, previousScale != 0 else { return 1.0 }
        if abs(previousScale - 1.0) < 0.001 { return 1.0 }
        let normalized = (previousScale / 1.3 * 20).rounded() / 20
        return clampedPreferenceScale(normalized)
    }

    public static func frameBelowMenuBar(anchor: CGRect, size: CGSize, visibleFrame: CGRect) -> CGRect {
        let origin = CGPoint(
            x: min(max(anchor.midX - size.width / 2, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(anchor.minY - size.height, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
        return CGRect(origin: origin, size: size)
    }

    public static func frameCentered(on point: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGRect {
        let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        return clamp(CGRect(origin: origin, size: size), to: visibleFrame)
    }

    /// Pick a predominantly horizontal route: abs(dx) > 1.732 * abs(dy).
    /// Both endpoints must lie in the legal window-origin rectangle.
    public static func horizontalWanderTarget(from start: CGPoint, proposed: CGPoint,
                                               originBounds: CGRect, maxDistance: Double) -> CGPoint? {
        guard originBounds.width > 1, maxDistance > 1,
              start.x >= originBounds.minX, start.x <= originBounds.maxX,
              start.y >= originBounds.minY, start.y <= originBounds.maxY else { return nil }
        var x = min(originBounds.maxX, max(originBounds.minX, proposed.x))
        if abs(x - start.x) < min(90, originBounds.width / 4) {
            x = start.x < originBounds.midX ? originBounds.maxX : originBounds.minX
        }
        let dx = x - start.x
        guard abs(dx) > 1 else { return nil }
        // A small margin preserves the strict inequality, including after interpolation.
        let verticalLimit = abs(dx) / 1.733
        let y = min(originBounds.maxY, start.y + verticalLimit,
                    max(originBounds.minY, start.y - verticalLimit, proposed.y))
        let dy = y - start.y
        let factor = min(1, maxDistance / hypot(dx, dy))
        return CGPoint(x: start.x + dx * factor, y: start.y + dy * factor)
    }

    public static func clamp(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, visibleFrame.width), height: min(frame.height, visibleFrame.height))
        return CGRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }
}
