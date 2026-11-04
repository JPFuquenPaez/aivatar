import SwiftUI
import WidgetKit

/// AvatarStageView (§9): the stage *is* the app — full-screen avatar, face in
/// the upper third glance zone, name/state text in text styles (never fixed
/// sizes), vertical-paging TabView to Settings, one VoiceOver element with a
/// state-based label (never per-frame).
struct AvatarStageView: View {
    /// Debug/CI launch-argument override (smoke tests, previews); nil in
    /// normal use, where the persisted selection wins (ArchetypeSelection).
    private let launchOverride: Archetype?

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ArchetypeSelection.storageKey) private var storedArchetype: Archetype = .ember
    /// A5c naming ceremony (§10.5.1): the user-owned name replaces the
    /// archetype display name once the ceremony completes.
    /// A5c naming ceremony: rename access (§10.5.1).
    @AppStorage("companionName") private var companionName = ""
    @AppStorage("namingCompleted") private var namingCompleted = false
    /// v10 onboarding: the companion picker runs once, before the naming
    /// ceremony (choose the animal, then name it).
    @AppStorage("companionPickerCompleted") private var pickerCompleted = false
    /// v11: the post-first-interaction ceremony sequence runs ONCE per
    /// install (it must never nag on later sessions — Settings stays the
    /// door for re-choosing and renaming).
    @AppStorage("onboardingCeremonyShown") private var ceremonyShown = false
    /// v11: the slow-blink ritual hint is surfaced once, after the first
    /// touch — a hidden gesture needs one visible invitation.
    @AppStorage("ritualHintShown") private var ritualHintShown = false
    @State private var context: AvatarRenderContext?
    @State private var isResting = false
    @State private var showPicker = false
    @State private var showNaming = false
    @State private var showRitualHint = false
    /// "It noticed" (§10.5.5): timestamp when the app left the active
    /// phase; a return after a long absence gets a soft noticed-nod.
    @State private var wentToBackgroundAt: Date?
    /// v12 presence: the streak days of the visit record, republished to
    /// the complication when the name changes.
    @State private var lastStreakDays = 0

    init(archetype: Archetype? = nil) {
        launchOverride = archetype
    }

    private var archetype: Archetype {
        launchOverride ?? storedArchetype
    }

    var body: some View {
        // watchOS 10 platform pattern (v12): the system vertical-page
        // TabView renders the page indicator next to the Digital Crown and
        // gives crown paging for free — stage on page 1, Settings on page 2.
        TabView {
            stage
            SettingsView(archetype: archetype)
        }
        .tabViewStyle(.verticalPage(transitionStyle: .automatic))
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
        // A5d interiority: record the visit, hand the persistent traces
        // to the painter (memory is an input, never wall-clock in the
        // engine). CI/debug launches may simulate absence via -absence.
        let summary = recordVisitForBuild()
        let renderContext = AvatarRenderContext(engine: engine, interiority: summary.tuning)
        context = renderContext
        // Phase B: notification events reach this engine via the
        // session registry (§13 port); re-registering replaces any
        // previous context.
        AvatarSession.shared.register(context: renderContext, archetype: archetype)
        presentInteriority(summary)
        lastStreakDays = summary.streakDays
        publishCompanionWidgetState(streakDays: summary.streakDays)
    }

    /// v12 presence pass: publish the companion snapshot to the shared
    /// app group and ask WidgetKit to redraw the timeline — the watch-face
    /// complication never polls; it refreshes when the app says so.
    /// Also seeds the complication icon PNGs (the REAL rendered pixel
    /// companion) once per archetype.
    private func publishCompanionWidgetState(streakDays: Int) {
        CompanionWidgetState.write(CompanionWidgetSnapshot(
            archetypeRaw: archetype.rawValue,
            name: stageName,
            streakDays: streakDays
        ))
        seedCompanionWidgetIcons()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Renders every archetype's icon into the shared container once (the
    /// icons only depend on the archetype; existing files are kept).
    private func seedCompanionWidgetIcons() {
        guard let container = CompanionWidgetState.sharedContainer() else { return }
        let icons = container.appendingPathComponent(CompanionWidgetState.iconsDirectoryName)
        try? FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        for archetype in Archetype.allCases {
            guard let url = CompanionWidgetState.iconURL(forArchetypeRaw: archetype.rawValue, container: container),
                  !FileManager.default.fileExists(atPath: url.path),
                  let png = CompanionIcon.pngData(for: archetype) else { continue }
            try? png.write(to: url)
        }
    }

    /// The visit record (A5d). The -absence launch argument (debug/E2E
    /// only) seeds the memory with an old lastSeen so the unobserved
    /// behaviors can be captured without waiting real days.
    private func recordVisitForBuild() -> VisitSummary {
        let store = CompanionMemoryStore()
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-absence"),
           index + 1 < args.count,
           let absence = Int(args[index + 1]) {
            // Seed a memory whose last visit was `absence` days ago.
            let existing = store.load()
            var memory = existing ?? CompanionMemory(firstLaunch: Date().addingTimeInterval(-Double(absence) * 86_400))
            memory.lastSeen = Date().addingTimeInterval(-Double(absence) * 86_400)
            if existing == nil {
                memory.firstLaunch = memory.lastSeen
                memory.sessions = max(0, absence * 2)  // a plausible history
                memory.sproutDays = Double(absence)
                memory.streakDays = max(0, absence - 1)
            }
            store.save(memory)
        }
        return store.recordVisit()
    }

    /// A5d — the return presentation: what the companion did while
    /// nobody was watching, shown on the first frame of a visit after a
    /// real absence (§1: "it kept something while I was gone").
    private func presentInteriority(_ summary: VisitSummary) {
        guard summary.absenceDays >= 1, let context else { return }
        let engine = context.engine
        switch archetype {
        case .ember:
            // The rehearsal: it practiced a dance while you were away —
            // now it shows you. The show improves with the rehearsal
            // level (a longer run for a practiced performer).
            engine.handleEvent(.gesture(name: "sparkle"))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                engine.handleEvent(.gesture(name: "spin"))
                if summary.rehearsalLevel >= 3 {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    engine.handleEvent(.gesture(name: "bounce"))
                }
            }
        case .willow:
            // It kept watering the sprout — the swaying settle says the
            // tending continued without you (the grown sprout is the trace).
            engine.handleEvent(.gesture(name: "swayCatch"))
        case .compass:
            // The audit is done: one approval tick — the week grid it
            // drew is waiting below the body.
            engine.handleEvent(.gesture(name: "tick"))
        case .prism:
            // It found something while you were out and brought it back.
            engine.handleEvent(.gesture(name: "doubleTake"))
        case .nimbus:
            // The barometer: if this is your usual time, it started its
            // little drift BEFORE you arrived — it saw you coming.
            if summary.nearUsualHour {
                engine.handleEvent(.gesture(name: "driftFloat"))
            }
        }
    }

    private var stageName: String {
        companionName.isEmpty ? archetype.displayName : companionName
    }

    private var stage: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if let context {
                    CanvasAvatarRenderer(context: context)
                } else {
                    Color.black
                }
                VStack(spacing: 2) {
                    Text(stageName)
                        .font(.footnote)
                    Text(isResting ? "resting" : "is here")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
                .padding(.horizontal, 12)
                if showRitualHint {
                    Text("Touch and hold to share a slow blink")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 34)
                        .padding(.horizontal, 12)
                        .transition(.opacity)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Double-tap to play. Touch and hold to share a slow blink.")
            // A5c: long-press is the SLOW-BLINK RITUAL (U8 — the trust
            // exchange: mutual gaze, then a blink you can watch happen).
            // The signature quirk stays on the VoiceOver named action and
            // the idle schedule.
            .onLongPressGesture(minimumDuration: 0.5) {
                context?.engine.handleEvent(.gesture(name: "slowBlink"))
            }
            // v6 touch-gaze: a spatial tap sends the normalized touch
            // direction so the avatar's eyes dart to the finger (§9
            // responsiveness) before the pooled reaction plays. Competes
            // with the long-press like a plain tap did — quick tap wins,
            // a hold still triggers the ritual.
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let size = geometry.size
                        guard size.width > 0, size.height > 0 else { return }
                        let nx = Float((value.location.x - size.width / 2) / (size.width / 2))
                        let ny = Float((value.location.y - size.height / 2) / (size.height / 2))
                        context?.engine.handleEvent(.gazeAt(x: nx, y: ny))
                        context?.engine.handleEvent(.tap)
                        HapticsChannel.shared.react(to: archetype)
                        afterFirstInteraction()
                    }
            )
            .accessibilityAction {
                context?.engine.handleEvent(.tap)
                HapticsChannel.shared.react(to: archetype)
                afterFirstInteraction()
            }
            .accessibilityAction(named: "Play signature move") {
                performQuirk()
            }
            .onChange(of: isLuminanceReduced) { reduced in
                isResting = reduced
            }
            .onAppear {
                isResting = isLuminanceReduced
                // v11 onboarding order: the first LIVING FRAME is the first
                // impression — no sheet ever gates the stage (watch
                // interactions are glanceable and short). The ceremonies
                // (companion picker, then naming) ride the user's first
                // interaction instead; both stay re-openable from Settings.
                // CI/smoke launches pass an -archetype override and skip
                // the sheets entirely.
            }
            // Dismissing the picker without choosing still leads to naming.
            .onChange(of: showPicker) { visible in
                if !visible, launchOverride == nil, !pickerCompleted, !namingCompleted {
                    showNaming = true
                }
            }
            .onChange(of: scenePhase) { phase in
                // "It noticed" (§10.5.5): returning after a long absence
                // (>= 30 min — a long meeting, a workout, sleep) earns one
                // soft noticed-nod within the U7 300 ms contingency window.
                if phase == .active {
                    if let leftAt = wentToBackgroundAt,
                       Date().timeIntervalSince(leftAt) >= 1800 {
                        context?.engine.handleEvent(.gesture(name: "nod"))
                    }
                    wentToBackgroundAt = nil
                } else if phase == .background {
                    wentToBackgroundAt = Date()
                }
            }
            .sheet(isPresented: $showPicker) {
                NavigationStack {
                    CompanionPickerView {
                        showPicker = false
                        if !namingCompleted { showNaming = true }
                    }
                }
            }
            .sheet(isPresented: $showNaming) {
                NamingCeremonyView(archetype: archetype, isPresented: $showNaming) { _ in
                    celebrateNaming()
                }
            }
        }
    }

    /// v11 onboarding order: the first frame is a living companion, never a
    /// form. After the user's FIRST interaction (the moment of delight),
    /// the one-time ceremony sequence follows — picker, then naming (each
    /// skipped if already done); once the sequence has run it never
    /// returns. After onboarding, the slow-blink ritual gets its single
    /// visible hint.
    private func afterFirstInteraction() {
        if launchOverride == nil, !ceremonyShown {
            ceremonyShown = true
            if !pickerCompleted {
                showPicker = true
            } else if !namingCompleted {
                showNaming = true
            }
        } else if !ritualHintShown {
            ritualHintShown = true
            showRitualHint = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                showRitualHint = false
            }
        }
    }

    /// The naming ceremony's answer: the companion celebrates its new
    /// name (§10.5.1 — the moment personalization becomes ownership).
    /// The complication learns the new name immediately (v12 presence).
    private func celebrateNaming() {
        context?.engine.handleEvent(.gesture(name: "sparkle"))
        HapticsChannel.shared.react(to: archetype)
        publishCompanionWidgetState(streakDays: lastStreakDays)
    }

    private func performQuirk() {
        context?.engine.handleEvent(.gesture(name: archetype.quirkGesture.rawValue))
        HapticsChannel.shared.react(to: archetype)
    }

    private var accessibilityText: String {
        let kind = "your \(archetype.animalName) companion"
        if isResting {
            return "\(stageName), \(kind), is resting"
        }
        return "\(stageName), \(kind), is calm"
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
