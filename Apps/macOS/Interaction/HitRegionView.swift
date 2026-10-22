import AppKit

@MainActor
protocol PetViewInteractionDelegate: AnyObject {
    func petViewDidPetHead(_ view: PetView)
    func petViewDidPokeFace(_ view: PetView)
    func petViewDidRequestFull(_ view: PetView)
    func petViewDidRequestReturn(_ view: PetView)
    func petViewDidRequestDismiss(_ view: PetView)
    func petView(_ view: PetView, didDragTo screenPoint: CGPoint, downwardDistance: Double)
    func petViewDidEndDrag(_ view: PetView)
}

@MainActor
class HitRegionView: NSView {
    /// Normalized bounds kept close to the visible placeholder art. The panel is also tightly sized;
    /// WhaleGirl never uses a screen-sized transparent event window.
    var normalizedHitRegion = CGRect(x: 0.08, y: 0.03, width: 0.84, height: 0.94)
    var hitRegionBounds: CGRect { bounds }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let childHit = super.hitTest(point), childHit !== self {
            return childHit
        }
        let regionBounds = hitRegionBounds
        let hitRegion = CGRect(
            x: regionBounds.minX + regionBounds.width * normalizedHitRegion.minX,
            y: regionBounds.minY + regionBounds.height * normalizedHitRegion.minY,
            width: regionBounds.width * normalizedHitRegion.width,
            height: regionBounds.height * normalizedHitRegion.height
        )
        return hitRegion.contains(point) ? self : nil
    }
}

/// Alpha of the displayed frame, independent of atlas padding and animation pose.
struct SpriteAlphaMask: Sendable {
    let width: Int
    let height: Int
    private let alpha: [UInt8]
    private let rowStride: Int
    private let originX: Int
    private let originY: Int
    private let packed: Bool

    init(alpha: [UInt8], atlasWidth: Int, rect: CGRect, packed: Bool = false) {
        self.alpha = alpha
        self.packed = packed
        rowStride = atlasWidth
        originX = Int(rect.minX)
        originY = Int(rect.minY)
        width = Int(rect.width)
        height = Int(rect.height)
    }

    init?(image: CGImage, rect: CGRect) {
        guard let frame = image.cropping(to: rect) else { return nil }
        let width = frame.width
        let height = frame.height
        self.width = width
        self.height = height
        rowStride = width
        originX = 0
        originY = 0
        packed = false
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }

    func contains(normalized point: CGPoint) -> Bool {
        guard point.x >= 0, point.x < 1, point.y >= 0, point.y < 1 else { return false }
        let x = min(width - 1, Int(point.x * Double(width)))
        let y = min(height - 1, Int((1 - point.y) * Double(height)))
        let index = (originY + y) * rowStride + originX + x
        if packed {
            return alpha.indices.contains(index / 8) && (alpha[index / 8] & (1 << (index % 8))) != 0
        }
        return alpha.indices.contains(index) && alpha[index] >= 24
    }
}
