import Foundation

/// SpriteDirector (v13, Tools/PIXEL_DESIGN.md v5) — the companion's
/// acting brain for the authored sprite stage. The AvatarEngine's FK
/// transforms are gone from the live path: life is DISCRETE POSES on a
/// 150 ms clock — long idle holds, 1-2 tick blinks, rare accent acts —
/// the same grammar measured from real authored pixel mascots, where the
/// only big frame deltas are blinks and everything else moves 2-8 cells.
///
/// Determinism (memory-as-input discipline): a seeded RNG plus a tick
/// counter schedule everything; the same seed steps the same sequence, so
/// sprite goldens and CI rate budgets work exactly like the engine's.
///
/// The RATE budget still comes from PersonalityProfile (the personality
/// is the animal): blink cadence from `gazeProfile.blinkRatePerMin`,
/// event tempo from `motionProfile.tempoScale`, gaze probing from
/// `gazeProfile.saccadeRatePerMin`. Reduce Motion: L1 keeps blinks but
/// drops idle acts; L2 keeps the body still — acts degrade to blink
/// (face-readable, matching the engine's L2 parity contract).
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

    /// The acting queue: (frame id, hold ticks). Non-empty means an act is
    /// playing; empty means idle. Life on idle is per-tick Bernoulli draws
    /// (the engine's §7 discipline — one seeded draw per tick), so the
    /// profile rates land exactly: blink cadence, gaze probes, quirk
    /// events. The units are authored frames, so "one tick" is the whole
    /// animation budget — sparse by construction.
    private var queue: [(frame: String, ticks: Int)] = []
    private(set) var tick = 0
    private(set) var blinkCount = 0
    private(set) var actCount = 0
    /// Rest/always-on: forces the sleepy frame until wake.
    private(set) var resting = false

    init(profile: PersonalityProfile, seed: UInt64) {
        let resolved = Archetype(rawValue: profile.id) ?? .ember
        archetype = resolved
        sprite = AuthoredSprites.sprite(for: resolved)
        rng = SeededRandom(seed ^ 0x51_DE_51_CE)
        blinkP = profile.gazeProfile.blinkRatePerMin / Self.ticksPerMinute
        glanceP = profile.gazeProfile.saccadeRatePerMin / Self.ticksPerMinute * 0.35
        // Idle accent events (quirks): rare by construction — one involuntary
        // signature move every ~75 s, tempo-scaled by personality.
        eventP = 0.8 / Self.ticksPerMinute * profile.motionProfile.tempoScale
    }

    // MARK: - Acting

    /// The frame the stage should draw right now.
    var currentFrame: String {
        if resting { return "sleepy" }
        return queue.first?.frame ?? "idle"
    }

    /// Advances the director clock to `target` ticks (idempotent).
    /// The renderer maps wall-clock elapsed to ticks; nothing else mutates
    /// the schedule between draws.
    func advance(toTick target: Int) {
        while tick < target { step() }
    }

    private func step() {
        tick += 1
        if resting { return }
        if !queue.isEmpty {
            queue[0].ticks -= 1
            if queue[0].ticks <= 0 {
                queue.removeFirst()
            }
            return
        }
        // Idle schedule (draw order fixed: blink, glance, quirk). A firing
        // act preempts idle; the draws only run on idle ticks, so the
        // deterministic sequence is untouched by act lengths.
        if rng.nextFloat() < blinkP {
            play(.blink)
        } else if mode != .reduceMotionL2, rng.nextFloat() < glanceP {
            play(.look, direction: rng.nextFloat() < 0.5 ? -1 : 1)
            actCount += 1
        } else if mode == .full, rng.nextFloat() < eventP {
            play(.quirk)
            actCount += 1
        }
    }

    // MARK: - Events (shares the engine's AvatarEvent vocabulary)

    func handleEvent(_ event: AvatarEvent) {
        switch event {
        case .tap, .crownTick:
            play(.happy)
        case .wake:
            resting = false
            play(.happy)
        case .sleep:
            play(.farewell)
        case .gazeAt(let x, _):
            play(.look, direction: x < 0 ? -1 : 1)
        case .gesture(let name):
            play(gestureAct(named: name))
        }
    }

    func setResting(_ value: Bool) {
        resting = value
        if !value { queue.removeAll() }
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

    // MARK: - Acts

    /// Act vocabulary: discrete beats over frame ids.
    nonisolated enum SpriteAct: Sendable {
        case blink, happy, quirk, look, slowBlink, farewell, perk
    }

    // MARK: - Sound presence (v14, Tools/PIXEL_DESIGN.md §7)

    /// Sound-derived awareness (SoundPresenceLayer events — impure at
    /// capture, pure at digest). Per the sonic reaction map, a startle
    /// plays the animal's authored `perk` pose and a sustained voice plays
    /// its personality acknowledgment. A shared act guard (2.4 s) keeps a
    /// clap storm from ever turning the silent stage into jitter; under
    /// Reduce Motion L2 reactions degrade to the face-readable blink.
    private var lastSoundActTick = -100

    func handleSound(_ event: SoundPresenceEvent) {
        if resting { return }
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
            queue = bodyGated ? [("blink", 1), ("idle", 1)] : [("quirk", 2), ("idle", 2)]
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
