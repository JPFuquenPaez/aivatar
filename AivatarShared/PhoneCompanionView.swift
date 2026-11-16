import SwiftUI

/// PhoneCompanionView (v36, v3): the iPhone companion shell. "One character,
/// one proportion spec, one palette, three renders" — the phone carries the
/// CLAYMORPHIC render of the same soft-toy puppet the watch animates: same
/// resolver, same springs, same director grammar on the same 150 ms clock;
/// gradients + soft shadow where the stage stays flat (doc §5.8). The HD
/// portrait beside a pixel grid is retired with the two-cast era.
struct PhoneCompanionView: View {
    let archetype: Archetype
    var presence: CompanionPresence
    let size: CGFloat

    @State private var animator: PhoneCompanionAnimator
    @State private var epoch = Date()

    init(archetype: Archetype, presence: CompanionPresence = .awake, size: CGFloat) {
        self.archetype = archetype
        self.presence = presence
        self.size = size
        _animator = State(initialValue: PhoneCompanionAnimator(archetype: archetype, presence: presence))
    }

    var body: some View {
        PuppetLiveStage(
            driver: animator,
            ambientEnabled: presence != .asleep,
            style: .clay
        )
        .frame(width: size, height: size * 0.92)
        .id(presence)
    }
}
