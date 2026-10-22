import Foundation
import Testing
@testable import WhaleCore

struct SpriteManifestTests {
    private let frame = SpriteManifest.Frame(
        rect: .init(x: 0, y: 0, width: 20, height: 20),
        duration: 0.1,
        anchor: .init(x: 0.5, y: 1),
        visualBounds: .init(x: 0, y: 0, width: 1, height: 1),
        hitbox: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    )

    @Test func rejectsFrameOutsideAtlas() {
        let invalid = SpriteManifest(
            schemaVersion: 1,
            atlases: [.init(id: "a", resource: "a", pixelWidth: 10, pixelHeight: 10)],
            clips: [.init(id: "idle", atlasID: "a", looping: true, frames: [frame])]
        )
        #expect(throws: SpriteManifestError.frameOutsideAtlas("idle")) { try invalid.validate() }
    }

    @Test func timelineStopsOnLastFrame() {
        let clip = SpriteManifest.Clip(id: "once", atlasID: "a", looping: false, frames: [frame, frame])
        #expect(AnimationTimeline.frameIndex(clip: clip, elapsed: 99) == 1)
    }
}
