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

    private let sprite: CompanionSprite
    private let archetype: Archetype
    private var rng: SeededRandom
    private let blinkP: Float
    private let glanceP: Float
    private let eventP: Float
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
        weatherHueShiftDeg = dial.hueShiftDeg
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
        weatherDials = profile.weatherDials
        nextMoteTick = 140 + rng.nextInt(160)
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
        updateMoodAndAutonomy()
        if !queue.isEmpty {
            queue[0].ticks -= 1
            if queue[0].ticks <= 0 { queue.removeFirst() }
            return
        }
        // Idle schedule (draw order fixed: blink, glance, quirk). A firing
        // act preempts the floor frame; draws only run on idle ticks.
        scheduledIdle = scheduledIdleFrame()
        // v16 F1: bond biases the idle schedule — higher bond, more signature
        // quirks, fewer glances away (the companion looks at you more).
        let glanceMul: Float = (mood == .bored ? 2 : (mood == .lonely ? 0.3 : 1))
            * BondRules.glanceAwayMultiplier(bondLevel) * weatherGlanceMul
        let eventMul: Float = (mood == .playful ? 2 : (mood == .lonely ? 1.5 : 1))
            * BondRules.quirkRateMultiplier(bondLevel) * weatherTempoMul
        if rng.nextFloat() < blinkP {
            play(.blink)
        } else if mode != .reduceMotionL2, rng.nextFloat() < glanceP * glanceMul {
            play(.look, direction: rng.nextFloat() < 0.5 ? -1 : 1)
            actCount += 1
        } else if mode == .full, rng.nextFloat() < eventP * eventMul {
            play(.quirk)
            actCount += 1
        }
    }

    /// The life floor between acts: one breath every ~2.7 s (2-tick
    /// inhale/exhale window) over a slow idle-variant rotation (~8 s).
    /// L2 pins it to plain idle.
    private func scheduledIdleFrame() -> String {
        guard mode != .reduceMotionL2 else { return "idle" }
        let phase = tick % 18
        if phase == 8 || phase == 9 { return "breathe" }
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
        // never under Reduce Motion L2.
        if mood == .lonely, mode != .reduceMotionL2,
           tick - lastLonelyPokeTick > 240, queue.isEmpty {
            lastLonelyPokeTick = tick
            queue = [("perk", 2), ("blink", 2), ("idle", 2)]
            actCount += 1
        }
        // One yawn per long unattended stretch (90 s idle, 4.5 min cooldown).
        if mode != .reduceMotionL2, sinceInteraction > 600,
           tick - lastYawnTick > 1800, queue.isEmpty {
            lastYawnTick = tick
            queue = [("yawn", 3), ("idle", 2)]
            actCount += 1
        }
        // Self-play mote (v16): full mode only, never while an act plays.
        if mode == .full, queue.isEmpty {
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
        switch event {
        case .tap, .crownTick:
            markInteraction()
            play(.happy)
        case .wake:
            markInteraction()
            resting = false
            lifeActThisWake = false
            play(.happy)
        case .sleep:
            play(.farewell)
        case .gazeAt(let x, _):
            markInteraction()
            play(.look, direction: x < 0 ? -1 : 1)
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
        guard let act = Self.reactionAct(for: event, archetype: archetype) else { return }
        let kind = Self.kind(of: event)
        if lifeActThisWake { return }
        if let last = lastLifeActTick[kind], tick - last < Self.lifeEventCooldownTicks { return }
        lastLifeActTick[kind] = tick
        lifeActThisWake = true
        lifeEventCount += 1
        curiousUntilTick = tick + 200
        if mode == .reduceMotionL2 {
            play(.blink)
        } else {
            play(act)
        }
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
            return nil                        // F6
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
    }

    /// Life-event kinds (v17 F2) — the cooldown/log unit.
    nonisolated enum LifeEventKind: Hashable, Sendable {
        case calendarSoon, workoutDone, sleptWithWatch, weatherClass, workoutLive
    }

    /// The authored frame queue for one act (L2 degrades body accents to a
    /// face-readable blink). v17: blinks hold 2 ticks — a 1-tick act is
    /// drained before it can render, so blinks were invisible.
    private func frames(for act: SpriteAct, direction: Int = 0) -> [(frame: String, ticks: Int)] {
        if act == .blink {
            return [("blink", 2), ("idle", 1)]
        }
        let bodyGated = mode == .reduceMotionL2
        switch act {
        case .blink:
            return [("blink", 2), ("idle", 1)]
        case .happy:
            return [("happy", 2), ("idle", 2)]
        case .quirk:
            // Anticipation (v15): a 1-tick wind-up before the signature move.
            return bodyGated
                ? [("blink", 2), ("idle", 1)]
                : [("perk", 1), ("quirk", 2), ("idle", 1)]
        case .look:
            return [(direction < 0 ? "glanceL" : "glanceR", 4), ("idle", 1)]
        case .slowBlink:
            return [("idle", 3), ("blink", 6), ("idle", 2)]
        case .perk:
            return [("perk", 3), ("idle", 1)]
        case .farewell:
            // v16 F1: level 4+ earns a longer goodbye bloom.
            return [("idle", 1), ("blink", 2), ("sleepy", BondRules.farewellBloomTicks(bondLevel))]
        }
    }

    private func play(_ act: SpriteAct, direction: Int = 0) {
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
