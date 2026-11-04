import Foundation

/// The live avatar's app-side registration point (§3 App Shell / §13 ports).
/// The stage owns the engine AND the sprite director (v13: the authored
/// sprite stage is the live path; the engine stays registered for the
/// vector fallback and engine-side consumers); anything that needs to feed
/// events (notification bridge, Phase B interaction sources) resolves them
/// here. @MainActor: the engine is main-thread UI-adjacent by design (§7).
@MainActor
final class AvatarSession {
    static let shared = AvatarSession()

    private init() {}

    /// Weak: the stage's render context outlives registration; the engine
    /// is never retained beyond the stage's lifetime.
    private(set) weak var context: AvatarRenderContext?
    private(set) weak var spriteDirector: SpriteDirector?
    private(set) var archetype: Archetype = .ember

    func register(context: AvatarRenderContext, director: SpriteDirector, archetype: Archetype) {
        self.context = context
        self.spriteDirector = director
        self.archetype = archetype
    }

    func unregister(context: AvatarRenderContext) {
        if self.context === context {
            self.context = nil
        }
    }

    /// Single delivery path into the live avatar (§13): taps, crown ticks
    /// and notification reactions all land here — fanned out to the engine
    /// (dormant live, still the vector owner) and the v13 sprite director
    /// (the stage's actor).
    func handle(_ event: AvatarEvent) {
        context?.engine.handleEvent(event)
        spriteDirector?.handleEvent(event)
    }
}
