import AppKit
import QuartzCore
import WhaleCore
import XCTest
@testable import WhaleGirl

extension WhaleGirlAppTests {
    func testAgentBirthWaitsTwoSecondsAndClaimsDistinctActions() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Contents/Resources/CommunityActions/catalog.json")
        // Reload a fresh repository with two real fixture action slots.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        var actions = try XCTUnwrap(object["actions"] as? [[String: String]])
        actions.append(["clipID": "full.community.manual", "title": "检查", "category": "测试"])
        object["actions"] = actions
        try JSONSerialization.data(withJSONObject: object).write(to: catalog)
        let manifestURL = catalog.deletingLastPathComponent().appendingPathComponent("sprite-manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var atlases = try XCTUnwrap(manifest["atlases"] as? [[String: Any]])
        var separateAtlas = atlases[0]; separateAtlas["id"] = "community.manual"
        atlases.append(separateAtlas); manifest["atlases"] = atlases
        var clips = try XCTUnwrap(manifest["clips"] as? [[String: Any]])
        for index in clips.indices where clips[index]["id"] as? String == "full.community.manual" { clips[index]["atlasID"] = "community.manual" }
        manifest["clips"] = clips
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let available = try SpriteRepository(bundle: XCTUnwrap(Bundle(url: root)))
        var autonomy = PetView.AutonomyConfiguration()
        autonomy.agentBirthDelay = 2; autonomy.idleDelay = 100...100; autonomy.finishedPoseDelay = 100
        let first = PetView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), repository: available, autonomy: autonomy)
        let second = PetView(frame: first.frame, repository: available, autonomy: autonomy)
        defer { first.pauseAnimation(); second.pauseAnimation(); first.releaseStationaryAction(); second.releaseStationaryAction() }
        for (index, view) in [first, second].enumerated() {
            view.play("full.idle")
            view.beginAgentLife(introduction: "子代理 \(index) 报到")
        }
        try await Task.sleep(for: .milliseconds(1800))
        XCTAssertEqual(first.currentClipID, "full.community.idle")
        XCTAssertEqual(second.currentClipID, "full.community.idle")
        try await waitForWanderingCondition(timeout: 4) {
            first.currentClipID != "full.community.idle" && second.currentClipID != "full.community.idle"
        }
        XCTAssertNotEqual(first.currentClipID, second.currentClipID)
        _ = repository // Preserve the fixture producer until the test has finished.
    }

    func testAngelDepartureRendersFeatherAndHalo() async throws {
        let domain = "WhaleGirl.AngelPreview." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let repository = try SpriteRepository(bundle: .main, defaults: defaults)
        _ = repository.selectSkin(.classic)
        let ready = await repository.prepareClip("full.idle")
        XCTAssertTrue(ready)
        let view = PetView(frame: NSRect(x: 0, y: 0, width: 300, height: 350), repository: repository)
        view.play("full.idle"); view.pauseAnimation(); view.layoutSubtreeIfNeeded()
        defer { view.cancelAngelDeparture(); view.pauseAnimation() }
        _ = view.beginAngelDeparture(duration: 3.6, reducedMotion: false)
        let mask = try XCTUnwrap(view.agentDepartureMask)
        let animation = try XCTUnwrap(mask.animation(forKey: "featheredDeparture") as? CABasicAnimation)
        let start = try XCTUnwrap(animation.fromValue as? Double)
        let end = try XCTUnwrap(animation.toValue as? Double)
        let image = try XCTUnwrap(mask.contents) as! CGImage
        let bytes = try XCTUnwrap(image.dataProvider?.data)
        let pointer = try XCTUnwrap(CFDataGetBytePtr(bytes))
        func alpha(_ x: Int, _ row: Int) -> UInt8 { pointer[row * image.bytesPerRow + x * 4 + 3] }
        let middle = image.width / 2, side = image.width / 4
        let centerBoundary = try XCTUnwrap((0..<image.height).first { alpha(middle, $0) >= 128 })
        let sideBoundary = try XCTUnwrap((0..<image.height).first { alpha(side, $0) >= 128 })
        XCTAssertGreaterThan(centerBoundary, sideBoundary, "The lip bows downward in the center rather than being a straight line")
        XCTAssertGreaterThan((0..<image.height).filter { alpha(middle, $0) > 0 && alpha(middle, $0) < 255 }.count, 12, "A feathered transition must span many pixels")
        mask.removeAllAnimations()
        for (index, progress) in [0.0, 0.5, 1.0].enumerated() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            mask.position.y = start + (end - start) * progress
            CATransaction.commit(); CATransaction.flush()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/whale-angel-\(index).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "angel-wipe-\(index)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testAgentAscendsAfterFarewellAndWorkingCancelsAscent() async throws {
        await FullScreenAvoidance.shared.waitForInitialSnapshot()
        let repository = try SpriteRepository(bundle: .main)
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = RoamPanelController(repository: repository)
        controller.show(centeredAt: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY), screen: screen, scale: 1, clipID: "full.idle")
        defer { controller.hide() }
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertTrue(controller.isVisible)
        let origin = panel.frame.origin
        var closes = 0
        controller.completeAgentDeparture { closes += 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(closes, 0, "Departure must animate instead of closing immediately")
        controller.cancelAgentDeparture()
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(closes, 0, "Resumed work cancels a queued close")
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(panel.frame.minY, origin.y, accuracy: 1)
        XCTAssertNil(controller.petView?.agentDepartureMask)
        XCTAssertNil(controller.petView?.agentHalo)
        controller.completeAgentDeparture { closes += 1 }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let mask = try XCTUnwrap(controller.petView?.agentDepartureMask)
            let animation = try XCTUnwrap(mask.animation(forKey: "featheredDeparture") as? CABasicAnimation)
            let from = try XCTUnwrap(animation.fromValue as? Double)
            let to = try XCTUnwrap(animation.toValue as? Double)
            XCTAssertEqual(animation.duration, 3.6)
            XCTAssertEqual(mask.name, "agent.departure.curvedFeather")
            XCTAssertNotNil(mask.contents)
            let halo = try XCTUnwrap(controller.petView?.agentHalo)
            XCTAssertGreaterThan(halo.shadowRadius, 0)
            XCTAssertTrue(controller.petView?.layer?.mask === mask, "The halo and body share the erase mask")
            try await Task.sleep(for: .seconds(1.8))
            XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01, "Normal departure erases spatially, never fades the whole pet")
            XCTAssertEqual(closes, 0)
            try await Task.sleep(for: .seconds(2.1))
            XCTAssertEqual(panel.frame.minY - origin.y, from - to, accuracy: 1, "Rise and wipe cover identical distances in the same duration")
        } else {
            try await Task.sleep(for: .seconds(0.5))
            XCTAssertEqual(panel.alphaValue, 0, accuracy: 0.01)
        }
        XCTAssertEqual(closes, 1)
    }

    func testClassicFarewellIsExactSharedAndResumeCancelsClose() async throws {
        let repository = try SpriteRepository(bundle: .main)
        let old = repository.selectedSkin; _ = repository.selectSkin(.classic)
        defer { _ = repository.selectSkin(old) }
        let wave = RoamPanelController.classicFarewell
        let clip = try XCTUnwrap(repository.clip(wave))
        XCTAssertEqual(clip.frames.count, 120)
        XCTAssertEqual(clip.frames.reduce(0) { $0 + $1.duration }, 10, accuracy: 0.01)
        let ready = await repository.prepareClip(wave)
        XCTAssertTrue(ready)
        let first = PetView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), repository: repository)
        let second = PetView(frame: first.frame, repository: repository)
        defer { first.pauseAnimation(); second.pauseAnimation() }
        first.play(wave, looping: false, allowSharedAction: true)
        second.play(wave, looping: false, allowSharedAction: true)
        XCTAssertEqual(first.currentClipID, wave)
        XCTAssertEqual(second.currentClipID, wave)
        let controller = AgentCompanionController()
        var resumed = 0; controller.onResumed = { _ in resumed += 1 }
        let now = Date()
        func event(_ kind: String, _ offset: Double) -> WhaleEvent {
            .init(source: .dsh, sourceInstance: "fixture", sessionId: "child", parentSessionId: "root",
                  eventType: kind, occurredAt: now.addingTimeInterval(offset), severity: .info,
                  metadata: ["agentLabel": "检查设置页面"])
        }
        controller.receive(event("agent.working", 0))
        controller.receive(event("agent.session_completed", 1))
        controller.receive(event("agent.working", 2))
        XCTAssertEqual(resumed, 1)
        XCTAssertNil(controller.roster.entries.values.first?.retireAt)
        XCTAssertEqual(controller.labels.values.first, "检查设置页面")
        controller.closeAll()
    }

    func testAgentCompanionCallbacksAreIdempotentAndToggleOnlyClosesOwnedAgents() {
        let controller = AgentCompanionController()
        var spawned: [String] = [], spoken: [String] = [], closed: [String] = []
        controller.onSpawn = { spawned.append($0) }
        controller.onFinished = { key, success in if success { spoken.append(key) } }
        controller.onClose = { closed.append($0) }
        let now = Date()
        func event(_ id: String, _ type: String, parent: String? = "root") -> WhaleEvent {
            .init(source: .dsh, sourceInstance: "fixture", sessionId: id, parentSessionId: parent,
                  eventType: type, occurredAt: now, severity: .info)
        }
        controller.receive(event("root", "agent.working", parent: nil))
        controller.receive(event("a", "agent.session_started"))
        controller.receive(event("a", "agent.working"))
        controller.receive(event("b", "agent.session_started"))
        XCTAssertEqual(spawned.count, 3)
        controller.receive(event("a", "agent.session_completed"))
        controller.receive(event("a", "agent.session_completed"))
        XCTAssertEqual(spoken.count, 1)
        let entry = controller.roster.entries[spoken[0]]!
        XCTAssertTrue((10...20).contains(entry.retireAt!.timeIntervalSince(entry.lastSeen)))
        controller.setEnabled(false)
        XCTAssertEqual(Set(closed), Set(spawned))
        controller.receive(event("c", "agent.session_started"))
        XCTAssertEqual(spawned.count, 3)
        controller.setEnabled(true)
        controller.receive(event("c", "agent.session_started"))
        XCTAssertEqual(spawned.count, 4)
        controller.closeAll()
    }

    func testAgentCompanionRecoversFreshDSHTerminalWithoutStart() {
        let controller = AgentCompanionController()
        var spawned = 0, spoken = 0
        controller.onSpawn = { _ in spawned += 1 }
        controller.onFinished = { _, _ in spoken += 1 }
        let ended = Date().addingTimeInterval(-2)
        let event = WhaleEvent(source: .dsh, sourceInstance: "recovery-fixture", sessionId: "missing-start", parentSessionId: "parent",
            eventType: "agent.session_completed", occurredAt: ended, severity: .info, metadata: ["client":"dsh-whale-status"])
        controller.receive(event)
        XCTAssertEqual(spawned, 1)
        XCTAssertEqual(spoken, 1)
        let key = AgentCompanionRoster.key(for: event)!
        XCTAssertTrue((10...20).contains(controller.roster.entries[key]!.retireAt!.timeIntervalSince(ended)))
        controller.closeAll()
    }

    func testReplyCompletionUsesPeekSpeechForTenSecondsAndArrow() async throws {
        let repository = try SpriteRepository(bundle: .main)
        let suppressed = MenuBarController(repository: repository, metricsSampler: .init(), peekSuppression: { _ in true })
        suppressed.install(scale: 0.9)
        suppressed.showReplyCompletion(sourceName: "Grok")
        XCTAssertFalse(suppressed.isCompletionPeekActive)
        suppressed.uninstall()
        let menuBar = MenuBarController(repository: repository, metricsSampler: .init(), peekSuppression: { _ in false })
        defer { menuBar.uninstall() }
        menuBar.install(scale: 0.9)
        menuBar.showReplyCompletion(sourceName: "Codex")
        try await waitForWanderingCondition(timeout: 20) { menuBar.completionSpeechLine == "Codex 回复完成啦" && menuBar.isHoverCharacterVisible }
        let speech = try XCTUnwrap(menuBar.completionSpeechPanel)
        XCTAssertTrue(speech.isVisible)
        XCTAssertTrue(speech.ignoresMouseEvents)
        XCTAssertTrue(speech.collectionBehavior.contains(.fullScreenNone))
        // Notification ownership survives mouse enter/exit and the next wink.
        func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        menuBar.mouseEntered(with: try crossing(.mouseEntered))
        menuBar.mouseExited(with: try crossing(.mouseExited))
        menuBar.showReplyCompletion(sourceName: "Gemini")
        menuBar.showReplyCompletion(sourceName: "Codex")
        try await waitForWanderingCondition { menuBar.completionSpeechLine == "Codex、Gemini 回复完成啦" }
        try await Task.sleep(for: .milliseconds(400))
        let bubble = try XCTUnwrap(speech.contentView as? HoverSpeechBubbleView)
        bubble.layoutSubtreeIfNeeded(); bubble.displayIfNeeded()
        let path = HoverSpeechBubbleView.bubblePath(in: bubble.bounds.insetBy(dx: 0.5, dy: 0.5), tailX: bubble.tailX)
        XCTAssertTrue(path.contains(CGPoint(x: bubble.tailX, y: bubble.bounds.maxY - 2)))
        XCTAssertFalse(path.contains(CGPoint(x: bubble.bounds.midX - 18, y: bubble.bounds.maxY - 2)))
        if let bitmap = bubble.bitmapImageRepForCachingDisplay(in: bubble.bounds) {
            bubble.cacheDisplay(in: bubble.bounds, to: bitmap)
            let image = NSImage(size: bubble.bounds.size); image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image); attachment.name = "peek-reply-arrow"; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await Task.sleep(for: .seconds(9))
        XCTAssertTrue(menuBar.isHoverCharacterVisible)
        XCTAssertTrue(menuBar.isCompletionPeekActive)
        XCTAssertTrue(speech.isVisible)
        try await waitForWanderingCondition(timeout: 4) { !menuBar.isHoverCharacterVisible && !menuBar.isCompletionPeekActive }
        try await waitForWanderingCondition { !speech.isVisible }
        menuBar.showReplyCompletion(sourceName: "Claude Code")
        try await waitForWanderingCondition(timeout: 4) { menuBar.isHoverCharacterVisible }
        menuBar.uninstall()
        XCTAssertFalse(menuBar.isCompletionPeekActive)
        XCTAssertFalse(speech.isVisible)
    }
}
