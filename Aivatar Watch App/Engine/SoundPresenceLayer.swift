import Foundation

/// SoundPresenceEvent (v14, Tools/PIXEL_DESIGN.md v5 §7 — sonic presence):
/// the two awareness signals a companion needs. Impure at capture (the
/// mic), PURE at digest: the director maps these to authored acts, and CI
/// feeds synthetic loudness fixtures to pin the exact schedules and rate
/// budgets — the same discipline as the blink/saccade Bernoulli draws.
nonisolated enum SoundPresenceEvent: Sendable, Equatable {
    /// A transient spike over the ambient envelope — a clap, a tap, a
    /// knock near the watch.
    case onset
    /// Sustained voice-band energy (~1.5 s+) after a quiet baseline —
    /// the human commonly known as "you" is talking nearby.
    case voiceSustained
}

/// SoundPresenceLayer: turns a decimated RMS loudness stream (one value
/// per 50 ms tick, 0...1) into at most a handful of `SoundPresenceEvent`s
/// per minute. Deliberately tiny — ~30 lines of DSP, no ML, no buffers
/// retained (nothing to persist, ever):
///
/// - a leaky ambient envelope (fast attack, slow decay) normalizes the
///   level, so the stage reacts to CHANGE, not loudness (constant rain,
///   traffic or music-with-no-transients produces zero events);
/// - onsets fire when the level jumps well above the envelope, with a
///   hard refractory (1.2 s) that bounds the reaction rate by construction;
/// - voiceSustained fires only for a mid-band rise out of a quiet
///   baseline, arming for ~1 s of near-silence and disarming for 10 s
///   after each acknowledgment.
///
/// The layer is equally usable for CI (synthetic fixtures) and the live
/// mic source (MicrophonePresenceSource) — determinism lives here.
nonisolated final class SoundPresenceLayer {
    /// One layer tick (the loudness stream cadence).
    static let tickDuration: Double = 0.05

    // Ambient envelope (leaky integrator): fast attack, slow decay.
    private var env: Float = 0
    // Voice detector state.
    private var voiceRun = 0
    private var quietRun = 0
    private var voiceArmed = false
    private var voiceRefractory = 0
    // Onset detector state.
    private var onsetRefractory = 0
    private(set) var tick = 0

    // Thresholds (calibrated for watch-mic RMS at conversation distance).
    /// Onset: the level must exceed the envelope by this much AND clear
    /// an absolute floor (wrist friction is below it).
    private let onsetEnvJump: Float = 0.12
    private let onsetLevelFloor: Float = 0.15
    private let onsetRefractoryTicks = 24        // 1.2 s
    /// Voice: sustained mid-band level for at least ~1.5 s, rising from
    /// a quiet baseline (~1 s below the floor). The band ceiling keeps
    /// constant loud ambience (traffic, engines, crowds) OUT of the
    /// voice detector — it disarms instead of saturating.
    private let voiceFloor: Float = 0.06
    private let voiceBandCeil: Float = 0.25
    private let voiceMinTicks = 30               // 1.5 s
    private let voiceArmQuietTicks = 20          // 1.0 s
    private let voiceRefractoryTicks = 200       // 10.0 s

    init() {}

    /// Processes one loudness sample (RMS, 0...1) and returns any events
    /// fired on this tick.
    func process(level: Float) -> [SoundPresenceEvent] {
        tick += 1
        var events: [SoundPresenceEvent] = []
        let clamped = min(max(level, 0), 1)

        // Ambient envelope: attack 0.5, decay 0.08 per tick.
        if clamped > env {
            env += (clamped - env) * 0.5
        } else {
            env += (clamped - env) * 0.08
        }

        // --- Onset: transient over the envelope, hard rate bound.
        if onsetRefractory > 0 { onsetRefractory -= 1 }
        if onsetRefractory == 0,
           clamped - env > onsetEnvJump, clamped >= onsetLevelFloor {
            onsetRefractory = onsetRefractoryTicks
            events.append(.onset)
        }

        // --- Voice: sustained mid-band rise out of quiet.
        if voiceRefractory > 0 {
            voiceRefractory -= 1
            voiceRun = 0
            quietRun = 0
            voiceArmed = false
        } else if clamped < voiceFloor {
            voiceRun = 0
            quietRun += 1
            if quietRun >= voiceArmQuietTicks { voiceArmed = true }
        } else if clamped <= voiceBandCeil {
            quietRun = 0
            if voiceArmed { voiceRun += 1 }
            if voiceRun >= voiceMinTicks {
                voiceRun = 0
                voiceArmed = false
                voiceRefractory = voiceRefractoryTicks
                events.append(.voiceSustained)
            }
        } else {
            // A sudden very loud wall disarms the voice detector — you
            // cannot have a conversation inside a blender.
            voiceRun = 0
            voiceArmed = false
            quietRun = 0
        }
        return events
    }
}
