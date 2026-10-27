import AppKit
import QuartzCore
import WhaleCore
import XCTest
@testable import WhaleGirl

extension WhaleGirlAppTests {
    func testWanderingOccursAfterExactlyZeroThroughThreeCompletedActions() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for count in 0...3 {
            let view = PetView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), repository: repository,
                autonomy: .init(drawActionCount: { count }, idleDelay: 0.02...0.02, finishedPoseDelay: 0.02))
            var walks = 0
            var observed = [count]
            view.onRequestWander = {
                XCTAssertEqual(view.randomActionsUntilWalk, 0)
                walks += 1
            }
            view.play("full.idle")
            let deadline = Date().addingTimeInterval(8)
            while walks == 0, Date() < deadline {
                if observed.last != view.randomActionsUntilWalk { observed.append(view.randomActionsUntilWalk) }
                try await Task.sleep(for: .milliseconds(5))
            }
            if observed.last != view.randomActionsUntilWalk { observed.append(view.randomActionsUntilWalk) }
            XCTAssertEqual(walks, 1, "Must reach one walk for a count of \(count)")
            XCTAssertEqual(observed, Array(stride(from: count, through: 0, by: -1)))
            XCTAssertTrue(view.isWandering)
            view.finishAutonomousWalk()
            XCTAssertEqual(view.randomActionsUntilWalk, count, "A finished outing draws a new count")
            view.pauseAnimation()
            view.onRequestWander = nil
        }
    }

    func testWanderingIsInterruptedByInteractionManualPlaybackAndPause() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), repository: repository,
            autonomy: .init(drawActionCount: { 0 }, idleDelay: 0.02...0.02, finishedPoseDelay: 0.02))
        defer { view.pauseAnimation() }
        var requests = 0, cancels = 0
        view.onRequestWander = { requests += 1 }
        view.onCancelWander = { cancels += 1 }
        view.play("full.idle")
        try await waitForWanderingCondition { view.isWandering }
        view.beginUserInteraction()
        XCTAssertFalse(view.isWandering)
        XCTAssertEqual(cancels, 1)
        let stoppedAt = requests
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests, stoppedAt)
        view.endUserInteraction()
        try await waitForWanderingCondition { view.isWandering }
        view.onContextMenu = { _ in
            XCTAssertTrue(view.isUserInteracting)
            XCTAssertFalse(view.isWandering)
        }
        let right = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.rightMouseDown(with: right)
        try await waitForWanderingCondition { view.isWandering }
        view.play("full.community.manual", looping: false)
        XCTAssertFalse(view.isWandering)
        XCTAssertEqual(view.currentClipID, "full.community.manual")
        try await waitForWanderingCondition { view.isWandering }
        view.pauseAnimation()
        XCTAssertFalse(view.isWandering)
        let pausedAt = requests
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests, pausedAt)
        view.resumeAnimation()
        try await waitForWanderingCondition { view.isWandering }
    }

    func testWanderingMirrorsClickPixelsWithTheCharacter() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = await repository.prepareClip("full.walk")
        XCTAssertTrue(ready)
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), repository: repository)
        defer { view.pauseAnimation() }
        view.play("full.walk", looping: true)
        view.layoutSubtreeIfNeeded()
        let left = CGPoint(x: 10, y: 50), right = CGPoint(x: 90, y: 50)
        XCTAssertTrue(view.containsCharacter(at: left))
        XCTAssertFalse(view.containsCharacter(at: right))
        view.setWalkingDirection(toRight: true)
        XCTAssertFalse(view.containsCharacter(at: left))
        XCTAssertTrue(view.containsCharacter(at: right))
        view.setWalkingDirection(toRight: false)
        XCTAssertTrue(view.containsCharacter(at: left))
    }

    func testWanderingMovesWithinScreenAndStopsOnDragAndHide() async throws {
        let (repository, root) = try wanderingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = RoamPanelController(repository: repository,
            autonomy: .init(drawActionCount: { 0 }, idleDelay: 0.02...0.02, finishedPoseDelay: 0.02))
        defer { controller.hide() }
        controller.show(centeredAt: CGPoint(x: screen.visibleFrame.maxX, y: screen.visibleFrame.maxY),
                        screen: screen, scale: 1, clipID: "full.idle")
        let view = try XCTUnwrap(controller.petView)
        let panel = try XCTUnwrap(controller.panel)
        try await waitForWanderingCondition { view.isWandering }
        let start = panel.frame
        controller.advanceWander(at: CACurrentMediaTime() + 100)
        XCTAssertNotEqual(panel.frame.origin, start.origin)
        XCTAssertTrue(screen.visibleFrame.contains(panel.frame))
        XCTAssertFalse(view.isWandering)
        try await waitForWanderingCondition { view.isWandering }
        view.beginUserInteraction()
        let stopped = panel.frame
        controller.advanceWander(at: CACurrentMediaTime() + 100)
        XCTAssertEqual(panel.frame, stopped)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(panel.frame, stopped)
        view.endUserInteraction()
        try await waitForWanderingCondition { view.isWandering }
        controller.hide()
        let hidden = panel.frame
        controller.advanceWander(at: CACurrentMediaTime() + 100)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.frame, hidden)
    }

    func testStationaryActionsAreUniqueAcrossFiveCharactersAndManualRequests() async throws {
        let repository = try SpriteRepository(bundle: .main)
        let preferred = repository.resolvedClipID("full.idle")
        let ready = await repository.prepareClip(preferred)
        XCTAssertTrue(ready)
        let views = (0..<5).map { _ in PetView(frame: CGRect(x: 0, y: 0, width: 240, height: 135),
            repository: repository, autonomy: .init(drawActionCount: { 3 }, idleDelay: 30...30)) }
        defer { views.forEach { $0.pauseAnimation(); $0.releaseStationaryAction() } }
        for view in views { view.play("full.idle"); view.beginUserInteraction() }
        XCTAssertEqual(Set(views.map(\.currentClipID)).count, 1)
        let action = try XCTUnwrap(repository.communityActions.first { $0.clipID != preferred })
        for view in views { view.play(action.clipID, looping: false) }
        XCTAssertEqual(Set(views.map(\.currentClipID)).count, 5)
        let firstID = views[0].currentClipID
        views[1].play(firstID, looping: false)
        XCTAssertNotEqual(views[1].currentClipID, firstID)
        XCTAssertEqual(Set(views.map(\.currentClipID)).count, 5)
        views[0].releaseStationaryAction()
        views[1].play(firstID, looping: false)
        XCTAssertEqual(views[1].currentClipID, firstID)
    }

    func testActionReservationsProtectOutgoingTexturesAndReleaseDeadOwners() throws {
        let repository = try SpriteRepository(bundle: .main)
        let ids = Array(repository.communityActions.prefix(3).map(\.clipID))
        var first: NSObject? = NSObject()
        let second = NSObject()
        XCTAssertEqual(repository.claimStationaryAction(ids[0], candidates: [], owner: first!), ids[0])
        XCTAssertEqual(repository.claimStationaryAction(ids[1], candidates: [], owner: first!), ids[1])
        XCTAssertNil(repository.claimStationaryAction(ids[0], candidates: [ids[1]], owner: second))
        repository.retainStationaryAction(ids[1], owner: first!)
        XCTAssertEqual(repository.claimStationaryAction(ids[0], candidates: [], owner: second), ids[0])
        first = nil
        XCTAssertEqual(repository.claimStationaryAction(ids[1], candidates: [], owner: second), ids[1])
        let idleOwner = NSObject(), returnOwner = NSObject()
        let idle = repository.resolvedClipID("full.idle")
        XCTAssertEqual(repository.claimStationaryAction(idle, candidates: [], owner: idleOwner), idle)
        XCTAssertNil(repository.claimStationaryAction("full.community.return", candidates: [], owner: returnOwner))
    }
}
