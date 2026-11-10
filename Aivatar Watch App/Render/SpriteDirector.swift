import Foundation

/// SpriteMood (v15 "Life 2.0", Tools/PIXEL_DESIGN.md §7): the companion's
/// internal state — the difference between reacting and being alive. Driven
/// by interaction recency/rate, sound events, and session memory; biases
/// the idle schedule's weights. Deterministic per seed.
nonisolated enum SpriteMood: Sendable, Equatable {
    case calm, curious, bored, lonely, playful
}

/// SpriteDirector (v13-v15, Tools/PIXEL_DESIGN.md v5 §7): the companion's
/// acting brain for the authored sprite stage. Life is DISCRETE POSES on a
/// 150 ms clock — the cat's grammar. v15 adds the life floor and the inner
/// state on top of the v13/v14 grammar:
///
/// - LIFE FLOOR: `breathe` every ~1.35 s (two-phase), `idleA`/`idleB`
///   drift variants every ~8 s — the companion never sits perfectly still.
///   (L2 keeps the body fully static; rest is the sleepy frame.)
/// - MOOD: calm/curious/bored/lonely/playful from interaction recency and
///   rate; lonely earns a rate-capped attention poke (perk + blink at you),
///   bored doubles the glance-away rate, playful doubles the quirk rate.
/// - ANTICIPATION: quirks wind up with a 1-tick `perk` first — acting, not
///   random. Long unattended stretches earn one `yawn` (refractory 4.5 min).
/// - AUTONOMY (v16): every ~30-60 s a single mote drifts in and the
///   companion glances at it — self-directed play, one focal story.
///
/// Determinism (memory-as-input discipline): a seeded RNG plus a tick
/// counter schedule everything; the same seed steps the same sequence, so
/// goldens and CI rate budgets work exactly like the engine's. Rates come
/// from PersonalityProfile (the personality is the animal).
nonisolated final class SpriteDirector {
    /// One director tick — the authored-frame clock.
    static let tickDuration: Double = 0.15
    /// Ticks per minute on the director clock.
    private static let ticksPerMinute: Float = 60.0 / 0.15

    /// v28: the blink hold in ticks from the profile's durationScale — 300 ms
    /// is the visibility floor at the 150 ms clock (willow 1.8 -> 4 ticks, a
    /// watchable blink; ember 0.7 -> 2). Single source for director + tests.
    static func blinkTicks(durationScale: Float) -> Int {
        max(2, Int(round(2 * durationScale)))
    }

    /// v28: the quirk wind-up in ticks from the profile's anticipation dial —
    /// any nonzero anticipation earns at least one visible perk tick; exactly
    /// zero (willow) means no wind-up at all. Single source for director+tests.
    static func perkWindupTicks(anticipation: Float) -> Int {
        anticipation > 0 ? max(1, Int(round(anticipation * 2))) : 0
    }

    private let sprite: CompanionSprite
    private let archetype: Archetype
    /// The archetype this director acts (stage-metadata / hit-routing key).
    var currentArchetype: Archetype { archetype }
    /// Aivatar 2.0: transient tell overlays (E7 blush, E9.2 vapor, E5 memento
    /// deposit) — merged into the stage overlay by the renderer; the authored
    /// grids and frame patches never change for these.
    var transientOverlayCells: [CompanionSprite.CellDiff] {
        var cells: [CompanionSprite.CellDiff] = []
        // E5 level-5 memento deposit: the confidant cell fades in over 4 ticks.
        if let alpha = mementoDepositAlpha {
            cells.append(CompanionSprite.CellDiff(9, 16, "A", alpha: alpha))
        }
        cells += transientTellCells
        return cells
    }
    /// E7/E9 transient tells (blush / vapor).
    private var transientTellCells: [CompanionSprite.CellDiff] {
        var cells: [CompanionSprite.CellDiff] = []
        // E7: the happy-flush blush — 2 accent cells at face mid-height.
        if blushTicksLeft > 0 { cells += SpriteStageMetadata.blushCells(archetype) }
        // E9.2: the cold breath vapor — 2 ink cells above the face center.
        if vaporOnTicksLeft > 0 { cells += SpriteStageMetadata.vaporCells(archetype) }
        return cells
    }

    // MARK: - E9.2 cold breath vapor

    /// Dedicated deterministic stream for the vapor cycle (house rule).
    private var vaporRng: SeededRandom
    /// Ticks left in the current vapor puff (on 3, then hidden >= 33).
    private var vaporOnTicksLeft = 0
    private var vaporNextTick = 0
    static let vaporOnTicks = 3
    static let vaporMinHiddenTicks = 33
    /// True while a vapor puff renders (suppresses other tells: one focal story).
    var vaporActive: Bool { vaporOnTicksLeft > 0 }

    // MARK: - E7 boop the face

    /// Refractory between boops: 600 ticks = 90 s. During it, face taps route
    /// to the normal reaction pool (nothing dead, U7).
    static let boopRefractoryTicks = 600
    /// The flush overlay lifetime: 6 ticks.
    static let blushDurationTicks = 6
    private var blushTicksLeft = 0
    private var lastBoopTick = -1_000_000

    /// A face tap landed (hit math done by the caller via SpriteStageMetadata).
    /// Returns true when the boop was accepted: ack act (happy squint) plays
    /// within <= 2 ticks and the 6-tick blush overlay starts. Suppressed while
    /// resting, in a workout, or during a breath session.
    @discardableResult
    func boopFace() -> Bool {
        guard !resting, !workoutMode, !sessionMode,
              tick - lastBoopTick >= Self.boopRefractoryTicks else { return false }
        lastBoopTick = tick
        blushTicksLeft = Self.blushDurationTicks
        play(.happy)
        return true
    }

    // MARK: - E5 bond ceremonies

    /// Ceremonies scheduled after the ritual ack settles (+ >= 20 ticks).
    private var pendingCeremonies: [(act: SpriteAct, atTick: Int)] = []
    /// Minimum settle delay before a ceremony may play (ticks).
    static let ceremonySettleTicks = 20

    /// Schedules a one-shot demonstration act (E5). Suppressed while a
    /// workout runs (the run is the motion); fires as soon as the queue is
    /// free and the settle delay has passed.
    func scheduleCeremony(_ act: SpriteAct, afterTicks: Int = ceremonySettleTicks) {
        pendingCeremonies.append((act, tick + max(1, afterTicks)))
    }

    /// E5 level-5: the confidant memento deposit — the accent cell at (9,16)
    /// appears over 4 ticks (alpha stepped 0.25/tick through the overlay).
    private var mementoDepositTicksLeft = 0
    static let mementoDepositTicks = 4
    func depositMemento() { mementoDepositTicksLeft = Self.mementoDepositTicks }
    /// The deposit's current alpha, or nil when no deposit is in progress.
    var mementoDepositAlpha: Float? {
        guard mementoDepositTicksLeft > 0 else { return nil }
        return Float(Self.mementoDepositTicks - mementoDepositTicksLeft + 1) / Float(Self.mementoDepositTicks)
    }

    // MARK: - Preview mode (Aivatar 2.0, E2 "Meet them" live picker)

    /// Preview configuration (the picker): the animal is *meeting you*, not
    /// performing — blink λ x 0.7, glance rate x 0.5, motes/yawn/lonely-poke
    /// off, mood pinned calm, life floor on. Dwell >= 8 ticks (1.2 s) of
    /// continuous presence schedules exactly ONE owner quirk per page visit.
    var previewMode = false
    private var previewDwellTicks = 0
    private var previewQuirkDone = false
    /// Preview dwell threshold in ticks (8 ticks = 1.2 s).
    static let previewQuirkDwellTicks = 8

    /// Page change in the picker: the dwell counter resets and the quirk
    /// re-arms (at most one quirk per page visit).
    func resetPreviewDwell() {
        previewDwellTicks = 0
        previewQuirkDone = false
    }

    private func stepPreview() {
        guard queue.isEmpty else { return }
        previewDwellTicks += 1
        if previewDwellTicks >= Self.previewQuirkDwellTicks,
           !previewQuirkDone, mode == .full {
            previewQuirkDone = true
            play(.quirk)  // the owner's signature move, once per page visit
        }
    }

    private var rng: SeededRandom
    private let blinkP: Float
    private let glanceP: Float
    private let eventP: Float
    /// v31: the low-rate idle micro-flick (ear/perk flick) — deterministic
    /// Bernoulli, tempo-scaled like the quirk rate.
    private let flickP: Float
    /// v28: the profile's blink grammar + anticipation now shape the live
    /// stage (they were only consumed by the frozen vector engine).
    private let blinkTicks: Int
    /// v31: blink.variance drives occasional double-blinks (per-animal
    /// blink character: nimbus bursts, compass almost never).
    private let blinkVariance: Float
    private let perkWindupTicks: Int
    /// v31: the gaze policy shapes idle glances (compass sweeps on a
    /// metronome, willow holds long soft looks, prism alternates corners,
    /// nimbus darts then settles longest).
    private let gazePolicy: GazePolicy
    private var lastBlinkTick = -100
    private var lastGazeTick = -1
    private var lastGazeDir = 0
    private let weatherDials: WeatherDials?
    private var mode: MotionAccessibilityMode = .full

    /// v18 F3: the current weather condition class (an INPUT — determinism
    /// holds because goldens inject classes, never live weather). The dials
    /// bias the idle schedule: tempo -> quirk rate, amplitude -> glance rate,
    /// accentBias -> mote density, hueShift -> render-time palette rotation.
    private(set) var condition: ConditionClass = .unknown
    private var weatherTempoMul: Float = 1
    private var weatherGlanceMul: Float = 1
    private var weatherMoteMul: Float = 1
    /// Render-time hue rotation in degrees (0 = untouched palette).
    private(set) var weatherHueShiftDeg: Float = 0

    /// Sets the condition class and applies its dials (pure profile data).
    func setCondition(_ newCondition: ConditionClass) {
        condition = newCondition
        let dial = weatherDials?.dial(for: newCondition) ?? WeatherDial()
        weatherTempoMul = max(0.2, dial.tempoScale)
        weatherGlanceMul = max(0.2, dial.amplitudeScale)
        weatherMoteMul = min(2.0, max(0.5, 1.0 - dial.accentBias * 0.5))
        // v24: the hue-shift cap is enforced in code, not just in the data —
        // <= 20 degrees, Prism only (the LUT budget rule, PIXEL_DESIGN §7.6).
        weatherHueShiftDeg = archetype == .prism ? min(max(dial.hueShiftDeg, -20), 20) : 0
    }

    /// The acting queue: (frame id, hold ticks). Non-empty = an act plays.
    private var queue: [(frame: String, ticks: Int)] = []
    private var scheduledIdle = "idle"
    private(set) var tick = 0
    private(set) var blinkCount = 0
    private(set) var actCount = 0
    /// Rest/always-on: forces the sleepy frame until wake.
    private(set) var resting = false

    // MARK: - Mood & autonomy state

    /// The companion's current internal state (independence signal).
    private(set) var mood: SpriteMood = .calm
    private var lastInteractionTick = 0
    private var interactionTicks: [Int] = []
    private var curiousUntilTick = 0
    private var lastLonelyPokeTick = -10_000
    private var lastYawnTick = -10_000
    /// The self-play mote (one cell, stage-level), nil when absent.
    private(set) var moteCell: (x: Int, y: Int)?
    private var moteTicksLeft = 0
    private var nextMoteTick = 0
    private var moteDriftX = 0
    private var moteDriftY = 0

    /// Session memory input (A5d): the persistent traces, rendered as
    /// sprite overlay cells. Memory is an input — never wall-clock here.
    var interiority: InteriorityTuning = .default

    /// v16 F1: bond level (1...5) as a director input — memory-derived,
    /// clamped. It biases the idle schedule: a bonded companion quirks more
    /// (its signature is in the rotation) and glances away less (it looks
    /// at you more). Pure input, so goldens stay deterministic.
    private var _bondLevel = 1
    var bondLevel: Int {
        get { _bondLevel }
        set { _bondLevel = min(max(newValue, 1), BondRules.maxLevel) }
    }
    /// The last ritual ack played (F1) — test/VoiceOver surface.
    private(set) var lastRitual: BondRitual?
    private(set) var ritualCount = 0

    init(profile: PersonalityProfile, seed: UInt64) {
        let resolved = Archetype(rawValue: profile.id) ?? .ember
        archetype = resolved
        sprite = AuthoredSprites.sprite(for: resolved)
        rng = SeededRandom(seed ^ 0x51_DE_51_CE)
        blinkP = profile.gazeProfile.blinkRatePerMin / Self.ticksPerMinute
        glanceP = profile.gazeProfile.saccadeRatePerMin / Self.ticksPerMinute * 0.35
        eventP = 0.8 / Self.ticksPerMinute * profile.motionProfile.tempoScale
        flickP = 0.25 / Self.ticksPerMinute * profile.motionProfile.tempoScale
        // 300 ms is the visibility floor at the 150 ms clock; willow's
        // 1.8 durationScale -> 4 ticks (a watchable blink), ember 0.7 -> 2.
        blinkTicks = Self.blinkTicks(durationScale: profile.blink?.durationScale ?? 1)
        blinkVariance = profile.blink?.variance ?? 0
        perkWindupTicks = Self.perkWindupTicks(anticipation: profile.motionGrammar?.anticipation ?? 0)
        gazePolicy = profile.gazePolicy ?? .lock
        weatherDials = profile.weatherDials
        nextMoteTick = 140 + rng.nextInt(160)
        vaporRng = SeededRandom(seed ^ 0xFAE2_B04D)
        vaporNextTick = 80 + vaporRng.nextInt(120)
    }

    // MARK: - Reading state

    /// The frame the stage should draw right now.
    var currentFrame: String {
        if resting { return "sleepy" }
        return queue.first?.frame ?? scheduledIdle
    }

    /// Ticks still queued in the current act run (test-visible: F5 beat
    /// duration budget = pendingActTicks * tickDuration <= 5 s).
    var pendingActTicks: Int { queue.reduce(0) { $0 + $1.ticks } }

    /// Advances the director clock to `target` ticks (idempotent).
    func advance(toTick target: Int) {
        while tick < target { step() }
    }

    private func step() {
        tick += 1
        if resting { return }
        if vaporOnTicksLeft > 0 { vaporOnTicksLeft -= 1 }  // E9.2 puff lifetime
        // E8 session grammar runs instead of the idle schedule entirely.
        if sessionMode { stepSession(); return }
        // E2 preview: mood pinned calm, no motes/yawn/lonely; the dwell quirk
        // replaces the random quirk draw.
        if previewMode { stepPreview() } else { updateMoodAndAutonomy() }
        if !queue.isEmpty {
            queue[0].ticks -= 1
            if queue[0].ticks <= 0 { queue.removeFirst() }
            return
        }
        // E5: a due ceremony plays as soon as the queue is free (suppressed
        // during workouts — one intention at a time).
        if mementoDepositTicksLeft > 0 { mementoDepositTicksLeft -= 1 }
        if blushTicksLeft > 0 { blushTicksLeft -= 1 }
        if !pendingCeremonies.isEmpty, !workoutMode, !sessionMode,
           let i = pendingCeremonies.firstIndex(where: { $0.atTick <= tick }) {
            let ceremony = pendingCeremonies.remove(at: i)
            play(ceremony.act)
            return
        }
        // E9.2 vapor scheduling: cold class only, awake + full mode, no
        // workout/session/preview, queue free. On 3 ticks, then hidden
        // >= 33 ticks (gap drawn from the dedicated vapor stream).
        if mode == .full, !workoutMode, !sessionMode, !previewMode,
           condition == .cold, queue.isEmpty,
           vaporOnTicksLeft == 0, tick >= vaporNextTick {
            vaporOnTicksLeft = Self.vaporOnTicks
            vaporNextTick = tick + Self.vaporOnTicks + Self.vaporMinHiddenTicks + vaporRng.nextInt(60)
        }
        // Idle schedule (draw order fixed: blink, glance, quirk, flick). A
        // firing act preempts the floor frame; draws only run on idle ticks.
        scheduledIdle = scheduledIdleFrame()
        // E2 preview: blink λ x 0.7, glance rate x 0.5.
        let effBlinkP = previewMode ? blinkP * 0.7 : blinkP
        let effGlanceP = previewMode ? glanceP * 0.5 : glanceP
        // v16 F1: bond biases the idle schedule — higher bond, more signature
        // quirks, fewer glances away (the companion looks at you more).
        let glanceMul: Float = (mood == .bored ? 2 : (mood == .lonely ? 0.3 : 1))
            * BondRules.glanceAwayMultiplier(bondLevel) * weatherGlanceMul
        let eventMul: Float = (mood == .playful ? 2 : (mood == .lonely ? 1.5 : 1))
            * BondRules.quirkRateMultiplier(bondLevel) * weatherTempoMul
        if rng.nextFloat() < effBlinkP, tick - lastBlinkTick >= 3 {
            lastBlinkTick = tick
            play(.blink)
        } else if mode != .reduceMotionL2, !workoutMode,
                  rng.nextFloat() < effGlanceP * glanceMul || compassSweepDue() {
            // v31: the gaze policy shapes the glance — compass sweeps on a
            // deterministic 600-tick metronome, prism alternates corners.
            let direction: Int
            switch gazePolicy {
            case .metricSweep: direction = (tick / 600) % 2 == 0 ? 1 : -1
            case .wander: direction = lastGazeDir == 1 ? -1 : 1
            default: direction = rng.nextFloat() < 0.5 ? -1 : 1
            }
            lastGazeDir = direction
            // v31 F1: a bonded companion (L3+) occasionally answers with a
            // watchable slow-blink instead of a glance-away.
            if BondRules.lookAtYouPerMin(bondLevel) > 0,
               rng.nextFloat() < BondRules.lookAtYouPerMin(bondLevel) / Self.ticksPerMinute {
                play(.slowBlink)
            } else {
                play(.look, direction: direction)
            }
            actCount += 1
        } else if mode == .full, !workoutMode, !previewMode, !vaporActive,
                  rng.nextFloat() < eventP * eventMul {
            play(.quirk)
            actCount += 1
        } else if mode == .full, !workoutMode, !vaporActive, rng.nextFloat() < flickP {
            // v31: idle micro-flick — a 1-tick perk reads as an ear flick at
            // this rate, not an alert. Negligible motion-budget cost.
            play(.flick)
            actCount += 1
        }
    }

    /// v31: compass's metricSweep policy — a deterministic lighthouse sweep
    /// every 600 ticks (90 s), no RNG.
    private func compassSweepDue() -> Bool {
        gazePolicy == .metricSweep && tick > 0 && tick % 600 == 0
    }

    /// The life floor between acts: one breath every ~2.7 s (2-tick
    /// inhale/exhale window) over a slow idle-variant rotation (~8 s).
    /// L2 pins it to plain idle.
    private func scheduledIdleFrame() -> String {
        guard mode != .reduceMotionL2 else { return "idle" }
        // v21 F6: in workout mode the floor is a run cycle (idleA/idleB
        // alternating at the pace-band cadence) — no drift variants.
        if workoutMode {
            return (tick / Self.runCycleTicks(workoutPaceBand)) % 2 == 0 ? "idleA" : "idleB"
        }
        // v28: 600 ms visible hold every 3.6 s (~17 breaths/min, 25% duty) —
        // reads as breathing, not a twitch.
        let phase = tick % 24
        if (8...11).contains(phase) { return "breathe" }
        switch (tick / 55) % 3 {
        case 1: return "idleA"
        case 2: return "idleB"
        default: return "idle"
        }
    }

    // MARK: - Mood & autonomy (v15/v16)

    private func updateMoodAndAutonomy() {
        interactionTicks.removeAll { tick - $0 > 300 }
        let recent = interactionTicks.count
        let sinceInteraction = tick - lastInteractionTick
        if recent >= 3 {
            mood = .playful
        } else if tick < curiousUntilTick {
            mood = .curious
        } else if sinceInteraction > 300 {
            mood = .lonely
        } else if sinceInteraction > 150 {
            mood = .bored
        } else if mood == .bored || mood == .lonely {
            mood = .calm
        }
        // Lonely poke: one attention-seeking beat, rate-capped at ~36 s,
        // never under Reduce Motion L2 or during a workout.
        if mood == .lonely, mode != .reduceMotionL2, !workoutMode,
           tick - lastLonelyPokeTick > 240, queue.isEmpty {
            lastLonelyPokeTick = tick
            queue = [("perk", 2), ("blink", 2), ("idle", 2)]
            actCount += 1
        }
        // One yawn per long unattended stretch (90 s idle, 4.5 min cooldown).
        if mode != .reduceMotionL2, !workoutMode, sinceInteraction > 600,
           tick - lastYawnTick > 1800, queue.isEmpty {
            lastYawnTick = tick
            queue = [("yawn", 3), ("idle", 2)]
            actCount += 1
        }
        // Self-play mote (v16): full mode only, never while an act plays or
        // during a workout (v21: one focal story — the run).
        if mode == .full, !workoutMode, queue.isEmpty {
            if var mote = moteCell {
                moteTicksLeft -= 1
                if moteTicksLeft % 4 == 0 {
                    mote.x = min(max(mote.x + moteDriftX, 0), CompanionSprite.gridWidth - 1)
                    mote.y = min(max(mote.y + moteDriftY, 0), CompanionSprite.gridHeight - 1)
                    moteCell = mote
                }
                if moteTicksLeft <= 0 {
                    moteCell = nil
                    nextMoteTick = tick + Int(Float(200 + rng.nextInt(200)) * weatherMoteMul)
                }
            } else if tick >= nextMoteTick {
                let edge = rng.nextInt(4)
                let pos: (x: Int, y: Int)
                switch edge {
                case 0: pos = (rng.nextInt(CompanionSprite.gridWidth), 0)
                case 1: pos = (rng.nextInt(CompanionSprite.gridWidth), CompanionSprite.gridHeight - 1)
                case 2: pos = (0, rng.nextInt(CompanionSprite.gridHeight))
                default: pos = (CompanionSprite.gridWidth - 1, rng.nextInt(CompanionSprite.gridHeight))
                }
                moteCell = pos
                moteTicksLeft = 24
                moteDriftX = rng.nextInt(3) - 1
                moteDriftY = rng.nextInt(3) - 1
                play(.look, direction: pos.x < CompanionSprite.gridWidth / 2 ? -1 : 1)
            }
        }
    }

    private func markInteraction() {
        lastInteractionTick = tick
        interactionTicks.append(tick)
        if mood == .lonely || mood == .bored { mood = .calm }
    }

    // MARK: - Events (shares the engine's AvatarEvent vocabulary)

    func handleEvent(_ event: AvatarEvent) {
        // E8: taps and crown ticks end a breath session immediately (G1,
        // < 300 ms), then answer normally; a wrist-drop ends it too.
        if sessionMode {
            switch event {
            case .tap, .crownTick, .sleep: endSession()
            default: break
            }
        }
        switch event {
        case .tap:
            markInteraction()
            if tick == lastGazeTick {
                // v28: the v6 touch-gaze was silently canceled by the tap's
                // queue replace — play dart-then-answer as one run.
                queue = frames(for: .look, direction: lastGazeDir) + frames(for: .happy)
                actCount += 2
            } else {
                play(.happy)
            }
        case .crownTick(let delta):
            markInteraction()
            // v31: crown paging is answered on stage — a glance in the paging
            // direction, or a perk for a fast multi-page flick. Existing
            // frames only; input-driven, so zero idle-budget cost.
            if abs(delta) >= 2 {
                play(.perk)
            } else {
                play(.look, direction: delta > 0 ? 1 : -1)
            }
        case .wake:
            markInteraction()
            resting = false
            lifeActThisWake = false
            play(.happy)
        case .sleep:
            play(.farewell)
        case .gazeAt(let x, _):
            markInteraction()
            lastGazeTick = tick
            lastGazeDir = x < 0 ? -1 : 1
            play(.look, direction: lastGazeDir)
        case .gesture(let name):
            markInteraction()
            play(gestureAct(named: name))
        }
    }

    /// F1 ritual ack (v16): the stage awards bond through BondRules and
    /// tells the director to play the ritual's act. Every ritual gets a
    /// visible answer within one tick — rituals are never gesture-only.
    func handleRitual(_ ritual: BondRitual) {
        markInteraction()
        lastRitual = ritual
        ritualCount += 1
        switch ritual {
        case .slowBlink, .farewellAcknowledged:
            play(.slowBlink)
        case .firstGreetingOfDay, .namingCeremony, .dailyPresence:
            play(.happy)
        }
    }

    func setResting(_ value: Bool) {
        resting = value
        if value {
            moteCell = nil
        } else {
            queue.removeAll()
            scheduledIdle = "idle"
        }
    }

    /// E3: the naming-ceremony perk — the companion looks up at the name being
    /// written. Existing `perk` frame, no new vocabulary.
    func playPerk() { play(.perk) }

    var accessibilityMode: MotionAccessibilityMode {
        get { mode }
        set { mode = newValue }
    }

    /// Gesture-name map: every clip the notification bridge / interiority
    /// beats can name resolves to a sprite act. Unknown names degrade to
    /// .happy — never a blank beat.
    private func gestureAct(named name: String) -> SpriteAct {
        switch name {
        case "slowBlink", "swayCatch":
            return .slowBlink
        case "lookAround", "doubleTake", "mirror", "driftFloat", "shiver":
            return .look
        default:
            return .happy
        }
    }

    // MARK: - Sound presence (v14, Tools/PIXEL_DESIGN.md §7.1)

    /// Sound-derived awareness. A startle plays the authored `perk` pose;
    /// a sustained voice plays the personality acknowledgment and sets
    /// `curious` for a while. A shared act guard (2.4 s) keeps a clap
    /// storm from ever turning the silent stage into jitter; under
    /// Reduce Motion L2 reactions degrade to the face-readable blink.
    private var lastSoundActTick = -100

    func handleSound(_ event: SoundPresenceEvent) {
        if resting { return }
        markInteraction()
        curiousUntilTick = tick + 200
        if mode == .reduceMotionL2 {
            guard tick - lastSoundActTick >= Self.soundActGapTicks else { return }
            lastSoundActTick = tick
            play(.blink)
            return
        }
        guard tick - lastSoundActTick >= Self.soundActGapTicks else { return }
        lastSoundActTick = tick
        switch event {
        case .onset:
            play(.perk)
        case .voiceSustained:
            switch archetype {
            case .ember: play(.perk)                 // ears toward your voice
            case .willow: play(.slowBlink)           // the listening blink
            case .compass: play(.quirk)              // the metronome answers
            case .prism: play(.look, direction: 1)   // the turret locks on you
            case .nimbus: play(.happy)                // the chirp
            }
        }
    }

    /// Minimum director ticks between sound-driven acts (2.4 s at 150 ms.)
    static let soundActGapTicks = 16

    // MARK: - Life sense (v17, Ambient Life F2)

    /// Minimum director ticks between life-event acts of the same kind
    /// (10 min at 150 ms) — a calendar volley is one reaction, not a storm.
    static let lifeEventCooldownTicks = 4000

    private var lastLifeActTick: [LifeEventKind: Int] = [:]
    /// Max one life-event reaction per wake (F2); reset on .wake.
    private var lifeActThisWake = false
    private(set) var lifeEventCount = 0

    /// The director's reaction to a real-life event (calendar soon, workout
    /// done, slept with the watch). Reactions, never nags: at most one per
    /// wake, per-kind 10 min cooldown, nothing while resting, and under
    /// Reduce Motion L2 a face-readable blink only. The companion also gets
    /// curious for a while — it noticed your day.
    func handleLifeEvent(_ event: LifeEvent) {
        if resting { return }
        // v18 F3: a weather event also sets the condition (the ambient bias).
        if case .weatherClass(let classHash) = event,
           let klass = ConditionClass.fromHash(classHash) {
            setCondition(klass)
        }
        // v21 F6: live pace bands steer the run grammar (no act).
        if case .workoutLive(let band) = event {
            setWorkoutPaceBand(band)
        }
        guard let act = Self.reactionAct(for: event, archetype: archetype) else { return }
        let kind = Self.kind(of: event)
        // During a workout the one-per-wake gate is off (the run is live);
        // the per-kind cooldown still holds, and splits get a tighter one.
        if !workoutMode && lifeActThisWake { return }
        let cooldown = kind == .split ? Self.splitCooldownTicks : Self.lifeEventCooldownTicks
        if let last = lastLifeActTick[kind], tick - last < cooldown { return }
        lastLifeActTick[kind] = tick
        if !workoutMode { lifeActThisWake = true }
        lifeEventCount += 1
        if kind == .split { splitCount += 1 }
        curiousUntilTick = tick + 200
        if mode == .reduceMotionL2 {
            play(.blink)
        } else if workoutMode {
            // v29: land the cheer on a stride boundary, not mid-stride.
            playOnStrideBoundary(act)
        } else {
            play(act)
        }
    }

    /// Minimum ticks between split cheers (45 s at 150 ms — F6 split channel).
    static let splitCooldownTicks = 300

    // MARK: - Breath session mode (Aivatar 2.0, E8 "Sit together")

    /// Session grammar: while active, the breath IS the motion — the idle
    /// floor alternates inhale (breathe frame, 27 ticks) / exhale (idle
    /// settle, 53 ticks) for exactly 5 cycles (400 ticks = 60.0 s). Glances,
    /// quirks, flicks, motes and boops are suppressed; only the gentle blink
    /// remains. Taps and crown ticks end the session immediately (G1); a
    /// wrist-drop farewell ends it too (a partial >= 200 ticks still logs).
    private(set) var sessionMode = false
    private var sessionStartTick = 0
    /// Elapsed session ticks (0 when not in a session) — drives the L2
    /// breathe-in/out captions in the shell.
    var sessionElapsedTicks: Int { sessionMode ? tick - sessionStartTick : 0 }
    /// Fired exactly once when a session ends (auto at 400 ticks, or early via
    /// tap/crown/wrist-drop) with the elapsed tick count — the shell logs and
    /// plays the contentment act's aftermath from here.
    var onSessionEnded: (@Sendable (Int) -> Void)?

    func setSessionMode(_ on: Bool) {
        sessionMode = on
        if on {
            sessionStartTick = tick
            moteCell = nil
            scheduledIdle = "breathe"
        }
    }

    private func endSession() {
        guard sessionMode else { return }
        sessionMode = false
        onSessionEnded?(tick - sessionStartTick)
    }

    private func stepSession() {
        let elapsed = tick - sessionStartTick
        if blushTicksLeft > 0 { blushTicksLeft -= 1 }
        if mementoDepositTicksLeft > 0 { mementoDepositTicksLeft -= 1 }
        if !queue.isEmpty {
            queue[0].ticks -= 1
            if queue[0].ticks <= 0 { queue.removeFirst() }
            return
        }
        if elapsed >= BreathSessionController.totalTicks {
            endSession()
            play(BreathSessionController.contentmentAct(archetype))
            return
        }
        scheduledIdle = BreathSessionController.frame(atTick: elapsed)
        // The gentle blink survives the session; everything else is breath.
        if rng.nextFloat() < blinkP, tick - lastBlinkTick >= 3 {
            lastBlinkTick = tick
            play(.blink)
        }
    }

    // MARK: - Workout mode (v21, F6)

    /// True while Aivatar's own workout session runs: the idle floor becomes
    /// a run cycle (no random quirks/glances/motes — the run IS the motion;
    /// splits are the only acts). Frame budget: the run cycle itself is the
    /// motion budget (two frames per stride), and the renderer's draw-skip
    /// memo (v28) means zero redraws between frame changes — no separate
    /// cadence drop exists or is needed.
    private(set) var workoutMode = false
    private(set) var workoutPaceBand = 2
    private(set) var splitCount = 0

    func setWorkoutMode(_ on: Bool, paceBand: Int = 2) {
        workoutMode = on
        if on {
            moteCell = nil
            setWorkoutPaceBand(paceBand)
        }
    }

    /// Pace band 0...5 steers the run cadence (pure mapping, tested).
    func setWorkoutPaceBand(_ band: Int) {
        workoutPaceBand = min(max(band, 0), 5)
    }

    /// Run-cycle length in ticks for a pace band: faster pace, shorter cycle.
    nonisolated static func runCycleTicks(_ paceBand: Int) -> Int {
        max(2, 5 - min(max(paceBand, 0), 5))
    }

    /// The event's cooldown/log kind (LifeEvent carries values; the kind is
    /// what cooldowns and the lifeLog hash key off).
    nonisolated static func kind(of event: LifeEvent) -> LifeEventKind {
        switch event {
        case .calendarSoon: return .calendarSoon
        case .workoutDone: return .workoutDone
        case .sleptWithWatch: return .sleptWithWatch
        case .weatherClass: return .weatherClass
        case .workoutLive: return .workoutLive
        case .split: return .split
        }
    }

    /// Pure mapping: life event -> the archetype's in-character act. Every
    /// F2 kind has an answer for every archetype (parity pinned by tests);
    /// weather/workout-live belong to F3/F6 and answer nil for now.
    nonisolated static func reactionAct(for event: LifeEvent, archetype: Archetype) -> SpriteAct? {
        switch event {
        case .calendarSoon:
            switch archetype {
            case .ember: return .happy        // warm: "you have somewhere to be"
            case .willow: return .slowBlink   // settle-calm
            case .compass: return .quirk      // taps the week grid
            case .prism: return .look         // inspects the new shape of the day
            case .nimbus: return .perk        // notices first — alert tick
            }
        case .workoutDone:
            switch archetype {
            case .ember: return .quirk        // the celebration dance
            case .willow: return .happy
            case .compass: return .happy
            case .prism: return .happy
            case .nimbus: return .perk
            }
        case .sleptWithWatch:
            return .slowBlink                 // "slept beside you" — the soft blink
        case .weatherClass(let classHash):
            guard let klass = ConditionClass.fromHash(classHash) else { return nil }
            return Self.weatherAct(for: klass, archetype: archetype)
        case .workoutLive:
            return nil                        // pace bands steer the run, no act
        case .split(let km):
            return Self.splitCheer(distanceKm: km, archetype: archetype)
        }
    }

    /// The split cheer (F6): one celebratory act per archetype.
    nonisolated static func splitCheer(distanceKm: Int, archetype: Archetype) -> SpriteAct {
        switch archetype {
        case .ember: return .quirk        // a scamper of joy
        case .willow: return .happy
        case .compass: return .perk       // metronome keeps the beat
        case .prism: return .look
        case .nimbus: return .perk
        }
    }

    /// The per-archetype weather answer (F3): the pet's element meets the
    /// actual element — sunny fox warms up, rain makes the frog glad, wind
    /// makes the bird preen. Unknown classes stay neutral (no act).
    nonisolated static func weatherAct(for condition: ConditionClass, archetype: Archetype) -> SpriteAct? {
        switch archetype {
        case .ember:
            switch condition {
            case .sunny, .hot: return .happy        // brighter sparks, bouncier
            case .gray, .cold, .rain: return .slowBlink  // cozy huddle
            case .wind: return .perk
            case .unknown: return nil
            }
        case .willow:
            switch condition {
            case .rain, .sunny: return .happy       // rain: the leaf tell
            case .hot, .cold: return .slowBlink     // shaded / slow
            case .wind: return .look
            case .gray, .unknown: return condition == .unknown ? nil : .slowBlink
            }
        case .compass:
            switch condition {
            case .wind: return .look                // wander jitter
            case .cold: return .slowBlink
            case .unknown: return nil
            default: return .quirk                  // metronome steady
            }
        case .prism:
            switch condition {
            case .hot: return .perk
            case .unknown: return nil
            default: return .look                   // the turret checks the sky
            }
        case .nimbus:
            switch condition {
            case .wind: return .perk                // preen + drift
            case .sunny: return .happy              // brighter pulse
            case .unknown: return nil
            default: return .look
            }
        }
    }

    // MARK: - Acts

    /// Act vocabulary: discrete beats over frame ids.
    nonisolated enum SpriteAct: Sendable {
        case blink, happy, quirk, look, slowBlink, farewell, perk
        /// v31: the idle micro-flick — a 1-tick perk (ear flick / startle).
        case flick
    }

    /// Life-event kinds (v17 F2) — the cooldown/log unit.
    nonisolated enum LifeEventKind: Hashable, Sendable {
        case calendarSoon, workoutDone, sleptWithWatch, weatherClass, workoutLive, split
    }

    /// The authored frame queue for one act (L2 degrades body accents to a
    /// face-readable blink). v17: blinks hold 2 ticks — a 1-tick act is
    /// drained before it can render, so blinks were invisible.
    private func frames(for act: SpriteAct, direction: Int = 0) -> [(frame: String, ticks: Int)] {
        if act == .blink {
            // v31: blink.variance — a chance of a double-blink (blink, gap,
            // blink), the per-animal blink character (nimbus bursts, compass
            // almost never). The refractory still guards the Bernoulli path.
            if blinkVariance > 0, rng.nextFloat() < blinkVariance {
                return [("blink", blinkTicks), ("idle", 1), ("blink", blinkTicks), ("idle", 1)]
            }
            return [("blink", blinkTicks), ("idle", 1)]
        }
        let bodyGated = mode == .reduceMotionL2
        switch act {
        case .blink:
            return [("blink", blinkTicks), ("idle", 1)]
        case .happy:
            return [("happy", 2), ("idle", 2)]
        case .flick:
            // v31: 1-tick perk — reads as an ear flick at the idle rate.
            return [("perk", 1), ("idle", 1)]
        case .quirk:
            // Anticipation from the profile (v28): ember 0.9 -> 2-tick wind-up,
            // willow 0.0 -> none; follow-through settles for 2 ticks.
            if bodyGated {
                return [("blink", blinkTicks), ("idle", 1)]
            }
            var q: [(String, Int)] = []
            if perkWindupTicks > 0 { q.append(("perk", perkWindupTicks)) }
            q += [("quirk", 2), ("idle", 2)]
            return q
        case .look:
            // v28: dart-and-hold instead of a 600 ms stare. v31: the gaze
            // policy shapes the hold — willow's soft look holds 4 ticks,
            // nimbus darts then settles longest (5 idle ticks).
            let hold: Int
            let settle: Int
            switch gazePolicy {
            case .soft: (hold, settle) = (4, 2)
            case .detectThenSettle: (hold, settle) = (2, 5)
            default: (hold, settle) = (2, 2)
            }
            return [(direction < 0 ? "glanceL" : "glanceR", hold), ("idle", settle)]
        case .slowBlink:
            return [("idle", 3), ("blink", 6), ("idle", 2)]
        case .perk:
            return [("perk", 3), ("idle", 2)]
        case .farewell:
            // v16 F1: level 4+ earns a longer goodbye bloom.
            return [("idle", 1), ("blink", blinkTicks), ("sleepy", BondRules.farewellBloomTicks(bondLevel))]
        }
    }

    /// v29 workout mode: hold the current run frame until the cycle turns,
    /// then play the act — the celebration lands on a stride boundary
    /// instead of snapping mid-stride.
    private func playOnStrideBoundary(_ act: SpriteAct) {
        if act != .look, moteCell != nil {
            moteCell = nil
            nextMoteTick = tick + 120 + rng.nextInt(160)
        }
        if act == .blink { blinkCount += 1 }
        let stride = Self.runCycleTicks(workoutPaceBand)
        let hold = max(1, stride - (tick % stride))
        queue = [(scheduledIdleFrame(), hold)] + frames(for: act)
        if act != .blink { actCount += 1 }
    }

    private func play(_ act: SpriteAct, direction: Int = 0) {
        // v28: one focal story — a self-play mote never lingers during an act.
        // A cleared mote is gone for a while, not respawned at once (otherwise
        // act-heavy high-bond idle would spawn motes — and chase looks — faster
        // than low-bond idle).
        if act != .look, moteCell != nil {
            moteCell = nil
            nextMoteTick = tick + 120 + rng.nextInt(160)
        }
        if act == .blink { blinkCount += 1 }
        queue = frames(for: act, direction: direction)
        if act != .blink { actCount += 1 }
    }

    /// v19 F5: a morning-beat sequence plays as one queued run of acts
    /// (<= 5 s total, G1). Any input replaces the queue — the skip path is
    /// a single tap, i.e. <= 150 ms to the stage.
    func playSequence(_ acts: [SpriteAct]) {
        guard !acts.isEmpty else { return }
        markInteraction()
        var q: [(frame: String, ticks: Int)] = []
        for act in acts {
            if act == .blink { blinkCount += 1 }
            q += frames(for: act)
        }
        queue = q
        actCount += acts.count
    }
}
