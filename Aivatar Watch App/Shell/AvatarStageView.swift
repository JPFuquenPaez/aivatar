import SwiftUI

/// AvatarStageView (§9): the stage *is* the app — full-screen avatar, face in
/// the upper third glance zone, name/state text in text styles (never fixed
/// sizes), vertical-paging TabView to Settings, one VoiceOver element with a
/// state-based label (never per-frame).
struct AvatarStageView: View {
    let archetype: Archetype

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var context: AvatarRenderContext?
    @State private var isResting = false

    var body: some View {
        // watchOS TabView pages vertically natively. The explicit
        // .verticalPage style is watchOS 10+ only, and our deployment
        // target is watchOS 9 (§2 hard constraint).
        TabView {
            stage
            SettingsView(archetype: archetype)
        }
        .onAppear {
            if context == nil {
                let engine = AvatarEngine(
                    skeleton: try! Skeleton(document: try! RigDocument.load()),
                    profile: try! PersonalityProfile.load(archetype),
                    // Stable per-archetype seed (String.hashValue is
                    // randomized per launch and must never be used here).
                    seed: 20261010 + UInt64(Archetype.allCases.firstIndex(of: archetype) ?? 0)
                )
                let renderContext = AvatarRenderContext(engine: engine)
                context = renderContext
            }
        }
    }

    private var stage: some View {
        ZStack(alignment: .bottom) {
            if let context {
                CanvasAvatarRenderer(context: context)
            } else {
                Color.black
            }
            VStack(spacing: 2) {
                Text(archetype.displayName)
                    .font(.footnote)
                Text(isResting ? "resting" : "is here")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
            .padding(.horizontal, 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        // Phase B: tap and the VoiceOver default action send a .tap event;
        // the engine answers with a pooled, in-character reaction clip and
        // the archetype's haptic flavor (§9).
        .onTapGesture {
            context?.engine.handleEvent(.tap)
            HapticsChannel.shared.react(to: archetype)
        }
        .accessibilityAction {
            context?.engine.handleEvent(.tap)
            HapticsChannel.shared.react(to: archetype)
        }
        .onChange(of: isLuminanceReduced) { reduced in
            isResting = reduced
        }
        .onAppear {
            isResting = isLuminanceReduced
        }
    }

    private var accessibilityText: String {
        let name = archetype.displayName
        if isResting {
            return "\(name), your companion, is resting"
        }
        return "\(name), your companion, is calm"
    }
}

// MARK: - Preview harness (§10)
// One preview per archetype for fast visual iteration; the engine is
// UI-framework-free, so these same previews compile unchanged in a future
// iOS/macOS debug app (flagged: a separate preview target is not in scope).

#if DEBUG
#Preview("Ember") { AvatarStageView(archetype: .ember) }
#Preview("Willow") { AvatarStageView(archetype: .willow) }
#Preview("Compass") { AvatarStageView(archetype: .compass) }
#Preview("Prism") { AvatarStageView(archetype: .prism) }
#Preview("Nimbus") { AvatarStageView(archetype: .nimbus) }
#endif
