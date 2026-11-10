import HealthKit
import os
import SwiftUI
import WidgetKit

/// AvatarStageView (§9): the stage *is* the app — full-screen avatar, face in
/// the upper third glance zone, name/state text in text styles (never fixed
/// sizes), vertical-paging TabView to Settings, one VoiceOver element with a
/// state-based label (never per-frame).
struct AvatarStageView: View {
    /// CI/smoke hook: -stageAwake keeps the stage on the live frame in
    /// the simulator (which dims to Always On on idle); never set in
    /// normal use. Same convention as the -archetype / -absence args.
    private static let forceAwake = ProcessInfo.processInfo.arguments.contains("-stageAwake")

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
    /// v25 (audit M4) + v31: hint that crown paging reaches the workout page
    /// and Settings — now gated on the first workout, not a once-ever flag.
    @State private var showPagesHint = false
    /// v14 sonic presence: the user's sound-listening preference, the
    /// once-per-install in-context permission ask, and the live tell.
    @AppStorage("listenForSounds") private var listenForSounds = true
    @AppStorage("soundPermissionAsked") private var soundPermissionAsked = false
    /// v17 F2 life sense: explicit opt-ins (absence of consent = dormant).
    /// Polled on visit/wake only — never in a background loop.
    @AppStorage("lifeSenseCalendar") private var lifeSenseCalendar = false
    @AppStorage("lifeSenseHealth") private var lifeSenseHealth = false
    /// v18 F3 weather: opt-in; fetched on visit with a 60-min cache.
    @AppStorage("lifeSenseWeather") private var lifeSenseWeather = false
    @State private var isListening = false
    @State private var context: AvatarRenderContext?
    /// v13: the authored-sprite stage's actor (the engine below stays
    /// registered for the vector fallback and engine-side consumers).
    @State private var director: SpriteDirector?
    @State private var isResting = false
    @State private var showPicker = false
    /// v27 debug/CI hooks: -showPicker opens the companion picker directly,
    /// -page N jumps the TabView to page N (0 stage, 1 workout, 2 settings).
    @State private var tabSelection = 0
    @State private var showNaming = false
    @State private var showRitualHint = false
    /// "It noticed" (§10.5.5): timestamp when the app left the active
    /// phase; a return after a long absence gets a soft noticed-nod.
    @State private var wentToBackgroundAt: Date?
    /// v12 presence: the streak days of the visit record, republished to
    /// the complication when the name changes.
    @State private var lastStreakDays = 0
    /// v16 F1 ritual bonding: the current bond level (memory-derived input
    /// for the director) and the once-per-session farewell gate.
    @State private var bondLevel = 1
    @State private var farewellAwardedThisSession = false
    /// v16 F1: transient VoiceOver announcement for bond moments (watchOS has
    /// no UIAccessibility.post — the single stage element's label carries it).
    @State private var bondAnnouncement = ""
    /// v19 F5: the morning-beat caption (Dynamic Type text, ~5 s, then gone).
    @State private var beatCaption: String?

    /// v14 sonic presence: the one-a-lifetime creation point — state
    /// changes surface as the on-stage listening tell.
    @State private var soundSource: MicrophonePresenceSource?
    /// v17 F2: the life-sense bridges, created once, polled on visit/wake.
    @State private var calendarBridge: CalendarSenseBridge?
    @State private var healthBridge: HealthSenseBridge?
    /// v18 F3: the weather bridge (watchOS 11+; dormant below).
    @State private var weatherBridge: WeatherSenseBridge?
    /// v21 F6: Aivatar's own workout session bridge + live UI state.
    @State private var workoutBridge: WorkoutCompanionBridge?
    @State private var workoutActive = false
    @State private var workoutElapsed: TimeInterval = 0
    /// v31: an honest inline error when a workout cannot start (Health access
    /// off/unavailable) — the old silent no-op left the button dead.
    @State private var workoutError = false
    /// v31: "run with" pill on the stage after a recent saved workout, until
    /// the user's first run (the pages hint gates on the same flag).
    @AppStorage("workoutEverStarted") private var workoutEverStarted = false
    /// v31: previous tab page, to derive crown-paging deltas.
    @State private var lastTabSelection = 0

    init(archetype: Archetype? = nil) {
        launchOverride = archetype
    }

    private var archetype: Archetype {
        launchOverride ?? storedArchetype
    }

    var body: some View {
        // watchOS 10 platform pattern (v12): the system vertical-page
        // TabView renders the page indicator next to the Digital Crown and
        // gives crown paging for free — stage on page 1, workout page 2,
        // Settings on page 3.
        TabView(selection: $tabSelection) {
            stage
            // v21 F6: the workout page rides the same crown paging.
            WorkoutPageView(archetype: archetype, active: workoutActive,
                            elapsed: workoutElapsed, error: workoutError,
                            onStart: startWorkout, onStop: stopWorkout)
            SettingsView(archetype: archetype)
        }
        .tabViewStyle(.verticalPage(transitionStyle: .automatic))
        // v31: the crown's paging is answered on stage — a glance in the
        // paging direction (the director maps |delta| >= 2 to a perk).
        .onChange(of: tabSelection) { new in
            let delta = new - lastTabSelection
            lastTabSelection = new
            guard delta != 0 else { return }
            context?.engine.handleEvent(.crownTick(delta: Float(delta)))
            director?.handleEvent(.crownTick(delta: Float(delta)))
        }
        .onAppear {
            buildContextIfNeeded()
            if soundSource == nil {
                soundSource = MicrophonePresenceSource { active in
                    isListening = active
                }
                if let director { soundSource?.bind(director: director) }
            }
            // v17 F2: a visit is a poll point — the bridges never loop.
            pollLifeSense()
            // v21 F6: a force-quit workout is recovered on launch (the
            // session itself cannot survive; the partial is finished).
            recoverWorkoutIfNeeded()
            // v27 debug/CI hooks.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-showPicker") {
                pickerCompleted = true
                ceremonyShown = true
                showPicker = true
            }
            // v30: -showNaming opens the naming ceremony directly (CI captures).
            if args.contains("-showNaming") {
                pickerCompleted = true
                ceremonyShown = true
                showNaming = true
            }
            if let i = args.firstIndex(of: "-page"), i + 1 < args.count,
               let n = Int(args[i + 1]) {
                tabSelection = n
            }
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
        guard let profile = try? PersonalityProfile.load(archetype) else { return }
        // v25 (audit): the frozen vector engine is dormant in the live path —
        // a missing/corrupt rig must never crash the stage. On failure we
        // log and run sprite-only (context = nil).
        let engine: AvatarEngine? = {
            do {
                return AvatarEngine(
                    skeleton: try Skeleton(document: try RigDocument.load()),
                    profile: profile,
                    // Stable per-archetype seed (String.hashValue is
                    // randomized per launch and must never be used here).
                    seed: 20261010 + UInt64(Archetype.allCases.firstIndex(of: archetype) ?? 0),
                    telemetry: OsLogTelemetrySink()
                )
            } catch {
                Logger(subsystem: "com.aivatar", category: "stage")
                    .error("rig load failed, running sprite-only: \(error, privacy: .public)")
                return nil
            }
        }()
        // A5d interiority: record the visit, hand the persistent traces
        // to the painter (memory is an input, never wall-clock in the
        // engine). CI/debug launches may simulate absence via -absence.
        let summary = recordVisitForBuild()
        context = engine.map { AvatarRenderContext(engine: $0, interiority: summary.tuning) }
        // v13: the stage acts through the sprite director (the engine
        // stays registered via the session; see buildContext comments).
        let spriteDirector = SpriteDirector(
            profile: profile,
            seed: 20261010 + UInt64(Archetype.allCases.firstIndex(of: archetype) ?? 0)
        )
        director = spriteDirector
        // v15: session memory becomes visible sprite cells (sprout /
        // week grid / trinket) — memory is an input to the director too.
        spriteDirector.interiority = summary.tuning
        // v16 F1: bond level rides in as a director input (memory-as-input).
        bondLevel = summary.bondLevel
        spriteDirector.bondLevel = summary.bondLevel
        soundSource?.bind(director: spriteDirector)
        // Phase B: notification events reach this engine via the
        // session registry (§13 port); re-registering replaces any
        // previous context.
        AvatarSession.shared.register(context: context, director: spriteDirector, archetype: archetype)
        presentInteriority(summary)
        // v19 F5: the morning life beat — one per day, first visit of a day.
        playMorningBeatIfNeeded()
        lastStreakDays = summary.streakDays
        publishCompanionWidgetState()
        refreshRunPill()
    }

    /// v12 presence pass + v18 F4 state model: publish the companion
    /// snapshot to the shared app group and ask WidgetKit to redraw — the
    /// complication never polls; it refreshes when the app says so. The
    /// write itself lives in the shared CompanionWidgetPublisher (v29) so
    /// every surface (stage, rename in Settings) uses one path.
    private func publishCompanionWidgetState() {
        CompanionWidgetPublisher.publish(archetype: archetype, name: stageName)
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
        // v13: each beat mirrors onto the sprite director — the engine
        // keeps the event for its own consumers, the director acts it out
        // on the stage (the authored-sprite vocabulary).
        func play(_ name: String) {
            engine.handleEvent(.gesture(name: name))
            director?.handleEvent(.gesture(name: name))
        }
        switch archetype {
        case .ember:
            // The rehearsal: it practiced a dance while you were away —
            // now it shows you. The show improves with the rehearsal
            // level (a longer run for a practiced performer).
            play("sparkle")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                play("spin")
                if summary.rehearsalLevel >= 3 {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    play("bounce")
                }
            }
        case .willow:
            // It kept watering the sprout — the swaying settle says the
            // tending continued without you (the grown sprout is the trace).
            play("swayCatch")
        case .compass:
            // The audit is done: one approval tick — the week grid it
            // drew is waiting below the body.
            play("tick")
        case .prism:
            // It found something while you were out and brought it back.
            play("doubleTake")
        case .nimbus:
            // The barometer: if this is your usual time, it started its
            // little drift BEFORE you arrived — it saw you coming.
            if summary.nearUsualHour {
                play("driftFloat")
            }
        }
    }

    private var stageName: String {
        companionName.isEmpty ? archetype.displayName : companionName
    }

    private var stage: some View {
        GeometryReader { geometry in
            // v28: corner tells respect the rounded bezel's safe area; only
            // the Canvas is full-bleed.
            let insets = geometry.safeAreaInsets
            // v28: the gesture/accessibility/sheet chain lives in its own
            // builder — inlined here it exceeded the type-check budget.
            stageChrome(
                ZStack(alignment: .bottom) {
                    if let director {
                        SpriteStageRenderer(
                            director: director,
                            sprite: AuthoredSprites.sprite(for: archetype),
                            forceAwake: AvatarStageView.forceAwake
                        )
                        // v28: companion switch rebuilds the renderer (no epoch hitch)
                        .id(ObjectIdentifier(director))
                    } else {
                        Color.black
                    }
                    bottomBlock(insets: insets)
                    cornerTells(insets: insets)
                },
                geometry: geometry
            )
        }
    }

    /// v28: the stage's interaction chrome — one accessibility element with a
    /// state-based label, the tap/long-press gestures, the VoiceOver actions,
    /// the lifecycle hooks, and the ceremony sheets — as a single builder so
    /// `stage` stays within the compiler's type-check budget.
    private func stageChrome<Content: View>(_ content: Content, geometry: GeometryProxy) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint(String(localized: "stage.hint"))
            // A5c: long-press is the SLOW-BLINK RITUAL (U8 — the trust
            // exchange: mutual gaze, then a blink you can watch happen).
            // The signature quirk stays on the VoiceOver named action and
            // the idle schedule.
            .onLongPressGesture(minimumDuration: 0.5) {
                context?.engine.handleEvent(.gesture(name: "slowBlink"))
                director?.handleEvent(.gesture(name: "slowBlink"))
                // v16 F1: the slow-blink ritual also grows bond (once-per-day
                // rituals are gated inside BondRules; this one is per-hold).
                awardRitual(.slowBlink)
                director?.handleRitual(.slowBlink)
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
                        // E7 boop-the-face: resolve the touched cell with the
                        // stage's own layout math and hit-test the face rect.
                        // Accepted boop = happy-squint ack + 6-tick blush flush
                        // + soft haptic; during the 90 s refractory (or a
                        // workout/session) the tap falls through to the normal
                        // reaction pool below — nothing is ever dead (U7).
                        let cell = size.width / CGFloat(CompanionSprite.gridWidth)
                        let top = size.height * 0.46 - cell * CGFloat(CompanionSprite.gridHeight) / 2
                        let cx = Int(value.location.x / cell)
                        let cy = Int((value.location.y - top) / cell)
                        if SpriteStageMetadata.isFaceCell(archetype, x: cx, y: cy),
                           director?.boopFace() == true {
                            HapticsChannel.shared.boop()
                        }
                        context?.engine.handleEvent(.gazeAt(x: nx, y: ny))
                        context?.engine.handleEvent(.tap)
                        director?.handleEvent(.gazeAt(x: nx, y: ny))
                        director?.handleEvent(.tap)
                        HapticsChannel.shared.react(to: archetype)
                        // v16 F1: the day's first greeting is a bond ritual.
                        awardRitual(.firstGreetingOfDay)
                        director?.handleRitual(.firstGreetingOfDay)
                        afterFirstInteraction()
                    }
            )
            .accessibilityAction {
                context?.engine.handleEvent(.tap)
                director?.handleEvent(.tap)
                HapticsChannel.shared.react(to: archetype)
                awardRitual(.firstGreetingOfDay)
                director?.handleRitual(.firstGreetingOfDay)
                afterFirstInteraction()
            }
            .accessibilityAction(named: String(localized: "a11y.action_quirk")) {
                performQuirk()
            }
            // v16 F1/G6: the slow-blink ritual is never gesture-only — under
            // Reduce Motion L2 it is a VoiceOver custom action (bond accrues).
            .accessibilityAction(named: String(localized: "a11y.action_slow_blink")) {
                context?.engine.handleEvent(.gesture(name: "slowBlink"))
                director?.handleEvent(.gesture(name: "slowBlink"))
                awardRitual(.slowBlink)
                director?.handleRitual(.slowBlink)
            }
            .onChange(of: isLuminanceReduced) { reduced in
                isResting = reduced && !Self.forceAwake
                // v14: the mic NEVER runs into the Always On rest state.
                syncSoundPresence()
                // v17 F2: a wrist-raise wake is a poll point too.
                if !reduced { pollLifeSense() }
                // v16 F1: the wrist-drop farewell, acknowledged once per
                // session when it is seen in full — a soft goodnight tick.
                if reduced, !Self.forceAwake, !farewellAwardedThisSession {
                    farewellAwardedThisSession = true
                    awardRitual(.farewellAcknowledged)
                    // v28: no competing act — the farewell beat IS the visible
                    // acknowledgment (one writer per queue).
                    HapticsChannel.shared.farewell()
                } else if !reduced {
                    farewellAwardedThisSession = false
                }
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
                let routesToNaming = !visible && launchOverride == nil && !pickerCompleted && !namingCompleted
                if routesToNaming {
                    // v31: defer one tick so the picker sheet fully dismisses
                    // before the naming sheet presents — no sheet-swap flash.
                    DispatchQueue.main.async { showNaming = true }
                }
                // v25: the ceremony sequence closed — now the deferred mic
                // ask may run (in-context, once, never racing a sheet).
                if !visible, !routesToNaming { syncSoundPresence() }
            }
            .onChange(of: showNaming) { visible in
                if !visible { syncSoundPresence() }
            }
            .onChange(of: scenePhase) { phase in
                // v14 sonic presence: the companion only listens where
                // you can see it listen — active scene phase only.
                syncSoundPresence()
                // "It noticed" (§10.5.5): returning after a long absence
                // (>= 30 min — a long meeting, a workout, sleep) earns one
                // soft noticed-nod within the U7 300 ms contingency window.
                if phase == .active {
                    if let leftAt = wentToBackgroundAt,
                       Date().timeIntervalSince(leftAt) >= 1800 {
                        context?.engine.handleEvent(.gesture(name: "nod"))
                        director?.handleEvent(.gesture(name: "nod"))
                    }
                    wentToBackgroundAt = nil
                    // v17 F2: returning to the foreground is a poll point.
                    pollLifeSense()
                    // v29: a wrist-raise wake refreshes the presence timestamp
                    // (the complication's awake window) and republishes —
                    // without counting a new session in the memory.
                    CompanionMemoryStore().touchLastSeen()
                    publishCompanionWidgetState()
                } else if phase == .background {
                    wentToBackgroundAt = Date()
                }
            }
            .sheet(isPresented: $showPicker) {
                NavigationStack {
                    // v30: onboarding mode gets a quiet "Not now" (the picker
                    // is skippable); a skip dismisses and the onChange below
                    // routes to the naming ceremony, as after a plain dismiss.
                    CompanionPickerView {
                        showPicker = false
                        if !namingCompleted {
                            // v31: same one-tick defer as the dismiss path.
                            DispatchQueue.main.async { showNaming = true }
                        }
                    } onSkip: {
                        showPicker = false
                    }
                }
            }
            .sheet(isPresented: $showNaming) {
                NamingCeremonyView(archetype: archetype, isPresented: $showNaming) { _ in
                    celebrateNaming()
                }
            }
    }

    /// v19 F5: selects and plays the morning beat (once per day). Also
    /// re-injects today's weather class from the lifeLog as the director's
    /// ambient condition input — the class persists across sessions while
    /// the log entry is today's. Any input skips the beat (the queue is
    /// replaced by the tap's act — skip <= 150 ms, G1).
    @MainActor
    private func playMorningBeatIfNeeded() {
        guard let director else { return }
        let store = CompanionMemoryStore()
        guard var memory = store.load() else { return }
        let now = Date()
        let dayIndex = CompanionMemoryStore.dayIndex(of: now)
        if let w = memory.lifeLog.filter({
            $0.kindHash == LifeKind.hash(of: .weatherClass) && $0.dayIndex == dayIndex
        }).last, let ch = w.classHash, let klass = ConditionClass.fromHash(ch) {
            director.setCondition(klass)
        }
        guard let beat = WakeBeatSelector.beat(memory: memory, archetype: archetype, now: now) else { return }
        director.playSequence(WakeBeatSelector.acts(for: beat, archetype: archetype))
        WakeBeatSelector.markShown(&memory, now: now)
        store.save(memory)
        if let caption = WakeBeatCaption.text(for: beat, name: stageName) {
            beatCaption = caption
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if beatCaption == caption { beatCaption = nil }
            }
        }
    }

    /// v17 F2 life sense: one on-demand poll per visit/wake/foreground — the
    /// bridges are never run in a loop (G9: zero rest-state cost). Consent
    /// gates everything: with both toggles off this is a no-op and the app
    /// is indistinguishable from one without life sense. Each delivered event
    /// also lands in the memory lifeLog as a content-free hash (the daily
    /// calendar cap reads that ring; F5/F8 will read it for beats/postcards).
    @MainActor
    private func pollLifeSense() {
        guard scenePhase == .active, !isLuminanceReduced || Self.forceAwake else { return }
        guard lifeSenseCalendar || lifeSenseHealth || lifeSenseWeather else { return }
        let now = Date()
        // v23: polls are async (HealthKit/EventKit queries must never block
        // the main thread) — run them off-main-actor in one task.
        Task { @MainActor in
            var events: [LifeEvent] = []
            if lifeSenseCalendar {
                if calendarBridge == nil {
                    calendarBridge = CalendarSenseBridge()
                    calendarBridge?.requestAccessIfNeeded()
                }
                events += await calendarBridge?.poll(now: now) ?? []
            }
            if lifeSenseHealth {
                if healthBridge == nil {
                    healthBridge = HealthSenseBridge()
                    healthBridge?.requestAccessIfNeeded()
                }
                events += await healthBridge?.poll(now: now) ?? []
            }
            if lifeSenseWeather {
                if weatherBridge == nil { weatherBridge = WeatherSenseBridge() }
                events += await weatherBridge?.poll(now: now) ?? []
            }
            guard !events.isEmpty else { return }
            for event in events {
                AvatarSession.shared.handleLifeEvent(event)
                logLifeEvent(event, now: now)
                // v22 F7: a noticed life event gets one soft haptic (capped).
                HapticsChannel.shared.play(.lifeEvent, archetype: archetype)
            }
        }
    }

    /// Logs one life event into the memory ring (content-free hash) and
    /// republishes the watch-face presence (v18 F4: an event flips the
    /// complication's state + copy line).
    @MainActor
    private func logLifeEvent(_ event: LifeEvent, now: Date = Date()) {
        let store = CompanionMemoryStore()
        var memory = store.load() ?? CompanionMemory()
        let dayIndex = CompanionMemoryStore.dayIndex(of: now)
        let classHash: Int? = {
            if case .weatherClass(let h) = event { return h }
            return nil
        }()
        memory.appendLifeLog(LifeLogEntry(
            kindHash: LifeSenseMapping.kindHash(of: event), dayIndex: dayIndex, at: now,
            classHash: classHash))
        store.save(memory)
        publishCompanionWidgetState()
        // v31: a fresh workoutDone may earn the stage's "Run with" pill.
        refreshRunPill()
    }

    // MARK: - Workout mode (v21, F6)

    /// "Run with <name>" — starts Aivatar's own HKWorkoutSession (in-context
    /// HealthKit ask on first use) and switches the director to the run
    /// grammar. The workout page shows the honest controls; the stage shows
    /// presence + a minimal elapsed corner.
    @MainActor
    private func startWorkout() {
        guard !workoutActive else { return }
        workoutError = false
        let bridge = WorkoutCompanionBridge()
        workoutBridge = bridge
        Task { @MainActor in
            do {
                try await bridge.start(activityRaw: Int(HKWorkoutActivityType.running.rawValue))
                workoutActive = true
                workoutElapsed = 0
                workoutEverStarted = true
                director?.setWorkoutMode(true)
                Task { @MainActor in
                    await runMetricsLoop(bridge: bridge, startedAt: Date())
                }
            } catch {
                workoutBridge = nil
                // Health data unavailable or denied: no session, no pretend —
                // v31: say so inline instead of leaving the button dead.
                workoutError = true
            }
        }
    }

    /// 10 s metrics cadence while the workout runs (G9: throttled, never a
    /// stream). Splits cheer with one haptic; everything goes to the director.
    /// v31: the UI poll pauses in background (the HKWorkoutSession itself
    /// keeps the session alive; only the on-screen elapsed pauses).
    @MainActor
    private func runMetricsLoop(bridge: WorkoutCompanionBridge, startedAt: Date) async {
        while workoutActive {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard workoutActive, scenePhase == .active else { continue }
            workoutElapsed = Date().timeIntervalSince(startedAt)
            for event in bridge.pollMetrics() {
                if case .split = event { HapticsChannel.shared.split() }
                AvatarSession.shared.handleLifeEvent(event)
            }
        }
    }

    @MainActor
    private func stopWorkout() {
        guard let bridge = workoutBridge else { return }
        Task { @MainActor in
            do {
                let done = try await bridge.stop()
                workoutActive = false
                director?.setWorkoutMode(false)
                // The wind-down: celebration act + lifeLog + watch-face event.
                AvatarSession.shared.handleLifeEvent(done)
                logLifeEvent(done)
            } catch {
                workoutActive = false
                director?.setWorkoutMode(false)
                refreshRunPill()
            }
        }
    }

    /// Force-quit recovery on launch: the session cannot survive the kill,
    /// so a persisted in-progress marker is finished as a partial workout
    /// (or discarded when too short to be real).
    @MainActor
    private func recoverWorkoutIfNeeded() {
        let bridge = WorkoutCompanionBridge()
        workoutBridge = bridge
        Task { @MainActor in
            for event in await bridge.recoverIfNeeded() {
                AvatarSession.shared.handleLifeEvent(event)
                logLifeEvent(event)
            }
        }
    }

    /// v14 sonic presence lifecycle: listen only while the app is the
    /// active scene, the stage is awake, the user opted in, and the
    /// in-context ask has happened. Idempotent start/stop.
    private func syncSoundPresence() {
        guard soundPermissionAsked else { return }
        if scenePhase == .active, !isLuminanceReduced, listenForSounds {
            soundSource?.start()
        } else {
            soundSource?.stop()
        }
    }

    /// v11 onboarding order: the first frame is a living companion, never a
    /// form. After the user's FIRST interaction (the moment of delight),
    /// the one-time ceremony sequence follows — picker, then naming (each
    /// skipped if already done); once the sequence has run it never
    /// returns. After onboarding, the slow-blink ritual gets its single
    /// visible hint.
    private func afterFirstInteraction() {
        // v14 in-context permission ask (the notification-auth pattern):
        // once per install, at the moment the feature matters — right
        /// after the first living interaction.
        // v25 (audit M1): mark the ask as done but DEFER the mic start until
        // the ceremony sheets close — the TCC alert and the app sheet must
        // not race on the first tap. syncSoundPresence() starts it then.
        if !soundPermissionAsked, listenForSounds {
            soundPermissionAsked = true
        }
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
        } else if !workoutEverStarted {
            // v25 (audit M4) + v31: the pages hint (crown paging reaches the
            // workout page and Settings) now repeats until the user's FIRST
            // workout — the workout page must not stay invisible.
            showPagesHint = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                showPagesHint = false
            }
        }
    }

    /// The naming ceremony's answer: the companion celebrates its new
    /// name (§10.5.1 — the moment personalization becomes ownership).
    /// The complication learns the new name immediately (v12 presence).
    /// v16 F1: the ceremony is the one-time large bond grant.
    private func celebrateNaming() {
        context?.engine.handleEvent(.gesture(name: "sparkle"))
        director?.handleEvent(.gesture(name: "sparkle"))
        HapticsChannel.shared.react(to: archetype)
        awardRitual(.namingCeremony)
        director?.handleRitual(.namingCeremony)
        publishCompanionWidgetState()
    }

    /// v16 F1: awards a bond ritual against the persistent memory (pure
    /// BondRules call — deterministic under the real clock at the shell),
    /// then feeds the new level to the director and, on a level-up, plays
    /// the bond haptic and announces it to VoiceOver ("trusts you more").
    /// No numbers are ever shown on the stage (G4: felt, not read).
    @MainActor
    private func awardRitual(_ ritual: BondRitual) {
        let store = CompanionMemoryStore()
        var memory = store.load() ?? CompanionMemory()
        let award = BondRules.award(&memory, ritual)
        // E5: schedule the ceremony for every newly crossed level whose bit is
        // still clear; the bit is set at SCHEDULE time so a skipped ceremony
        // is still a celebrated crossing and never repeats.
        var scheduledLevels: [Int] = []
        for level in award.newlyCrossedLevels where (memory.crossedLevels & (1 << level)) == 0 {
            memory.crossedLevels |= (1 << level)
            scheduledLevels.append(level)
        }
        store.save(memory)
        guard award.xpGained > 0 else { return }
        bondLevel = award.newLevel
        director?.bondLevel = award.newLevel
        // E5 ceremonies: one demonstration act per newly crossed level, after
        // the ritual ack settles (+ >= 20 ticks, via the director's queue).
        for level in scheduledLevels {
            switch level {
            case 2: director?.scheduleCeremony(.quirk)       // the newly unlocked quirk, unprompted
            case 3: director?.scheduleCeremony(.slowBlink)   // a directed slow blink at you
            case 4: break                                     // farewell bloom already scales (farewellBloomTicks)
            case 5:
                director?.depositMemento()                    // confidant cell, 4-tick stepped deposit
                director?.scheduleCeremony(.happy)
                announce(String(localized: "ceremony.level5.caption"))
            default: break
            }
        }
        if award.leveledUp {
            HapticsChannel.shared.bond()
            announce(String(format: String(localized: "bond.announce"), stageName))
        }
    }

    /// One VoiceOver announcement for bond moments. watchOS has no
    /// UIAccessibility.post, so the announcement rides the stage's single
    /// accessibility label for a few seconds — VoiceOver re-reads the label
    /// when it changes while focused.
    @MainActor
    private func announce(_ text: String) {
        bondAnnouncement = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if bondAnnouncement == text { bondAnnouncement = "" }
        }
    }

    private func performQuirk() {
        context?.engine.handleEvent(.gesture(name: archetype.quirkGesture.rawValue))
        director?.handleEvent(.gesture(name: archetype.quirkGesture.rawValue))
        HapticsChannel.shared.react(to: archetype)
    }

    /// v31: a recent saved workout (lifeLog, <= 7 days) with no active run
    /// earns a contextual "Run with <name>" pill on the stage that jumps to
    /// the workout page — page 2 stops being hidden after the first run.
    @State private var showRunPill = false

    private func refreshRunPill() {
        guard let memory = CompanionMemoryStore().load() else { showRunPill = false; return }
        let today = CompanionMemoryStore.dayIndex(of: Date())
        showRunPill = !workoutActive && memory.lifeLog.contains {
            $0.kindHash == LifeKind.hash(of: .workoutDone) && today - $0.dayIndex <= 7
        }
    }

    /// v28: the bottom text block (hints + beat caption + name + state) is
    /// ONE layout owner, so hints can never collide with the name lines.
    @ViewBuilder
    private func bottomBlock(insets: EdgeInsets) -> some View {
        VStack(spacing: 2) {
            if showRunPill, tabSelection == 0 {
                Text(String(format: String(localized: "workout.run_with"), stageName))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(SetupTheme.accent(for: archetype))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(SetupTheme.accent(for: archetype).opacity(0.15))
                    .clipShape(Capsule())
                    // High priority so the stage's spatial tap doesn't eat it.
                    .highPriorityGesture(TapGesture().onEnded { tabSelection = 1 })
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(format: String(localized: "workout.run_with"), stageName))
                    .accessibilityHint(String(localized: "workout.start_hint"))
                    .padding(.bottom, 2)
            }
            if showRitualHint {
                Text(String(localized: "hint.slow_blink"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: showRitualHint)
            }
            // v25: the one-time pages hint (workout + settings are crown pages).
            if showPagesHint {
                Text(String(localized: "hint.pages"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: showPagesHint)
            }
            // v19 F5: the beat caption rides as text (Dynamic Type), never as
            // painter pixels. v28: it's the moment's headline — footnote/primary.
            if let beatCaption {
                Text(beatCaption)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: beatCaption != nil)
            }
            // v30: one line — a long custom name must never wrap into the
            // state line below it.
            Text(stageName)
                .font(.footnote)
                .lineLimit(1)
            // v28: "resting" only after the farewell beat completes.
            Text(isResting && director?.resting == true
                 ? String(localized: "stage.tag_resting")
                 : String(localized: "stage.tag_here"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8 + insets.bottom)
        .padding(.horizontal, 12)
    }

    /// v28: corner tells (elapsed, waveform) inside the bezel safe area.
    @ViewBuilder
    private func cornerTells(insets: EdgeInsets) -> some View {
        Group {
            // v21 F6: the one number Aivatar shows during its own workout.
            if workoutActive {
                Text(WorkoutPageView.format(workoutElapsed))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(EdgeInsets(top: 6 + insets.top, leading: 0, bottom: 0, trailing: 10 + insets.trailing))
            }
            // v14: the visible listening tell — privacy is a design surface.
            if isListening {
                Image(systemName: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(EdgeInsets(top: 6 + insets.top, leading: 10 + insets.leading, bottom: 0, trailing: 0))
            }
        }
    }

    private var accessibilityText: String {
        // v30: localized state words (was hardcoded English).
        let kind = String(format: String(localized: "stage.kind"), archetype.animalName)
        var text: String
        if isResting {
            text = "\(stageName), \(kind), \(String(localized: "stage.state_resting"))"
        } else if isListening {
            text = "\(stageName), \(kind), \(String(localized: "stage.state_listening"))"
        } else {
            text = "\(stageName), \(kind), \(String(localized: "stage.state_calm"))"
        }
        // v16 F1: bond level-ups are announced, not displayed.
        if !bondAnnouncement.isEmpty {
            text += ". \(bondAnnouncement)"
        }
        // v19 F5: the beat caption is read once, then the standard state.
        if let beatCaption {
            text += ". \(beatCaption)"
        }
        return text
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
