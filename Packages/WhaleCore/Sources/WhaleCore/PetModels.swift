import Foundation

public enum PresentationMode: String, Codable, CaseIterable, Sendable {
    case mini
    case peeking
    case interacting
    case roaming
    case returning
    case hidden
}

public enum PetMood: String, Codable, CaseIterable, Sendable {
    case calm
    case curious
    case playful
    case annoyed
}

public struct PetState: Equatable, Sendable {
    public var mode: PresentationMode
    public var mood: PetMood
    public var pokeCount: Int

    public init(mode: PresentationMode = .mini, mood: PetMood = .calm, pokeCount: Int = 0) {
        self.mode = mode
        self.mood = mood
        self.pokeCount = pokeCount
    }
}

public enum PetInteraction: Equatable, Sendable {
    case statusTapped
    case headPetted
    case facePoked
    case dragStarted
    case draggedDown(distance: Double)
    case dragEnded
    case returnFinished
    case idleTimedOut
    case dismissRequested
}

public enum PetEffect: Equatable, Sendable {
    case showPeek
    case showFull
    case hideOverlays
    case returnToMenuBar
    case play(String)
    case say(String)
}

public struct PetInteractionReducer: Sendable {
    public init() {}

    public func reduce(state: inout PetState, interaction: PetInteraction) -> [PetEffect] {
        switch interaction {
        case .statusTapped:
            if state.mode == .mini || state.mode == .hidden {
                state.mode = .peeking
                state.mood = .curious
                return [.showPeek]
            }
            state.mode = .mini
            state.mood = .calm
            return [.hideOverlays]

        case .headPetted:
            state.mood = .playful
            return [.play(state.mode == .interacting ? "full.happy" : "peek.happy"), .say("再摸一下也可以～")]

        case .facePoked:
            state.pokeCount += 1
            state.mood = state.pokeCount >= 3 ? .annoyed : .playful
            let line = state.pokeCount >= 3 ? "再戳我要生气了！" : "不许戳脸！"
            return [.play(state.mode == .interacting ? "full.poke" : "peek.poke"), .say(line)]

        case .dragStarted:
            return []

        case let .draggedDown(distance):
            guard state.mode == .peeking, distance >= 28 else { return [] }
            state.mode = .interacting
            state.mood = .curious
            return [.showFull, .play("full.dragged"), .say("要带我去哪里？")]

        case .dragEnded:
            guard state.mode == .interacting else { return [] }
            state.mode = .returning
            state.mood = .calm
            return [.returnToMenuBar]

        case .returnFinished:
            guard state.mode == .returning else { return [] }
            state.mode = .peeking
            return [.showPeek]

        case .idleTimedOut:
            guard state.mode == .peeking else { return [] }
            state.mode = .mini
            state.mood = .calm
            return [.hideOverlays]

        case .dismissRequested:
            state.mode = .mini
            state.mood = .calm
            return [.hideOverlays]
        }
    }
}
