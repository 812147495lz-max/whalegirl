import AppKit
import QuartzCore
import WhaleCore
import XCTest
@testable import WhaleGirl

extension WhaleGirlAppTests {
    func testSpeechBubbleFitsShortTextAndWrapsLongText() throws {
        let repository = try SpriteRepository(bundle: .main)
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 360, height: 220), repository: repository)
        view.say("你好")
        let bubble = try XCTUnwrap(view.subviews.first { $0.identifier?.rawValue == "character.speech-bubble" })
        let short = bubble.frame.size
        XCTAssertLessThan(short.width, 100)
        view.say("在看什么？")
        XCTAssertGreaterThan(bubble.frame.width, short.width)
        view.say(String(repeating: "鲸鱼娘陪你工作，", count: 8))
        XCTAssertLessThanOrEqual(bubble.frame.width, 240)
        XCTAssertGreaterThan(bubble.frame.height, short.height)
        XCTAssertEqual(bubble.frame.midX, view.bounds.midX, accuracy: 0.5)
    }

    func testVisibleDialogueWindowsAcrossBothSkinsWithRenderedEvidence() async throws {
        let domain = "io.whalegirl.tests.visible-dialogue.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let repository = try SpriteRepository(bundle: .main, defaults: defaults)
        let screen = try XCTUnwrap(NSScreen.main)
        let pets = (0..<2).map { _ in RoamPanelController(repository: repository,
            autonomy: .init(drawActionCount: { 3 }, idleDelay: 60...60)) }
        defer { pets.forEach { $0.hide() } }
        for (index, pet) in pets.enumerated() {
            pet.show(centeredAt: CGPoint(x: screen.visibleFrame.midX + Double(index * 320 - 160),
                                        y: screen.visibleFrame.midY), screen: screen, scale: 1, clipID: "full.idle")
            pet.petView?.beginUserInteraction()
        }
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        func label(_ view: PetView) throws -> NSTextView {
            let bubble = try XCTUnwrap(view.subviews.first { $0.identifier?.rawValue == "character.speech-bubble" })
            return try XCTUnwrap(bubble.subviews.compactMap { $0 as? NSTextView }.first)
        }
        func capture(_ view: PetView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            view.window?.displayIfNeeded()
            CATransaction.flush()
            try attachSnapshot(of: view, named: name)
        }
        for skin in SpriteRepository.Skin.allCases {
            if repository.selectSkin(skin) { pets.forEach { $0.petView?.refreshSkin() } }
            let views = try pets.map { try XCTUnwrap($0.petView) }
            let expected = try XCTUnwrap(repository.clip("full.idle"))
            let ready = await repository.prepareClip(expected.id)
            XCTAssertTrue(ready)
            let texture = try XCTUnwrap(repository.cgImage(atlasID: expected.atlasID))
            try await waitForWanderingCondition(timeout: 15) {
                pets.allSatisfy(\.isVisible) && views.allSatisfy {
                    ($0.layer?.sublayers?.first?.contents as AnyObject?) === texture
                }
            }
            for round in 0..<3 {
                views.forEach { $0.mouseEntered(with: event) }
                let lines = try views.map { try label($0).string }
                XCTAssertNotEqual(lines[0], lines[1])
                XCTAssertTrue(lines.allSatisfy { DeepSeekChanDialog.lines.contains($0) })
                for (index, view) in views.enumerated() {
                    try capture(view, name: "\(skin.rawValue)-random-\(round)-pet-\(index)")
                }
                views.forEach { $0.mouseExited(with: event) }
            }
            views[0].say("在看什么？")
            views[1].say("事情可以慢慢想，饭要趁热吃。主人放心，尾巴摇着，脑子也没停。")
            for (index, view) in views.enumerated() {
                try capture(view, name: "\(skin.rawValue)-regression-pet-\(index)")
            }
        }
    }

    func testSpeechBubbleLaysOutEveryCharacterAtSmallAndNormalSizes() throws {
        let repository = try SpriteRepository(bundle: .main)
        let lines = ["在看什么？", "你好", "你好🐋，Token 余额还有多少？"] + DeepSeekChanDialog.lines
        for width in [80.0, 150, 266, 360] {
            let view = PetView(frame: CGRect(x: 0, y: 0, width: width, height: 220), repository: repository)
            for line in lines {
                view.say(line)
                let bubble = try XCTUnwrap(view.subviews.first { $0.identifier?.rawValue == "character.speech-bubble" })
                let text = try XCTUnwrap(bubble.subviews.compactMap { $0 as? NSTextView }.first)
                let manager = try XCTUnwrap(text.layoutManager)
                let container = try XCTUnwrap(text.textContainer)
                manager.ensureLayout(for: container)
                let laidOut = manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil)
                XCTAssertEqual(laidOut, NSRange(location: 0, length: (line as NSString).length), line)
                XCTAssertLessThanOrEqual(manager.usedRect(for: container).maxY, text.bounds.height, line)
                XCTAssertLessThanOrEqual(manager.usedRect(for: container).maxX, text.bounds.width + 0.5, line)
                XCTAssertTrue(bubble.bounds.contains(text.frame), line)
                XCTAssertLessThanOrEqual(bubble.frame.maxY, view.bounds.height)
            }
        }
    }

    func testDesktopHoverUsesRandomDialogueWithoutConsecutiveRepeats() throws {
        let repository = try SpriteRepository(bundle: .main)
        let views = (0..<2).map { _ in PetView(frame: CGRect(x: 0, y: 0, width: 266, height: 150), repository: repository) }
        defer { views.forEach { $0.pauseAnimation(); $0.releaseStationaryAction() } }
        views.forEach { $0.play("full.idle"); $0.beginUserInteraction() }
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        var previous: String?
        for index in 0..<20 {
            let view = views[index % 2]
            view.mouseEntered(with: event)
            let bubble = try XCTUnwrap(view.subviews.first { $0.identifier?.rawValue == "character.speech-bubble" })
            let text = try XCTUnwrap(bubble.subviews.compactMap { $0 as? NSTextView }.first)
            XCTAssertTrue(DeepSeekChanDialog.lines.contains(text.string))
            XCTAssertNotEqual(text.string, previous)
            XCTAssertFalse(bubble.isHidden)
            previous = text.string
            view.mouseExited(with: event)
            XCTAssertTrue(bubble.isHidden)
        }
    }
}
