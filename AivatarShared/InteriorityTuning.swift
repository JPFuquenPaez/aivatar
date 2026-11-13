import Foundation

/// Interiority tuning (A5d): the persistent traces the companion keeps —
/// fed from CompanionMemory at context build, NOT from the engine clock
/// (determinism: memory is an input, like the seed). Neutral by default
/// so untuned renders (tests, previews) match the pinned look exactly.
/// (Moved to AivatarShared in v36 so the iPhone shell compiles the same
/// sprite core as the watch.)
nonisolated struct InteriorityTuning: Sendable {
    /// Willow's tended sprout: 0.2 (just sprouted) ... 1.0 (mature).
    /// 1.0 = the A5a look; scales the soil pod and the sprout leaf.
    var sproutGrowth: Float = 1
    /// Compass's audit artifact: the week grid. 0 hides it (default);
    /// 1-7 lights `streakDays` cells and dims the rest — order made
    /// visible, the tidy artifact waiting for you.
    var streakDays: Int = 0
    /// Prism's found trinket: the day's small discovery, presented on
    /// return. Hidden by default.
    var trinketPresent = false
    /// v16 F1 level 5 ("confidant"): the companion keeps a small pixel
    /// memento of the naming day — one accent cell below the body.
    var confidantMemento = false

    static let `default` = InteriorityTuning()
}
