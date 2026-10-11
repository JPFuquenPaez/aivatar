import SwiftUI

/// AvatarStageView (§9): the stage *is* the app — full-screen avatar, face in
/// the upper third glance zone, name/state text in text styles (never fixed
/// sizes), vertical-paging TabView to Settings, one VoiceOver element with a
/// state-based label (never per-frame).
struct AvatarStageView: View {
    /// Debug/CI launch-argument override (smoke tests, previews); nil in
    /// normal use, where the persisted selection wins (ArchetypeSelection).
    private let launchOverride: Archetype?

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @AppStorage(ArchetypeSelection.storageKey) private var storedArchetype: Archetype = .ember
    @State private var context: AvatarRenderContext?
    @State private var isResting = false

    init(archetype: Archetype? = nil) {
        launchOverride = archetype
    }

    private var archetype: Archetype {
        launchOverride ?? storedArchetype
    }

    var body: some View {
        // watchOS TabView pages vertically natively. The explicit
        // .verticalPage style is watchOS 10+ only, and our deployment
        // target is watchOS 9 (§2 hard constraint).
        TabView {
            stage
            SettingsView(archetype: archetype)
        }
        .onAppear {
            buildContextIfNeeded()
        }
        .onChange(of: archetype) { _ in
            // Companion switch: each archetype is a distinct engine
            // (profile, visual set, per-archetype seed), so the context is
            // rebuilt. The new avatar's launch greeting bloom plays as it
            // appears (§8) — the switch is its own delight moment.
            buildContext()
        }
    }

    private func buildContextIfNeeded() {
        guard context == nil else { return }
        buildContext()
    }

    private func buildContext() {
        let engine = AvatarEngine(
            skeleton: try! Skeleton(document: try! RigDocument.load()),
            profile: try! PersonalityProfile.load(archetype),
            // Stable per-archetype seed (String.hashValue is
            // randomized per launch and must never be used here).
            seed: 20261010 + UInt64(Archetype.allCases.firstIndex(of: archetype) ?? 0),
            // Event counters go to os_log for the on-device validation
            // pass (§3 telemetry port, §11 budgets).
            telemetry: OsLogTelemetrySink()
        )
        let renderContext = AvatarRenderContext(engine: engine)
        context = renderContext
        // Phase B: notification events reach this engine via the
        // session registry (§13 port); re-registering replaces any
        // previous context.
        AvatarSession.shared.register(context: renderContext, archetype: archetype)
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
        .accessibilityHint("Double-tap to play. Touch and hold for its signature move.")
        // Phase B: tap and the VoiceOver default action send a .tap event;
        // the engine answers with a pooled, in-character reaction clip and
        // the archetype's haptic flavor (§9). Long-press (and a VoiceOver
        // named action) performs the archetype's signature quirk — Ember
        // spins with a spark trail, Willow sways, Nimbus startles (§5).
        .onLongPressGesture(minimumDuration: 0.5) {
            performQuirk()
        }
        .onTapGesture {
            context?.engine.handleEvent(.tap)
            HapticsChannel.shared.react(to: archetype)
        }
        .accessibilityAction {
            context?.engine.handleEvent(.tap)
            HapticsChannel.shared.react(to: archetype)
        }
        .accessibilityAction(named: "Play signature move") {
            performQuirk()
        }
        .onChange(of: isLuminanceReduced) { reduced in
            isResting = reduced
        }
        .onAppear {
            isResting = isLuminanceReduced
        }
    }

    private func performQuirk() {
        context?.engine.handleEvent(.gesture(name: archetype.quirkGesture.rawValue))
        HapticsChannel.shared.react(to: archetype)
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
