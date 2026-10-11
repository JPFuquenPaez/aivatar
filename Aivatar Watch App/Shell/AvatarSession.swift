import Foundation

/// The live avatar's app-side registration point (§3 App Shell / §13 ports).
/// The stage owns the engine; anything that needs to feed events into it
/// (notification bridge, Phase B interaction sources) resolves it here.
/// @MainActor: the engine is main-thread UI-adjacent by design (§7).
@MainActor
final class AvatarSession {
    static let shared = AvatarSession()

    private init() {}

    /// Weak: the stage's render context outlives registration; the engine
    /// is never retained beyond the stage's lifetime.
    private(set) weak var context: AvatarRenderContext?
    private(set) var archetype: Archetype = .ember

    func register(context: AvatarRenderContext, archetype: Archetype) {
        self.context = context
        self.archetype = archetype
    }

    func unregister(context: AvatarRenderContext) {
        if self.context === context {
            self.context = nil
        }
    }

    /// Single delivery path into the engine's L3 port (§13): taps, crown
    /// ticks and notification reactions all land here.
    func handle(_ event: AvatarEvent) {
        context?.engine.handleEvent(event)
    }
}
