import AppKit
import QuartzCore
import WhaleCore
import XCTest
@testable import WhaleGirl

extension WhaleGirlAppTests {
    func testOneShotHoldsFinalPoseThenRestsBeforeAnotherAction() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = await repository.prepareClip("full.community.manual")
        XCTAssertTrue(ready)
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), repository: repository,
            autonomy: .init(drawActionCount: { 3 }, idleDelay: 0.5...0.5, finishedPoseDelay: 0.2))
        defer { view.pauseAnimation(); view.releaseStationaryAction() }
        view.play("full.community.manual", looping: false)
        try await waitForWanderingCondition { view.isHoldingFinishedAction }
        let lastRect = view.layer?.sublayers?.first?.contentsRect
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(view.currentClipID, "full.community.manual")
        XCTAssertEqual(view.layer?.sublayers?.first?.contentsRect, lastRect)
        try await waitForWanderingCondition { view.currentClipID == repository.resolvedClipID("full.idle") }
        XCTAssertFalse(view.isHoldingFinishedAction)
        let idleRect = view.layer?.sublayers?.first?.contentsRect
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(view.currentClipID, repository.resolvedClipID("full.idle"))
        XCTAssertEqual(view.layer?.sublayers?.first?.contentsRect, idleRect)
        try await waitForWanderingCondition { view.currentClipID != repository.resolvedClipID("full.idle") }
        XCTAssertEqual(view.currentClipID, "full.community.running")
    }

    func testFinishedPoseTimerCannotOverrideNewPlaybackOrRestartWhilePaused() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = await repository.prepareClip("full.community.manual")
        XCTAssertTrue(ready)
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), repository: repository,
            autonomy: .init(drawActionCount: { 3 }, idleDelay: 10...10, finishedPoseDelay: 0.15))
        defer { view.pauseAnimation(); view.releaseStationaryAction() }
        view.play("full.community.manual", looping: false)
        try await waitForWanderingCondition { view.isHoldingFinishedAction }
        view.pauseAnimation()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(view.currentClipID, "full.community.manual")
        view.resumeAnimation()
        try await waitForWanderingCondition { view.currentClipID == repository.resolvedClipID("full.idle") }
        view.play("full.community.manual", looping: false)
        try await waitForWanderingCondition { view.isHoldingFinishedAction }
        view.play("full.walk", looping: true)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(view.currentClipID, "full.walk")
        XCTAssertFalse(view.isHoldingFinishedAction)
    }

    func testCoordinatorSwitchesThreeLiveCharactersWithoutMovingTheirWindows() async throws {
        let original = UserDefaults.standard.object(forKey: "desktopPetSkin")
        let coordinator = try AppCoordinator.make()
        defer {
            coordinator.stop()
            if let original { UserDefaults.standard.set(original, forKey: "desktopPetSkin") }
            else { UserDefaults.standard.removeObject(forKey: "desktopPetSkin") }
        }
        coordinator.menuBarDidSelectSkin(.classic)
        let screen = try XCTUnwrap(NSScreen.main)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        for offset in [-180.0, 0, 180.0] {
            coordinator.menuBarDidDragCharacter(to: CGPoint(x: screen.visibleFrame.midX + offset,
                                                           y: screen.visibleFrame.midY), isNew: true)
        }
        let windows = NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) && $0.contentView is PetView }
        XCTAssertEqual(windows.count, 3)
        let views = try windows.map { try XCTUnwrap($0.contentView as? PetView) }
        try await waitForWanderingCondition(timeout: 15) {
            windows.allSatisfy(\.isVisible) && views.allSatisfy { $0.layer?.sublayers?.first?.contents != nil }
        }
        let frames = windows.map(\.frame)
        let oldTextures = try views.map { try XCTUnwrap($0.layer?.sublayers?.first?.contents) as AnyObject }
        coordinator.menuBarDidSelectSkin(.red)
        try await waitForWanderingCondition(timeout: 15) {
            views.indices.allSatisfy { index in
                guard let texture = views[index].layer?.sublayers?.first?.contents as AnyObject? else { return false }
                return views[index].currentClipID.hasPrefix("full.community.red.") && texture !== oldTextures[index]
            }
        }
        XCTAssertEqual(Set(views.map(\.currentClipID)).count, 1, "Resting pets share the neutral pose")
        XCTAssertEqual(windows.map(\.frame), frames)
        let redTextures = try views.map { try XCTUnwrap($0.layer?.sublayers?.first?.contents) as AnyObject }
        let rects = views.map { $0.layer?.sublayers?.first?.contentsRect }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(views.map { $0.layer?.sublayers?.first?.contentsRect }, rects, "Idle is a held neutral pose")
        coordinator.menuBarDidSelectSkin(.classic)
        try await waitForWanderingCondition(timeout: 15) {
            views.indices.allSatisfy { index in
                guard let texture = views[index].layer?.sublayers?.first?.contents as AnyObject? else { return false }
                return !views[index].currentClipID.hasPrefix("full.community.red.") && texture !== redTextures[index]
            }
        }
        XCTAssertEqual(Set(views.map(\.currentClipID)).count, 1, "Resting pets share the neutral pose")
        XCTAssertEqual(windows.map(\.frame), frames)
        coordinator.menuBarDidRequestCloseAllCharacters()
        XCTAssertTrue(windows.allSatisfy { !$0.isVisible })
    }

    func testAllCommunityActionsDecodeWithTransparencyAndBoundedCache() async throws {
        let repository = try SpriteRepository(bundle: .main)
        XCTAssertEqual(repository.communityActions.count, 133)
        let firstID = try XCTUnwrap(repository.communityActions.first?.clipID)
        let firstAtlas = try XCTUnwrap(repository.clip(firstID)?.atlasID)
        for action in repository.communityActions {
            let prepared = await repository.prepareClip(action.clipID)
            XCTAssertTrue(prepared, "Failed to decode \(action.title)")
            let clip = try XCTUnwrap(repository.clip(action.clipID))
            let image = try XCTUnwrap(repository.cgImage(atlasID: clip.atlasID))
            let atlas = try XCTUnwrap(repository.manifest.atlas(id: clip.atlasID))
            XCTAssertEqual(image.width, atlas.pixelWidth)
            XCTAssertEqual(image.height, atlas.pixelHeight)
            XCTAssertTrue([CGImageAlphaInfo.premultipliedFirst, .premultipliedLast, .first, .last].contains(image.alphaInfo))
            XCTAssertLessThanOrEqual(repository.cachedCommunityBytes, repository.communityCacheBudget)
        }
        XCTAssertNil(repository.cgImage(atlasID: firstAtlas))
        XCTAssertTrue(repository.clip("full.idle")?.id.hasPrefix("full.community.") == true)
        XCTAssertNotNil(repository.clip("full.return"))
        XCTAssertEqual(repository.clip("peek.idle")?.id, "peek.idle")
    }

    func testCoordinatorCreatesMovesAndClosesMultipleCharacters() throws {
        let coordinator = try AppCoordinator.make()
        defer { coordinator.stop() }
        let screen = try XCTUnwrap(NSScreen.main)
        let center = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        func createdWindows() -> [NSWindow] {
            NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) && $0.contentView is PetView && $0.isVisible }
        }
        coordinator.menuBarDidDragCharacter(to: center, isNew: true)
        coordinator.menuBarDidDragCharacter(to: CGPoint(x: center.x - 140, y: center.y), isNew: false)
        XCTAssertEqual(createdWindows().count, 1, "A continuous drag must create only one character")
        coordinator.menuBarDidDragCharacter(to: center, isNew: true)
        coordinator.menuBarDidDragCharacter(to: CGPoint(x: center.x + 140, y: center.y), isNew: true)
        let windows = createdWindows()
        XCTAssertEqual(windows.count, 3)
        let moved = try XCTUnwrap(windows.first)
        let view = try XCTUnwrap(moved.contentView as? PetView)
        let others = windows.filter { $0 !== moved }.map { ($0, $0.frame) }
        let oldFrame = moved.frame
        coordinator.petView(view, didDragTo: CGPoint(x: center.x, y: center.y - 150), downwardDistance: 150)
        coordinator.petViewDidEndDrag(view)
        XCTAssertNotEqual(moved.frame, oldFrame)
        XCTAssertTrue(moved.isVisible, "Releasing a desktop character must not return it to the menu bar")
        for (window, frame) in others { XCTAssertEqual(window.frame, frame) }
        coordinator.petViewDidRequestDismiss(view)
        XCTAssertFalse(moved.isVisible)
        XCTAssertEqual(createdWindows().count, 2)
        coordinator.menuBarDidRequestCloseAllCharacters()
        XCTAssertTrue(createdWindows().isEmpty)
        coordinator.menuBarDidRequestFull()
        XCTAssertEqual(createdWindows().count, 1, "Closing all must keep the application able to spawn again")
    }

    func testCharacterContextMenuActionsTargetOnlyTheirOwnWindow() throws {
        let repository = try SpriteRepository(bundle: .main)
        let screen = try XCTUnwrap(NSScreen.main)
        let point = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let first = RoamPanelController(repository: repository)
        let second = RoamPanelController(repository: repository)
        defer { first.hide(); second.hide() }
        first.show(centeredAt: point, screen: screen, scale: 1, clipID: "full.idle")
        second.show(centeredAt: point, screen: screen, scale: 1, clipID: "full.idle")
        first.onClose = { [weak first] in first?.hide() }
        let menu = first.makeContextMenu()
        let sizes = try XCTUnwrap(menu.item(withTitle: "调整大小")?.submenu)
        let control = try XCTUnwrap(sizes.items.first?.view)
        let slider = try XCTUnwrap(control.subviews.compactMap { $0 as? NSSlider }.first)
        let secondFrame = second.panel?.frame
        let original = try XCTUnwrap(first.panel?.frame)
        slider.doubleValue = 60
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        XCTAssertLessThan(try XCTUnwrap(first.panel?.frame.height), original.height)
        XCTAssertEqual(second.panel?.frame, secondFrame)
        let close = try XCTUnwrap(menu.item(withTitle: "关闭这只鲸鱼娘"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(close.action), to: close.target, from: close))
        XCTAssertFalse(first.isVisible)
        XCTAssertTrue(second.isVisible)
    }

    func testSelectedAnimationChangesOnlyTheChosenCharactersTexture() async throws {
        let repository = try SpriteRepository(bundle: .main)
        let idleReady = await repository.prepareClip("full.idle")
        XCTAssertTrue(idleReady)
        let idleID = repository.resolvedClipID("full.idle")
        let chosen = try XCTUnwrap(repository.communityActions.first { $0.clipID != idleID })
        let chosenReady = await repository.prepareClip(chosen.clipID)
        XCTAssertTrue(chosenReady)
        let clip = try XCTUnwrap(repository.clip(chosen.clipID))
        let expected = try XCTUnwrap(repository.cgImage(atlasID: clip.atlasID))
        let screen = try XCTUnwrap(NSScreen.main)
        let point = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let first = RoamPanelController(repository: repository)
        let second = RoamPanelController(repository: repository)
        defer { first.hide(); second.hide() }
        first.show(centeredAt: point, screen: screen, scale: 1, clipID: "full.idle")
        second.show(centeredAt: point, screen: screen, scale: 1, clipID: "full.idle")
        let originalSecondTexture = try XCTUnwrap(second.petView?.layer?.sublayers?.first?.contents) as AnyObject
        let menu = first.makeContextMenu()
        let actions = try XCTUnwrap(menu.item(withTitle: "播放动画")?.submenu)
        let item = try XCTUnwrap(actions.items.flatMap { $0.submenu?.items ?? [] }.first {
            ($0.representedObject as? String) == chosen.clipID
        })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        let firstTexture = try XCTUnwrap(first.petView?.layer?.sublayers?.first?.contents) as AnyObject
        let secondTexture = try XCTUnwrap(second.petView?.layer?.sublayers?.first?.contents) as AnyObject
        XCTAssertTrue(firstTexture === expected)
        XCTAssertTrue(secondTexture === originalSecondTexture)
    }

    func testDesktopCharactersHaveIndependentWindowsSizesAndMenus() throws {
        let repository = try SpriteRepository(bundle: .main)
        let screen = try XCTUnwrap(NSScreen.main)
        let first = RoamPanelController(repository: repository)
        let second = RoamPanelController(repository: repository)
        defer { first.hide(); second.hide() }
        first.show(centeredAt: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY),
                   screen: screen, scale: 1, clipID: "full.idle")
        second.show(centeredAt: CGPoint(x: screen.visibleFrame.midX + 200, y: screen.visibleFrame.midY),
                    screen: screen, scale: 1, clipID: "full.idle")
        XCTAssertFalse(first.panel === second.panel)
        let originalSecondFrame = try XCTUnwrap(second.panel?.frame)
        let originalFirstFrame = try XCTUnwrap(first.panel?.frame)
        first.setCharacterScale(0.6)
        XCTAssertLessThan(try XCTUnwrap(first.panel?.frame.height), originalFirstFrame.height)
        XCTAssertEqual(second.panel?.frame, originalSecondFrame)
        let menu = first.makeContextMenu()
        XCTAssertNotNil(menu.item(withTitle: "关闭这只鲸鱼娘"))
        XCTAssertNotNil(menu.item(withTitle: "退出 WhaleGirl"))
        let animations = try XCTUnwrap(menu.item(withTitle: "播放动画")?.submenu)
        let actionCount = animations.items.reduce(0) { $0 + ($1.submenu?.items.count ?? 0) }
        XCTAssertEqual(actionCount, repository.communityActions.count)
        first.hide()
        XCTAssertFalse(first.isVisible)
        XCTAssertTrue(second.isVisible)
    }

    func testPanelCanOpenAndCloseTwoHundredTimesWithoutMultiplyingWindows() throws {
        let repository = try SpriteRepository(bundle: .main)
        let controller = PeekPanelController(repository: repository)
        let frame = CGRect(x: 100, y: 100, width: 110, height: 90)
        var identity: ObjectIdentifier?

        for _ in 0..<200 {
            controller.show(frame: frame, clipID: "peek.idle")
            guard let panel = controller.panel else { return XCTFail("Panel was not created") }
            if let identity {
                XCTAssertEqual(identity, ObjectIdentifier(panel))
            } else {
                identity = ObjectIdentifier(panel)
            }
            controller.hide()
        }
        XCTAssertFalse(controller.isVisible)
    }

    func testCharacterHasNoControlDockAndTransparentPixelsPassThrough() async throws {
        let repository = try SpriteRepository(bundle: .main)
        let ready = await repository.prepareClip("full.idle")
        XCTAssertTrue(ready)
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = RoamPanelController(repository: repository)
        defer { controller.hide() }
        controller.show(centeredAt: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY),
                        screen: screen, scale: 1, clipID: "full.idle")
        let panel = try XCTUnwrap(controller.panel)
        let view = try XCTUnwrap(controller.petView)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.subviews.compactMap { $0 as? NSVisualEffectView }.isEmpty)
        XCTAssertTrue(view.subviews.compactMap { $0 as? NSButton }.isEmpty)
        XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenPrimary))
        func findPoints() throws -> (CGPoint, CGPoint) {
            var opaque: CGPoint?
            var clear: CGPoint?
            for y in stride(from: 1.0, to: view.bounds.height, by: 3) {
                for x in stride(from: 1.0, to: view.bounds.width, by: 3) {
                    let point = CGPoint(x: x, y: y)
                    if view.containsCharacter(at: point) { opaque = opaque ?? point }
                    else { clear = clear ?? point }
                }
            }
            return (try XCTUnwrap(opaque), try XCTUnwrap(clear))
        }
        func verifyMouseAcceptance() throws {
            let (opaque, clear) = try findPoints()
            XCTAssertTrue(view.hitTest(opaque) === view)
            XCTAssertNil(view.hitTest(clear))
            controller.refreshMouseAcceptance(at: panel.convertPoint(toScreen: clear))
            XCTAssertTrue(panel.ignoresMouseEvents, "Transparent pixels must make the whole window ignore mouse events")
            controller.refreshMouseAcceptance(at: panel.convertPoint(toScreen: opaque))
            XCTAssertFalse(panel.ignoresMouseEvents, "Opaque character pixels must remain interactive")
        }
        try verifyMouseAcceptance()
        controller.setCharacterScale(0.6)
        view.layoutSubtreeIfNeeded()
        try verifyMouseAcceptance()
    }

    func testAlphaMaskMatchesImageOrientationAndRejectsTransparentPixels() throws {
        // Explicit top-to-bottom RGBA rows: only top-right and bottom-left opaque.
        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for (x, y) in [(3, 0), (0, 3)] {
            let offset = (y * 4 + x) * 4
            pixels[offset] = 255
            pixels[offset + 3] = 255
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let mask = try XCTUnwrap(SpriteAlphaMask(image: image, rect: CGRect(x: 0, y: 0, width: 4, height: 4)))
        XCTAssertTrue(mask.contains(normalized: CGPoint(x: 0.875, y: 0.875)))
        XCTAssertTrue(mask.contains(normalized: CGPoint(x: 0.125, y: 0.125)))
        XCTAssertFalse(mask.contains(normalized: CGPoint(x: 0.125, y: 0.875)))
        XCTAssertFalse(mask.contains(normalized: CGPoint(x: 0.875, y: 0.125)))
        XCTAssertFalse(mask.contains(normalized: CGPoint(x: -0.1, y: 0.5)))
    }

    func testFullscreenGeometryRespectsFrontAppDialogsAndDisplayCoordinates() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let other = CGRect(x: -1280, y: 200, width: 1280, height: 720)
        func window(_ rect: CGRect, pid: Int32) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: 0,
             kCGWindowAlpha as String: 1, kCGWindowBounds as String: rect.dictionaryRepresentation]
        }
        let full = window(main, pid: 42)
        let normal = window(CGRect(x: 100, y: 40, width: 900, height: 700), pid: 77)
        let dialog = window(CGRect(x: 400, y: 300, width: 400, height: 200), pid: 42)
        XCTAssertEqual(FullScreenAvoidance.coveredDisplays([main], windows: [full], primaryTop: 900, ownPID: 1), [main])
        XCTAssertTrue(FullScreenAvoidance.coveredDisplays([main], windows: [normal, full], primaryTop: 900, ownPID: 1).isEmpty)
        XCTAssertEqual(FullScreenAvoidance.coveredDisplays([main], windows: [dialog, full], primaryTop: 900, ownPID: 1), [main])
        let otherFull = window(CGRect(x: -1280, y: -20, width: 1280, height: 720), pid: 52)
        XCTAssertEqual(FullScreenAvoidance.coveredDisplays([main, other], windows: [normal, otherFull], primaryTop: 900, ownPID: 1), [other])
    }
}
