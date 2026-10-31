import AppKit
import QuartzCore
import WhaleCore
import XCTest
@testable import WhaleGirl

extension WhaleGirlAppTests {
    func testEditableDialogueCSVReloadAndSafeFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("气泡文案.csv")
        let store = DialogueCSVStore(url: url, defaults: ["默认一", "默认二"])
        try store.ensureFile()
        XCTAssertEqual(store.currentLines(), ["默认一", "默认二"])
        try DialogueCSV.encode(["自定义你好", "带逗号,和引号\"的文案"]).write(to: url, atomically: true, encoding: .utf8)
        try store.ensureFile()
        XCTAssertEqual(store.currentLines(), ["自定义你好", "带逗号,和引号\"的文案"])
        try "气泡文案\n只有新文案\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.currentLines(), ["只有新文案"], "Save must replace the list on the next request")
        for broken in ["", "气泡文案\n", "气泡文案\n\"未保存完", "气泡文案\n多个,非空列"] {
            try broken.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(store.currentLines(), ["只有新文案"])
        }
        try DialogueCSV.encode(["UTF16 文案🐋"]).write(to: url, atomically: true, encoding: .utf16)
        XCTAssertEqual(store.currentLines(), ["UTF16 文案🐋"])
        try Data(repeating: 65, count: 1_048_577).write(to: url)
        XCTAssertEqual(store.currentLines(), ["UTF16 文案🐋"])
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(store.currentLines(), ["UTF16 文案🐋"])
    }

    func testTrimmedFallRevealsCardAfterBounceBeforeFinalPoseAndClosesCleanly() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let resource = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("ClickAnimations"))
        let manifest = try SpriteManifest.decode(Data(contentsOf: resource.appendingPathComponent("sprite-manifest.json")))
        let fall = try XCTUnwrap(manifest.clip(id: "fall"))
        XCTAssertEqual(fall.frames.count, 52)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resource.appendingPathComponent("provenance.json"))) as? [String: Any])
        let policy = try XCTUnwrap(metadata["playback"] as? [String: Any])
        let sourceFrames = try XCTUnwrap(policy["fallSourceFrameNumbers"] as? [Int])
        XCTAssertEqual(sourceFrames.first, 1, "Preserve the exact hover handoff")
        XCTAssertEqual(sourceFrames.last, 68)
        XCTAssertTrue((15...58).allSatisfy { sourceFrames.contains($0) }, "Keep drop, flip, rebound and arm motion")
        let controller = MenuBarInformationController()
        defer { controller.shutdown() }
        XCTAssertEqual(sourceFrames[controller.informationRevealFrameIndex], 42)
        controller.open(anchor: CGRect(x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.maxY,
                                       width: 40, height: 24), screen: screen, scale: 0.9)
        try await waitForWanderingCondition(timeout: 15) { controller.state == .descending }
        while controller.frameIndex < controller.informationRevealFrameIndex - 1 { controller.advanceAnimation() }
        XCTAssertFalse(controller.informationPanel?.isVisible == true)
        controller.advanceAnimation()
        XCTAssertEqual(controller.state, .descending, "Card opens while arm animation is still running")
        let card = try XCTUnwrap(controller.informationPanel)
        XCTAssertTrue(card.isVisible)
        controller.close()
        XCTAssertFalse(card.isVisible, "Closing during early reveal hides the card immediately")
        for _ in 0..<55 { controller.advanceAnimation() }
        try await waitForWanderingCondition(timeout: 15) { controller.state == .ascending }
        XCTAssertFalse(card.isVisible)
        controller.shutdown()
        XCTAssertFalse(card.isVisible)
    }

    func testRopeHandoffUsesExactHoverBitmapAndKeepsCanvasThroughShowAndUp() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = MenuBarInformationController()
        defer { controller.shutdown() }
        let alignment = try XCTUnwrap(controller.alignment)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "frame_0030", withExtension: "png", subdirectory: "HoverAnimations/appear"))
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        var rawRect = CGRect(origin: .zero, size: image.size)
        let raw = try XCTUnwrap(image.cgImage(forProposedRect: &rawRect, context: nil, hints: nil))
        let crop = alignment.hoverCrop
        let hoverBitmap = try XCTUnwrap(raw.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)))
        let anchor = CGRect(x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.maxY, width: 40, height: 24)
        let hoverFrame = MenuBarInformationController.hoverPresentationFrame(anchor: anchor, visibleFrame: screen.visibleFrame,
            sourceSize: CGSize(width: hoverBitmap.width, height: hoverBitmap.height), displayScale: 0.9 * 1.3)
        var verified = false
        controller.onPresentationReady = {
            guard let panel = controller.characterPanel,
                  let layers = panel.contentView?.layer?.sublayers,
                  let handoff = layers.first(where: { $0.name == "hover-handoff" }) else { return XCTFail("Missing handoff layer") }
            XCTAssertTrue((handoff.contents as AnyObject?) === hoverBitmap)
            XCTAssertFalse(handoff.isHidden)
            XCTAssertTrue(layers.first?.isHidden == true, "Never double-render the two shared poses")
            let actual = handoff.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
            XCTAssertEqual(actual.minX, hoverFrame.minX, accuracy: 0.00001)
            XCTAssertEqual(actual.minY, hoverFrame.minY, accuracy: 0.00001)
            XCTAssertEqual(actual.size, hoverFrame.size)
            verified = true
        }
        controller.open(anchor: anchor, screen: screen, scale: 0.9, handoffPose: .init(image: hoverBitmap, frame: hoverFrame))
        try await waitForWanderingCondition(timeout: 15) { verified }
        let panel = try XCTUnwrap(controller.characterPanel)
        let layer = try XCTUnwrap(panel.contentView?.layer?.sublayers?.first)
        let canvas = layer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        controller.advanceAnimation()
        XCTAssertFalse(layer.isHidden)
        XCTAssertTrue(panel.contentView?.layer?.sublayers?.last?.isHidden == true)
        for _ in 0..<70 { controller.advanceAnimation() }
        try await waitForWanderingCondition(timeout: 15) { controller.state == .showing }
        XCTAssertEqual(layer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY), canvas)
        controller.close()
        try await waitForWanderingCondition(timeout: 15) { controller.state == .ascending && controller.frameIndex == 0 }
        XCTAssertEqual(layer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY), canvas)
        controller.shutdown()
    }

    func testRopeRegisteredPoseMapsToHoverAtEverySizeAndDisplayEdge() throws {
        let alignment = try XCTUnwrap(MenuBarInformationController().alignment)
        let visible = CGRect(x: -1280, y: 50, width: 1280, height: 750)
        for scale in [0.8, 1.0, 1.3, 1.5] {
            for x in [-1270.0, -640, -80] {
                let frames = MenuBarInformationController.presentationFrames(anchor: CGRect(x: x, y: 800, width: 40, height: 24),
                    visibleFrame: visible, alignment: alignment, scale: scale)
                XCTAssertTrue(visible.contains(frames.character))
                XCTAssertTrue(visible.contains(frames.card))
                let h = alignment.hoverCrop, f = alignment.fallCrop
                for point in [CGPoint(x: 470, y: 70), CGPoint(x: 630, y: 240), CGPoint(x: 700, y: 460)] {
                    let fromFall = CGPoint(x: frames.canvas.minX + (point.x - f.x) / f.width * frames.canvas.width,
                        y: frames.canvas.maxY - (point.y - f.y) / f.height * frames.canvas.height)
                    let expected = CGPoint(x: frames.hover.minX + (point.x * alignment.sourceScale + alignment.offsetX - h.x) / h.width * frames.hover.width,
                        y: frames.hover.maxY - (point.y * alignment.sourceScale + alignment.offsetY - h.y) / h.height * frames.hover.height)
                    XCTAssertEqual(fromFall.x, expected.x, accuracy: 0.00001)
                    XCTAssertEqual(fromFall.y, expected.y, accuracy: 0.00001)
                }
            }
        }
    }

    func testRopeInfoDownStaticCardAndUpLifecycle() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = MenuBarInformationController()
        defer { controller.shutdown() }
        let anchor = CGRect(x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.maxY, width: 40, height: 24)
        controller.open(anchor: anchor, screen: screen, scale: 0.9)
        try await waitForWanderingCondition(timeout: 15) { controller.state == .descending }
        let character = try XCTUnwrap(controller.characterPanel)
        let original = character.frame
        XCTAssertTrue(character.isVisible)
        XCTAssertTrue(character.ignoresMouseEvents)
        XCTAssertFalse(controller.informationPanel?.isVisible == true)
        for _ in 0..<70 { controller.advanceAnimation() }
        try await waitForWanderingCondition(timeout: 15) { controller.state == .showing }
        let card = try XCTUnwrap(controller.informationPanel)
        XCTAssertTrue(card.isVisible)
        XCTAssertFalse(card.ignoresMouseEvents, "The visible card contains metric preferences and scroll controls")
        let alignment = try XCTUnwrap(controller.alignment)
        let frames = MenuBarInformationController.presentationFrames(anchor: anchor,
            visibleFrame: screen.visibleFrame, alignment: alignment, scale: 0.9)
        let hand = MenuBarInformationController.presentationHand(canvas: frames.canvas, alignment: alignment)
        XCTAssertEqual(frames.card.minX, hand.x + 10, accuracy: 1)
        XCTAssertEqual(frames.card.maxY, hand.y + 44, accuracy: 1)
        XCTAssertEqual(character.frame, original)
        let pose = controller.frameIndex
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.frameIndex, pose, "Show is a static picture, never a loop")
        let view = try XCTUnwrap(controller.informationView)
        XCTAssertEqual(view.frame.width, 236, accuracy: 1)
        func checkOpaqueText(_ node: NSView) {
            if let label = node as? NSTextField {
                XCTAssertEqual(label.textColor?.alphaComponent ?? 0, 1)
            }
            for child in node.subviews { checkOpaqueText(child) }
        }
        checkOpaqueText(view)
        XCTAssertEqual(view.alphaValue, 1)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        try attachSnapshot(of: view, named: "computer-status-card")
        controller.close()
        XCTAssertFalse(card.isVisible)
        try await waitForWanderingCondition(timeout: 15) { controller.state == .ascending && controller.frameIndex == 0 }
        // Give the asynchronous up texture time to replace the held show picture.
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<24 { controller.advanceAnimation() }
        try await waitForWanderingCondition { controller.state == .hidden }
        XCTAssertFalse(character.isVisible)
        XCTAssertFalse(card.isVisible)
    }

    func testRopeInfoRapidCloseAndShutdownCannotLeaveOrphanWindows() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let anchor = CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 30, height: 24)
        let controller = MenuBarInformationController()
        defer { controller.shutdown() }
        controller.open(anchor: anchor, screen: screen, scale: 1)
        controller.close()
        XCTAssertEqual(controller.state, .hidden)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(controller.characterPanel?.isVisible == true)
        controller.open(anchor: anchor, screen: screen, scale: 1)
        try await waitForWanderingCondition(timeout: 15) { controller.state == .descending }
        controller.close()
        for _ in 0..<70 { controller.advanceAnimation() }
        try await waitForWanderingCondition { controller.state == .ascending }
        XCTAssertFalse(controller.informationPanel?.isVisible == true)
        controller.shutdown()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(controller.state, .hidden)
        XCTAssertFalse(controller.characterPanel?.isVisible == true)
    }

    func testRopeInfoMenuButtonRoutingAndUninstallCleanup() async throws {
        let repository = try SpriteRepository(bundle: .main)
        var menus = 0
        let menuBar = MenuBarController(repository: repository, metricsSampler: .init(), contextMenuPresenter: { menu, _, _ in
            XCTAssertNotNil(menu.item(withTitle: "退出 WhaleGirl"))
            XCTAssertNotNil(menu.item(withTitle: "编辑气泡文案 CSV"))
            menus += 1
        })
        defer { menuBar.uninstall() }
        menuBar.install(scale: 0.9)
        func click(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        menuBar.handleStatusClick(try click(.rightMouseUp, modifiers: .option))
        XCTAssertEqual(menus, 1)
        XCTAssertEqual(menuBar.informationState, .hidden)
        menuBar.handleStatusClick(try click(.rightMouseUp))
        try await waitForWanderingCondition(timeout: 15) { menuBar.informationState == .showing }
        menuBar.handleStatusClick(try click(.leftMouseUp))
        XCTAssertEqual(menus, 2)
        XCTAssertEqual(menuBar.informationState, .showing)
        menuBar.handleStatusClick(try click(.rightMouseUp, modifiers: .option))
        XCTAssertEqual(menus, 3)
        XCTAssertEqual(menuBar.informationState, .showing)
        menuBar.handleStatusClick(try click(.rightMouseUp))
        try await waitForWanderingCondition(timeout: 15) { menuBar.informationState == .hidden }
        XCTAssertTrue(menuBar.isHoverCoolingDown)
        func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil))
        }
        menuBar.mouseEntered(with: try crossing(.mouseEntered))
        menuBar.showPeek()
        XCTAssertFalse(menuBar.isPeekPinned, "Explicit peek must also respect the cooldown")
        XCTAssertFalse(menuBar.isHoverCharacterVisible)
        try await Task.sleep(for: .milliseconds(400))
        menuBar.mouseExited(with: try crossing(.mouseExited))
        menuBar.mouseEntered(with: try crossing(.mouseEntered))
        XCTAssertTrue(menuBar.isHoverCoolingDown, "Leaving/re-entering must not bypass the deadline")
        XCTAssertFalse(menuBar.isHoverCharacterVisible)
        try await waitForWanderingCondition(timeout: 2) { !menuBar.isHoverCoolingDown }
        // Pin acceptance is independent of the existing asynchronous tail/hover decoder.
        menuBar.showPeek()
        XCTAssertTrue(menuBar.isPeekPinned)
        menuBar.handleStatusClick(try click(.rightMouseUp))
        menuBar.uninstall()
        XCTAssertEqual(menuBar.informationState, .hidden)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(menuBar.isHoverCharacterVisible, "Uninstall cancels cooldown wakeup")
    }

    func testRopeInfoSpaceSwitchRetiresWindowsAndRecreatesOnNextOpen() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = MenuBarInformationController()
        defer { controller.shutdown() }
        let anchor = CGRect(x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.maxY, width: 40, height: 24)
        func reveal() async throws {
            controller.open(anchor: anchor, screen: screen, scale: 0.9)
            try await waitForWanderingCondition(timeout: 15) { controller.state == .descending }
            for _ in 0..<70 { controller.advanceAnimation() }
            try await waitForWanderingCondition(timeout: 15) { controller.state == .showing }
        }
        try await reveal()
        let firstCharacter = try XCTUnwrap(controller.characterPanel)
        let firstCard = try XCTUnwrap(controller.informationPanel)
        for panel in [firstCharacter, firstCard] {
            XCTAssertTrue(panel.collectionBehavior.contains(.moveToActiveSpace))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
            XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenNone))
            XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertFalse(panel.collectionBehavior.contains(.stationary))
            XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenPrimary))
        }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(controller.state, .hidden)
        XCTAssertFalse(firstCharacter.isVisible)
        XCTAssertFalse(firstCard.isVisible)
        XCTAssertNil(controller.characterPanel)
        XCTAssertNil(controller.informationPanel)
        XCTAssertNil(controller.informationView)
        try await reveal()
        XCTAssertFalse(controller.characterPanel === firstCharacter)
        XCTAssertFalse(controller.informationPanel === firstCard)
        XCTAssertTrue(controller.informationPanel?.isVisible == true)
    }

    func testRopeInfoSpaceSwitchCancelsLoadingWithoutLateWindows() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = MenuBarInformationController()
        defer { controller.shutdown() }
        let anchor = CGRect(x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.maxY, width: 40, height: 24)
        controller.open(anchor: anchor, screen: screen, scale: 0.9)
        XCTAssertEqual(controller.state, .loading)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(controller.state, .hidden)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(controller.characterPanel)
        XCTAssertNil(controller.informationPanel)
        XCTAssertEqual(controller.state, .hidden)
        controller.open(anchor: anchor, screen: screen, scale: 0.9)
        try await waitForWanderingCondition(timeout: 15) { controller.state == .descending }
        XCTAssertTrue(controller.characterPanel?.isVisible == true)
    }

    func testExplicitRopeInformationDoesNotDependOnAutomaticPeekPermission() async throws {
        let repository = try SpriteRepository(bundle: .main)
        let menuBar = MenuBarController(repository: repository, metricsSampler: .init(), peekSuppression: { _ in true })
        defer { menuBar.uninstall() }
        menuBar.install(scale: 0.9)
        let hover = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        menuBar.mouseEntered(with: hover)
        XCTAssertFalse(menuBar.isHoverCharacterVisible)
        XCTAssertFalse(menuBar.isPeekPinned)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseUp, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        menuBar.handleStatusClick(click)
        try await waitForWanderingCondition(timeout: 15) { menuBar.informationState == .showing }
        let card = try XCTUnwrap(menuBar.informationController.informationPanel)
        XCTAssertTrue(card.isVisible)
        XCTAssertTrue(card.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(card.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(menuBar.isHoverCharacterVisible)
    }

    func testRopeInfoGeometryStaysOnDisplayAndFormatsUnavailableMetrics() throws {
        let visible = CGRect(x: -1280, y: 50, width: 1280, height: 750)
        let alignment = try XCTUnwrap(MenuBarInformationController().alignment)
        for x in [-1270.0, -640, -80] {
            let frames = MenuBarInformationController.presentationFrames(
                anchor: CGRect(x: x, y: 800, width: 40, height: 24), visibleFrame: visible,
                alignment: alignment, scale: 1)
            XCTAssertTrue(visible.contains(frames.character))
            XCTAssertTrue(visible.contains(frames.card))
        }
        let values = ComputerInformationView.formattedValues(.unavailable)
        XCTAssertEqual(values.count, 5)
        XCTAssertEqual(values[0], "—")
        XCTAssertEqual(values[2], "—")
        XCTAssertEqual(values[3], "—")
        XCTAssertEqual(values[4], "—")
        XCTAssertTrue(values.allSatisfy { !$0.lowercased().contains("nan") && !$0.lowercased().contains("inf") })
    }

    func testStatusIconInputOwnsDragAndPreservesAllClickButtons() throws {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        let input = StatusIconInputView(frame: button.bounds)
        button.addSubview(input)
        XCTAssertTrue(button.hitTest(NSPoint(x: 20, y: 12)) === input,
                      "The icon input must receive events instead of the default button")
        var pointers: [NSEvent.EventType] = []
        var clicks: [NSEvent.EventType] = []
        input.onPointerEvent = { pointers.append($0.type) }
        input.onClick = { clicks.append($0.type) }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                                            timestamp: 0, windowNumber: 0, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        input.mouseDown(with: try event(.leftMouseDown))
        input.mouseDragged(with: try event(.leftMouseDragged))
        input.mouseUp(with: try event(.leftMouseUp))
        input.rightMouseUp(with: try event(.rightMouseUp))
        input.otherMouseUp(with: try event(.otherMouseUp))
        XCTAssertEqual(pointers, [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        XCTAssertEqual(clicks, [.leftMouseUp, .rightMouseUp, .otherMouseUp])
    }
    func testStatusDragCanStartWhileInformationIsOpen() throws {
        let coordinator = try AppCoordinator.make()
        defer { coordinator.stop() }
        let menu = coordinator.menuBar
        menu.install(scale: 1)
        let button = try XCTUnwrap(menu.statusItem?.button)
        let window = try XCTUnwrap(button.window)
        let anchor = try XCTUnwrap(menu.buttonFrameOnScreen)
        let start = CGPoint(x: anchor.midX, y: anchor.midY)
        func pointer(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        menu.showComputerInformation()
        XCTAssertNotEqual(menu.informationState, .hidden)
        menu.trackIconDrag(try pointer(.leftMouseDown, start))
        XCTAssertNotNil(menu.iconDragStart, "An open information card must not disable manual dragging")
        let destination = CGPoint(x: start.x, y: start.y - 140)
        menu.trackIconDrag(try pointer(.leftMouseDragged, destination))
        XCTAssertEqual(coordinator.desktopPets.count, 1)
        XCTAssertEqual(menu.informationState, .hidden)
        menu.trackIconDrag(try pointer(.leftMouseUp, destination))
        XCTAssertNil(coordinator.draggedMenuPet)
        XCTAssertEqual(coordinator.desktopPets.count, 1, "Release must not create another pet")
    }

    func testStatusPointerSamplingDragsWithoutMouseDraggedAndCleansUp() throws {
        let coordinator = try AppCoordinator.make()
        defer { coordinator.stop() }
        let menu = coordinator.menuBar
        menu.install(scale: 1)
        XCTAssertNotNil(menu.iconPointerTimer)
        let anchor = try XCTUnwrap(menu.buttonFrameOnScreen)
        let start = CGPoint(x: anchor.midX, y: anchor.midY)
        // Holding a button elsewhere and then entering the icon must not start a pet.
        menu.sampleIconPointer(at: start, leftButtonDown: true, mayBegin: false)
        menu.sampleIconPointer(at: start, leftButtonDown: true, mayBegin: true)
        XCTAssertNil(menu.iconDragStart)
        menu.sampleIconPointer(at: start, leftButtonDown: false, mayBegin: false)
        menu.sampleIconPointer(at: start, leftButtonDown: true, mayBegin: true)
        XCTAssertNotNil(menu.iconDragStart)
        menu.sampleIconPointer(at: CGPoint(x: start.x, y: start.y - 5), leftButtonDown: true, mayBegin: false)
        XCTAssertTrue(coordinator.desktopPets.isEmpty, "Click jitter must not create a pet")
        let destination = CGPoint(x: start.x, y: start.y - 160)
        menu.sampleIconPointer(at: destination, leftButtonDown: true, mayBegin: false)
        XCTAssertEqual(coordinator.desktopPets.count, 1)
        menu.sampleIconPointer(at: destination, leftButtonDown: false, mayBegin: false)
        XCTAssertNil(coordinator.draggedMenuPet)
        XCTAssertNil(menu.iconDragStart)
        XCTAssertEqual(coordinator.desktopPets.count, 1)
        // A second real press starts a separate pet, without any mouseDragged event.
        menu.sampleIconPointer(at: start, leftButtonDown: true, mayBegin: true)
        menu.sampleIconPointer(at: destination, leftButtonDown: true, mayBegin: false)
        menu.sampleIconPointer(at: destination, leftButtonDown: false, mayBegin: false)
        XCTAssertEqual(coordinator.desktopPets.count, 2)
        menu.uninstall()
        XCTAssertNil(menu.iconPointerTimer)
        XCTAssertNil(menu.iconDragStart)
    }

}
