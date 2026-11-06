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
    private var mode: MotionAccessibilityMode = .full

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

    init(profile: PersonalityProfile, seed: UInt64) {
        let resolved = Archetype(rawValue: profile.id) ?? .ember
        archetype = resolved
        sprite = AuthoredSprites.sprite(for: resolved)
        rng = SeededRandom(seed ^ 0x51_DE_51_CE)
        blinkP = profile.gazeProfile.blinkRatePerMin / Self.ticksPerMinute
        glanceP = profile.gazeProfile.saccadeRatePerMin / Self.ticksPerMinute * 0.35
        eventP = 0.8 / Self.ticksPerMinute * profile.motionProfile.tempoScale
        nextMoteTick = 140 + rng.nextInt(160)
    }

    // MARK: - Reading state

    /// The frame the stage should draw right now.
    var currentFrame: String {
        if resting { return "sleepy" }
        return queue.first?.frame ?? scheduledIdle
    }

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
        let glanceMul: Float = mood == .bored ? 2 : (mood == .lonely ? 0.3 : 1)
        let eventMul: Float = mood == .playful ? 2 : (mood == .lonely ? 1.5 : 1)
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
            queue = [("perk", 2), ("blink", 1), ("idle", 2)]
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
                    nextMoteTick = tick + 200 + rng.nextInt(200)
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

    // MARK: - Acts

    /// Act vocabulary: discrete beats over frame ids.
    nonisolated enum SpriteAct: Sendable {
        case blink, happy, quirk, look, slowBlink, farewell, perk
    }

    private func play(_ act: SpriteAct, direction: Int = 0) {
        if act == .blink {
            queue = [("blink", 1), ("idle", 1)]
            blinkCount += 1
            return
        }
        // Face readability under Reduce Motion L2: body accents degrade.
        let bodyGated = mode == .reduceMotionL2
        switch act {
        case .blink:
            break  // handled above
        case .happy:
            queue = [("happy", 2), ("idle", 2)]
        case .quirk:
            // Anticipation (v15): a 1-tick wind-up before the signature move.
            queue = bodyGated
                ? [("blink", 1), ("idle", 1)]
                : [("perk", 1), ("quirk", 2), ("idle", 1)]
        case .look:
            queue = [(direction < 0 ? "glanceL" : "glanceR", 4), ("idle", 1)]
        case .slowBlink:
            queue = [("idle", 3), ("blink", 6), ("idle", 2)]
        case .perk:
            queue = [("perk", 3), ("idle", 1)]
        case .farewell:
            queue = [("idle", 1), ("blink", 2), ("sleepy", 12)]
        }
        actCount += 1
    }
}
