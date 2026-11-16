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
    /// The self-play mote's stage-space bounds (v3: the bounds the puppet
    /// props map onto stage fractions 0...1 — 20x18 kept as the coordinate
    /// vocabulary so the seeded mote goldens are untouched).
    static let moteStageWidth = 20
    static let moteStageHeight = 18

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

    private let archetype: Archetype
    /// The archetype this director acts (drive/hit-routing key).
    var currentArchetype: Archetype { archetype }

    // MARK: - Act tells (v3: pose-channel tells, not cell overlays)

    /// The act the current queue is playing (nil once it settles).
    private(set) var currentAct: SpriteAct?
    /// The wrist-raise greeting sequence plays (pupils up at the user,
    /// weather ceremony, happy blink — then settles).
    private(set) var greetingActive = false
    /// Nimbus's songburst (a sustained voice just came in).
    private(set) var songburstActive = false
    /// E7 boop flush on.
    var blushing: Bool { blushTicksLeft > 0 }
    /// The boop pulse's first tick (the squash-and-glow beat).
    var boopPulse: Bool { blushTicksLeft == Self.blushDurationTicks }
    private var lastGreetTick = -100_000
    /// The slow-blink ritual (long-press petting) is mid-run.
    var slowBlinkActive: Bool { currentAct == .slowBlink && !queue.isEmpty }

    /// v3 (doc §5.5): the wrist-raise greeting — a 600 ms sequence: perk
    /// (pupils snap up at the user), the happy blink, tail swing. Input-
    /// driven only (never the idle scheduler), so the act goldens hold.
    /// Rate-capped at 20 ticks (3 s) so wake storms queue one greeting.
    func greet() {
        guard !resting, !sessionMode, tick - lastGreetTick >= 20 else { return }
        lastGreetTick = tick
        markInteraction()
        currentAct = nil
        greetingActive = true
        songburstActive = false
        blinkCount += 1
        queue = [("perk", 1), ("happy", 2), ("blink", blinkTicks), ("idle", 1)]
        actCount += 1
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

    /// A face tap landed (hit math done by the caller via
    /// PuppetDrawing.headHitCircle — one geometry source with the stage).
    /// Returns true when the boop was accepted: ack act (happy squint) plays
    /// within <= 2 ticks and the 6-tick blush overlay starts. Suppressed while
    /// resting or during a breath session.
    @discardableResult
    func boopFace() -> Bool {
        guard !resting, !sessionMode,
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

    /// Schedules a one-shot demonstration act (E5). Suppressed during a
    /// breath session; fires as soon as the queue is free and the settle
    /// delay has passed.
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

    // MARK: - The seeded schedule (SplitMix64, memory-as-input)

    private var rng: SeededRandom
    /// The raw stream seed (the v3 ambient phases are pure functions of
    /// display time; the seed stays the journey-visible identity of the
    /// director's stochastic schedule).
    nonisolated let seed: UInt64
    /// Ticks the current frame has been showing (act envelopes key on this).
    private(set) var frameAge = 0
    private let blinkP: Float
    private let glanceP: Float
    private let eventP: Float
    /// v31: the low-rate idle micro-flick (ear/perk flick) — deterministic
    /// Bernoulli, tempo-scaled like the quirk rate.
    private let flickP: Float
    /// v1.3 §5.14B.4: the surprise scheduler (the Snoopy decision-engine
    /// pattern) — rare micro-events on a DEDICATED rng stream (the main
    /// schedule's draws are untouched), recency-weighted so the event that
    /// fired longest ago is likeliest, with a minimum gap per kind.
    private var surpriseRng: SeededRandom
    private var lastSurpriseTick: [Int] = [0, 0, 0]   // flick, lookL, lookR
    /// Every surprise fired (test-visible: kind, tick — irregularity + min gap).
    private(set) var surpriseFires: [(kind: Int, tick: Int)] = []
    /// Min gap between surprises of one kind (ticks): ~36 s.
    static let surpriseMinGapTicks = 240
    /// Per-idle-tick surprise probability (~1 per 2.25 min at full mode).
    static let surpriseP: Float = 1.0 / 900.0
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
        self.seed = seed
        archetype = resolved
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
        surpriseRng = SeededRandom(seed ^ 0x5EED_5EED)
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
        let before = currentFrame
        tick += 1
        stepBody()
        frameAge = (currentFrame == before) ? frameAge + 1 : 1
    }

    private func stepBody() {
        if resting { return }
        if vaporOnTicksLeft > 0 { vaporOnTicksLeft -= 1 }  // E9.2 puff lifetime
        if blushTicksLeft > 0 { blushTicksLeft -= 1 }      // E7 flush lifetime
        // E8 session grammar runs instead of the idle schedule entirely.
        if sessionMode { stepSession(); return }
        updateMoodAndAutonomy()
        if !queue.isEmpty {
            queue[0].ticks -= 1
            if queue[0].ticks <= 0 { queue.removeFirst() }
            if queue.isEmpty { clearActTells() }
            return
        }
        // E5: a due ceremony plays as soon as the queue is free (suppressed
        // during a breath session — one intention at a time).
        if mementoDepositTicksLeft > 0 { mementoDepositTicksLeft -= 1 }
        if !pendingCeremonies.isEmpty, !sessionMode,
           let i = pendingCeremonies.firstIndex(where: { $0.atTick <= tick }) {
            let ceremony = pendingCeremonies.remove(at: i)
            play(ceremony.act)
            return
        }
        // E9.2 vapor scheduling: cold class only, awake + full mode, queue
        // free. On 3 ticks, then hidden >= 33 ticks (gap drawn from the
        // dedicated vapor stream).
        if mode == .full, !sessionMode,
           condition == .cold, queue.isEmpty,
           vaporOnTicksLeft == 0, tick >= vaporNextTick {
            vaporOnTicksLeft = Self.vaporOnTicks
            vaporNextTick = tick + Self.vaporOnTicks + Self.vaporMinHiddenTicks + vaporRng.nextInt(60)
        }
        // Idle schedule (draw order fixed: blink, glance, quirk, flick). A
        // firing act preempts the floor frame; draws only run on idle ticks.
        scheduledIdle = scheduledIdleFrame()
        let effBlinkP = blinkP
        let effGlanceP = glanceP
        // v16 F1: bond biases the idle schedule — higher bond, more signature
        // quirks, fewer glances away (the companion looks at you more).
        let glanceMul: Float = (mood == .bored ? 2 : (mood == .lonely ? 0.3 : 1))
            * BondRules.glanceAwayMultiplier(bondLevel) * weatherGlanceMul
        let eventMul: Float = (mood == .playful ? 2 : (mood == .lonely ? 1.5 : 1))
            * BondRules.quirkRateMultiplier(bondLevel) * weatherTempoMul
        if rng.nextFloat() < effBlinkP, tick - lastBlinkTick >= 3 {
            lastBlinkTick = tick
            play(.blink)
        } else if mode != .reduceMotionL2,
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
        } else if mode == .full, !vaporActive,
                  rng.nextFloat() < eventP * eventMul {
            play(.quirk)
            actCount += 1
        } else if mode == .full, !vaporActive, rng.nextFloat() < flickP {
            // v31: idle micro-flick — a 1-tick perk reads as an ear flick at
            // this rate, not an alert. Negligible motion-budget cost.
            play(.flick)
            actCount += 1
        } else if mode == .full, !vaporActive, surpriseDue() {
            // v1.3 §5.14B.4: a recency-weighted surprise micro-event — the
            // idle is non-periodic ("full of surprises each time you check").
            fireSurprise()
        }
    }

    /// v1.3 §5.14B.4: surprise due? Dedicated stream, so the main schedule's
    /// draws (and its goldens) are untouched. Recency-weighted: each kind's
    /// weight grows with the time since it last fired, gated by a min gap.
    private func surpriseDue() -> Bool {
        var weights: [Float] = []
        for kind in 0..<3 {
            let since = Float(tick - lastSurpriseTick[kind])
            weights.append(since >= Float(Self.surpriseMinGapTicks) ? 1 + since / Float(Self.surpriseMinGapTicks) : 0)
        }
        let total = weights.reduce(0, +)
        guard total > 0, surpriseRng.nextFloat() < Self.surpriseP * total / 3 else { return false }
        return true
    }

    /// Fires one surprise, chosen recency-first among the due kinds.
    private func fireSurprise() {
        var due: [Int] = []
        for kind in 0..<3 where Float(tick - lastSurpriseTick[kind]) >= Float(Self.surpriseMinGapTicks) {
            due.append(kind)
        }
        guard let kind = due.max(by: { lastSurpriseTick[$0] < lastSurpriseTick[$1] }) else { return }
        lastSurpriseTick[kind] = tick
        surpriseFires.append((kind, tick))
        switch kind {
        case 0: play(.flick)                       // an ear flick
        case 1: lastGazeDir = -1; play(.look, direction: -1)
        default: lastGazeDir = 1; play(.look, direction: 1)
        }
        actCount += 1
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
                    mote.x = min(max(mote.x + moteDriftX, 0), SpriteDirector.moteStageWidth - 1)
                    mote.y = min(max(mote.y + moteDriftY, 0), SpriteDirector.moteStageHeight - 1)
                    moteCell = mote
                }
                if moteTicksLeft <= 0 {
                    moteCell = nil
                    // F1: a bonded companion glances away less — mote self-play
                    // (the glance at the mote) scales down with bond too.
                    nextMoteTick = tick + Int(Float(200 + rng.nextInt(200)) * weatherMoteMul
                                              / BondRules.glanceAwayMultiplier(bondLevel))
                }
            } else if tick >= nextMoteTick {
                let edge = rng.nextInt(4)
                let pos: (x: Int, y: Int)
                switch edge {
                case 0: pos = (rng.nextInt(SpriteDirector.moteStageWidth), 0)
                case 1: pos = (rng.nextInt(SpriteDirector.moteStageWidth), SpriteDirector.moteStageHeight - 1)
                case 2: pos = (0, rng.nextInt(SpriteDirector.moteStageHeight))
                default: pos = (SpriteDirector.moteStageWidth - 1, rng.nextInt(SpriteDirector.moteStageHeight))
                }
                moteCell = pos
                moteTicksLeft = 24
                moteDriftX = rng.nextInt(3) - 1
                moteDriftY = rng.nextInt(3) - 1
                play(.look, direction: pos.x < SpriteDirector.moteStageWidth / 2 ? -1 : 1)
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
            case .nimbus:                            // the songburst answer
                play(.happy)
                songburstActive = true
            case .lumen: play(.slowBlink)             // the moth listens softly
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
        let cooldown = Self.lifeEventCooldownTicks
        if let last = lastLifeActTick[kind], tick - last < cooldown { return }
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
        if mementoDepositTicksLeft > 0 { mementoDepositTicksLeft -= 1 }
        if !queue.isEmpty {
            queue[0].ticks -= 1
            if queue[0].ticks <= 0 { queue.removeFirst() }
            if queue.isEmpty { clearActTells() }
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

    /// The event's cooldown/log kind (LifeEvent carries values; the kind is
    /// what cooldowns and the lifeLog hash key off).
    nonisolated static func kind(of event: LifeEvent) -> LifeEventKind {
        switch event {
        case .calendarSoon: return .calendarSoon
        case .workoutDone: return .workoutDone
        case .sleptWithWatch: return .sleptWithWatch
        case .weatherClass: return .weatherClass
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
            case .lumen: return .happy        // drifts in, warm
            }
        case .workoutDone:
            switch archetype {
            case .ember: return .quirk        // the celebration dance
            case .willow: return .happy
            case .compass: return .happy
            case .prism: return .happy
            case .nimbus: return .perk
            case .lumen: return .slowBlink    // the night-blink
            }
        case .sleptWithWatch:
            return .slowBlink                 // "slept beside you" — the soft blink
        case .weatherClass(let classHash):
            guard let klass = ConditionClass.fromHash(classHash) else { return nil }
            return Self.weatherAct(for: klass, archetype: archetype)
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
        case .lumen:
            switch condition {
            case .cold, .gray: return .slowBlink   // cozy night
            case .wind: return .perk                // wings flutter
            case .sunny, .hot: return .look         // hides from the light
            case .unknown: return nil
            default: return .quirk                  // the shimmer
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
        case calendarSoon, workoutDone, sleptWithWatch, weatherClass
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
            // v1.3 §5.14B.2: two-phase quirk — the poser holds the
            // anticipation pose on frameAge 1-2 and launches at 3+.
            q += [("quirk", 4), ("idle", 2)]
            return q
        case .look:
            // v28: dart-and-hold instead of a 600 ms stare. v31: the gaze
            // policy shapes the hold — willow's soft look holds 4 ticks,
            // nimbus darts then settles longest (5 idle ticks).
            let hold: Int
            let settle: Int
            switch gazePolicy {
            case .soft, .linger: (hold, settle) = (4, 2)
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
        currentAct = act
        // A new act supersedes the transient act-tells (one story, G2).
        greetingActive = false
        songburstActive = false
        queue = frames(for: act, direction: direction)
        if act != .blink { actCount += 1 }
    }

    /// Clears the act-tell flags once the queue settles.
    private func clearActTells() {
        currentAct = nil
        greetingActive = false
        songburstActive = false
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
        currentAct = acts.last
        greetingActive = false
        songburstActive = false
        queue = q
        actCount += acts.count
    }

    // MARK: - Puppet drive (v3: the renderer's flattened view of the brain)

    /// Advances to `target` (idempotent) and returns the drive snapshot for
    /// the puppet poser — one pure mapping, so the watch stage and every
    /// offline consumer (postcards, icons, tests) see the same animal.
    func puppetDrive(atTick target: Int) -> PuppetDrive {
        advance(toTick: target)
        var drive = PuppetDrive(archetype: archetype, frameID: currentFrame)
        drive.frameAge = frameAge
        drive.tick = tick
        drive.mood = {
            switch mood {
            case .calm: return .calm
            case .curious: return .curious
            case .bored: return .bored
            case .lonely: return .lonely
            case .playful: return .playful
            }
        }()
        drive.bondLevel = bondLevel
        drive.condition = condition
        drive.resting = resting
        drive.greeting = greetingActive
        drive.slowBlink = slowBlinkActive
        drive.songburst = songburstActive
        drive.blushing = blushing
        drive.boopPulse = boopPulse
        drive.vapor = vaporActive
        drive.mementoAlpha = Double(mementoDepositAlpha ?? 0)
        drive.mementoSteady = interiority.confidantMemento && mementoDepositAlpha == nil
        if let mote = moteCell {
            drive.moteX = mote.x
            drive.moteY = mote.y
        }
        drive.interiority = interiority
        drive.lastGazeDir = lastGazeDir
        drive.motionFloor = mode == .reduceMotionL2 ? .lidsOnly : .full
        drive.hueShiftDeg = Double(weatherHueShiftDeg)
        return drive
    }
}

extension SpriteDirector: PuppetLiveDriver {
    nonisolated var puppetTickDuration: Double { Self.tickDuration }
    nonisolated var puppetArchetype: Archetype { currentArchetype }
    nonisolated var puppetIsResting: Bool { resting }
}
