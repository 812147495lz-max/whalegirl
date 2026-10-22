import Testing
@testable import WhaleCore

struct InteractionReducerTests {
    @Test func opensPeekAndReturnsFromFull() {
        let reducer = PetInteractionReducer()
        var state = PetState()

        #expect(reducer.reduce(state: &state, interaction: .statusTapped) == [.showPeek])
        #expect(state.mode == .peeking)
        #expect(reducer.reduce(state: &state, interaction: .draggedDown(distance: 28)).contains(.showFull))
        #expect(state.mode == .interacting)
        #expect(reducer.reduce(state: &state, interaction: .dragEnded) == [.returnToMenuBar])
        #expect(state.mode == .returning)
        #expect(reducer.reduce(state: &state, interaction: .returnFinished) == [.showPeek])
        #expect(state.mode == .peeking)
    }

    @Test func shortDragDoesNotOpenFull() {
        let reducer = PetInteractionReducer()
        var state = PetState(mode: .peeking)
        #expect(reducer.reduce(state: &state, interaction: .draggedDown(distance: 27.9)).isEmpty)
        #expect(state.mode == .peeking)
    }

    @Test func petAndPokeHaveDistinctFeedback() {
        let reducer = PetInteractionReducer()
        var state = PetState(mode: .peeking)
        let pet = reducer.reduce(state: &state, interaction: .headPetted)
        let poke = reducer.reduce(state: &state, interaction: .facePoked)
        #expect(pet != poke)
        #expect(poke.contains(.say("不许戳脸！")))
        _ = reducer.reduce(state: &state, interaction: .facePoked)
        let thirdPoke = reducer.reduce(state: &state, interaction: .facePoked)
        #expect(thirdPoke.contains(.say("再戳我要生气了！")))
    }

    @Test func peekReturnsToMiniAfterIdleTimeout() {
        let reducer = PetInteractionReducer()
        var state = PetState(mode: .peeking, mood: .curious)

        #expect(reducer.reduce(state: &state, interaction: .idleTimedOut) == [.hideOverlays])
        #expect(state.mode == .mini)
        #expect(state.mood == .calm)
    }

    @Test func explicitDismissClosesEitherOverlay() {
        let reducer = PetInteractionReducer()
        var peekState = PetState(mode: .peeking, mood: .curious)
        var fullState = PetState(mode: .interacting, mood: .playful)

        #expect(reducer.reduce(state: &peekState, interaction: .dismissRequested) == [.hideOverlays])
        #expect(peekState.mode == .mini)
        #expect(reducer.reduce(state: &fullState, interaction: .dismissRequested) == [.hideOverlays])
        #expect(fullState.mode == .mini)
    }
}
