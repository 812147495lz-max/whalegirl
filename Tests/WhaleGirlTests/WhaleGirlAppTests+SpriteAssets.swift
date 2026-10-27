import AppKit
import QuartzCore
import WhaleCore
import XCTest
@testable import WhaleGirl

extension WhaleGirlAppTests {
    func testAllAddedSkinAtlasesActuallyDecodeAndStayWithinInactiveCacheBudget() async throws {
        let domain = "io.whalegirl.tests.decode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let repository = try SpriteRepository(bundle: .main, defaults: defaults)
        let yanz = repository.communityActions.filter { $0.clipID.hasPrefix("full.community.yanz.") }
        XCTAssertEqual(yanz.count, 27)
        XCTAssertTrue(repository.selectSkin(.red))
        let actions = yanz + repository.communityActions
        XCTAssertEqual(actions.count, 189)
        for action in actions {
            let ready = await repository.prepareClip(action.clipID)
            XCTAssertTrue(ready, action.title)
            let clip = try XCTUnwrap(repository.clip(action.clipID))
            let atlas = try XCTUnwrap(repository.decodedAtlas(atlasID: clip.atlasID))
            XCTAssertTrue(atlas.alpha.contains { $0 != 0 }, action.title)
            let frame = try XCTUnwrap(clip.frames.first)
            XCTAssertGreaterThan(atlas.image.width, 0)
            XCTAssertLessThanOrEqual(frame.rect.x + frame.rect.width, Double(atlas.image.width))
            XCTAssertLessThanOrEqual(repository.cachedCommunityBytes, repository.communityCacheBudget)
        }
    }

    func testSkinAndSpecificAnimationMenuActionsReachTheLiveTexture() async throws {
        let domain = "io.whalegirl.tests.menu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let repository = try SpriteRepository(bundle: .main, defaults: defaults)
        let screen = try XCTUnwrap(NSScreen.main)
        let pet = RoamPanelController(repository: repository,
            autonomy: .init(drawActionCount: { 3 }, idleDelay: 60...60))
        defer { pet.hide() }
        pet.show(centeredAt: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY),
                 screen: screen, scale: 1, clipID: "full.idle")
        pet.onSelectSkin = { skin in
            if repository.selectSkin(skin) { pet.petView?.refreshSkin() }
        }
        defer { pet.onSelectSkin = nil }
        let skins = try XCTUnwrap(pet.makeContextMenu().item(withTitle: "桌宠皮肤")?.submenu)
        let red = try XCTUnwrap(skins.item(withTitle: "赤风RED"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(red.action), to: red.target, from: red))
        XCTAssertEqual(repository.selectedSkin, .red)
        XCTAssertEqual(pet.makeContextMenu().item(withTitle: "桌宠皮肤")?.submenu?.item(withTitle: "赤风RED")?.state, .on)
        let chosen = try XCTUnwrap(repository.communityActions.first { $0.title == "Popcat 平滑" })
        let ready = await repository.prepareClip(chosen.clipID)
        XCTAssertTrue(ready)
        let clip = try XCTUnwrap(repository.clip(chosen.clipID))
        let expected = try XCTUnwrap(repository.cgImage(atlasID: clip.atlasID))
        let actions = try XCTUnwrap(pet.makeContextMenu().item(withTitle: "播放动画")?.submenu)
        let entry = try XCTUnwrap(actions.items.flatMap { $0.submenu?.items ?? [] }.first {
            ($0.representedObject as? String) == chosen.clipID
        })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(entry.action), to: entry.target, from: entry))
        let texture = try XCTUnwrap(pet.petView?.layer?.sublayers?.first?.contents) as AnyObject
        XCTAssertTrue(texture === expected)
    }

    func testSkinSelectionSeparatesActionsAliasesAndPersistsWithoutDecoding() throws {
        let domain = "io.whalegirl.tests.skins.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let repository = try SpriteRepository(bundle: .main, defaults: defaults)
        XCTAssertEqual(repository.selectedSkin, .classic)
        let classic = Set(repository.communityActions.map(\.clipID))
        let classicIdle = repository.resolvedClipID("full.idle")
        XCTAssertEqual(classic.count, 133)
        XCTAssertEqual(repository.walkingActions.count, 2)
        XCTAssertTrue(repository.selectSkin(.red))
        let red = Set(repository.communityActions.map(\.clipID))
        XCTAssertEqual(red.count, 162)
        XCTAssertTrue(classic.isDisjoint(with: red))
        for alias in ["idle", "happy", "poke", "dragged", "greet", "return"] {
            XCTAssertTrue(red.contains(repository.resolvedClipID("full.\(alias)")))
        }
        XCTAssertTrue(repository.walkingActions.isEmpty)
        XCTAssertEqual(repository.communityDecodeCount, 0)
        let restored = try SpriteRepository(bundle: .main, defaults: defaults)
        XCTAssertEqual(restored.selectedSkin, .red)
        XCTAssertTrue(restored.selectSkin(.classic))
        XCTAssertEqual(restored.resolvedClipID("full.idle"), classicIdle)
        XCTAssertEqual(Set(restored.communityActions.map(\.clipID)), classic)
    }

    func testBundledManifestAndAtlasesLoad() throws {
        let repository = try SpriteRepository(bundle: .main)
        XCTAssertNotNil(repository.clip("mini.idle"))
        XCTAssertNotNil(repository.clip("peek.wave"))
        XCTAssertNotNil(repository.clip("full.return"))
        XCTAssertNotNil(repository.image(atlasID: "mini"))
        XCTAssertNotNil(repository.image(atlasID: "peek"))
        XCTAssertNotNil(repository.image(atlasID: "full"))
        XCTAssertNotNil(repository.image(atlasID: "joy"))
        XCTAssertNotNil(repository.image(atlasID: "drag"))
        XCTAssertNotNil(repository.image(atlasID: "error"))
        XCTAssertNotNil(repository.cgImage(atlasID: "full"))
    }

    func testMenuBarAnimationFramesAreBundled() {
        for index in 1...20 {
            XCTAssertNotNil(
                Bundle.main.url(forResource: "png_\(index)", withExtension: "png", subdirectory: "MenuBarFrames"),
                "Missing menu bar animation frame png_\(index).png"
            )
        }
    }

    func testActiveAtlasIsSharedAfterCacheEvictionAndMasksMatchFramePixels() async throws {
        let repository = try SpriteRepository(bundle: .main)
        let first = try XCTUnwrap(repository.communityActions.first)
        let prepared = await repository.prepareClip(first.clipID)
        XCTAssertTrue(prepared)
        let clip = try XCTUnwrap(repository.clip(first.clipID))
        let held = try XCTUnwrap(repository.decodedAtlas(atlasID: clip.atlasID))
        for action in repository.communityActions.dropFirst().prefix(5) {
            let ready = await repository.prepareClip(action.clipID)
            XCTAssertTrue(ready)
        }
        let decodes = repository.communityDecodeCount
        let again = await repository.prepareClip(first.clipID)
        XCTAssertTrue(again)
        XCTAssertTrue(repository.decodedAtlas(atlasID: clip.atlasID) === held)
        XCTAssertEqual(repository.communityDecodeCount, decodes, "An active player's atlas must never be decoded again")
        XCTAssertLessThanOrEqual(repository.cachedCommunityBytes, repository.communityCacheBudget)
        for frame in [clip.frames[0], clip.frames[clip.frames.count / 2], try XCTUnwrap(clip.frames.last)] {
            let rect = CGRect(x: frame.rect.x, y: frame.rect.y, width: frame.rect.width, height: frame.rect.height)
            let sharedMask = held.mask(for: rect)
            let reference = try XCTUnwrap(SpriteAlphaMask(image: held.image, rect: rect))
            for y in stride(from: 0.025, to: 1.0, by: 0.05) {
                for x in stride(from: 0.025, to: 1.0, by: 0.05) {
                    let point = CGPoint(x: x, y: y)
                    XCTAssertEqual(sharedMask.contains(normalized: point), reference.contains(normalized: point))
                }
            }
        }
    }

    func testActivityFrameMidpointPreservesSharedPixelsAndMovesChangingContent() throws {
        let first = syntheticActivityFrame(tailOriginX: 60)
        let second = syntheticActivityFrame(tailOriginX: 68)
        let midpoint = try XCTUnwrap(ActivityFrameMorpher.midpoint(from: first, to: second))

        let firstPixels = try XCTUnwrap(rgbaPixels(of: first))
        let midpointPixels = try XCTUnwrap(rgbaPixels(of: midpoint))
        let unchangedBodyPixel = pixel(atX: 57, y: 20, in: firstPixels)
        XCTAssertEqual(pixel(atX: 57, y: 20, in: midpointPixels), unchangedBodyPixel)

        let midpointTailAlpha = (64...67).flatMap { x in
            (15...21).map { y in pixel(atX: x, y: y, in: midpointPixels)[3] }
        }.max() ?? 0
        XCTAssertGreaterThan(midpointTailAlpha, 0, "The interpolated tail should occupy the in-between position")
    }

    func testBundledWalkClipUsesOnlyTheContinuousRunningSection() throws {
        let repository = try SpriteRepository(bundle: .main)
        let source = try XCTUnwrap(repository.clip("full.community.318690038a1b"))
        let walk = try XCTUnwrap(repository.clip("full.walk"))
        XCTAssertTrue(walk.looping)
        XCTAssertEqual(walk.atlasID, source.atlasID)
        XCTAssertEqual(walk.frames, Array(source.frames[24..<52]))
        XCTAssertEqual(repository.communityActions.count, 133)
    }

    func testOnlyTheRetainedWalkingAssetsAreBundled() throws {
        let repository = try SpriteRepository(bundle: .main)
        XCTAssertEqual(repository.walkingActions.count, 2)
        let side = try XCTUnwrap(repository.clip("full.walk.side"))
        let source = try XCTUnwrap(repository.clip("full.community.10e8815c6fa8"))
        XCTAssertEqual(side.frames, Array(source.frames[24..<88]))
        XCTAssertNil(repository.clip("full.walk.yunyue"))
        XCTAssertNil(Bundle.main.url(forResource: "yunyue-walk", withExtension: "webp", subdirectory: "CommunityActions"))
    }

    func testCompactAtlasesKeepTheOriginalLogicalCanvasSize() throws {
        let repository = try SpriteRepository(bundle: .main)
        let idle = try XCTUnwrap(repository.clip("full.idle"))
        let layout = try XCTUnwrap(repository.renderLayout(for: idle.id))
        XCTAssertEqual(layout.canvasWidth, 384)
        XCTAssertEqual(layout.canvasHeight, 216)
        XCTAssertEqual(repository.canvasAspect(for: idle.id), 384.0 / 216.0)
        XCTAssertLessThan(layout.width * layout.height, 384 * 216)
        XCTAssertEqual(idle.frames.first?.rect.width, layout.width)
        XCTAssertEqual(idle.frames.first?.rect.height, layout.height)
        XCTAssertGreaterThanOrEqual(layout.normalized.minX, 0)
        XCTAssertGreaterThanOrEqual(layout.normalized.minY, 0)
        XCTAssertLessThanOrEqual(layout.normalized.maxX, 1)
        XCTAssertLessThanOrEqual(layout.normalized.maxY, 1)
    }
}
