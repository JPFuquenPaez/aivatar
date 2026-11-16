import Foundation

/// CellQuantizer (AMS v2 §5.3, P1): the pixel-honesty gate between continuous
/// envelope math and the 20x18 cell grid. Envelopes may propose continuous
/// amplitudes; NOTHING crosses to the renderer before it steps the cell floor
/// — the v42 failure ("invisible-then-jumpy": 0.22-cell sway and 0.57-degree
/// rotations on a 6.67 Hz clock) cannot recur by construction.
///
/// Rules (all unit-testable, all deterministic):
/// 1. CELL FLOOR — a channel below 1.0 cell of amplitude is deleted (output
///    0), never rounded into a jitter.
/// 2. HOLD RULE — ambient channels keep each quantized state for >= holdTicks
///    ticks; motion is either visible or absent.
/// 3. STEP ECONOMY — an output may move at most 1 cell-step per tick (a
///    reversal must pass through neutral, never snap across).
/// 4. ROTATION BAN — there is no rotation channel at all; parts express tilt
///    through authored shear/pose patches, and this type has no angle output.
///
/// Determinism: a value is a pure fold over the proposal stream — the same
/// inputs step the same outputs, bit-identical (pinned in SpriteFixTests).
nonisolated struct CellQuantizer: Sendable, Equatable {
    /// The last quantized output (cell steps, sign = direction).
    private(set) var output: Int = 0
    /// Ticks since the output last changed (holds; starts "long held").
    private(set) var ticksSinceMove: Int = 1_000_000

    init() {}

    /// One quantizer step. Pure w.r.t. (self, proposal, holdTicks):
    /// returns the current output after applying the rules above.
    /// `holdTicks` is the minimum hold for AMBIENT life (>= 2 by the spec);
    /// act channels may pass 1 and still respect floor + step economy.
    mutating func step(proposal: Double, holdTicks: Int = 2) -> Int {
        let target = Self.quantizedTarget(proposal)
        let clamped = min(output + 1, max(output - 1, target))
        if clamped != output, ticksSinceMove >= max(1, holdTicks) {
            output = clamped
            ticksSinceMove = 0
        } else {
            ticksSinceMove += 1
        }
        return output
    }

    /// The pure floor rule (rule 1): below 1.0 cell -> neutral; at/above it
    /// the sign of the proposal selects the pose direction.
    static func quantizedTarget(_ proposal: Double) -> Int {
        if abs(proposal) < 1.0 { return 0 }
        return proposal > 0 ? 1 : -1
    }
}

/// The ambient TAIL part channel (LPR §5.2: the tail is a cell-space part
/// moved only by CellDiff application). PetMotion proposes the wag envelope
/// in cells; the quantizer steps it with the >=2-tick hold; the director
/// renders the selected authored pose (tailL/neutral/tailR) as overlay diffs.
/// Fully deterministic: bursts come from a seeded SplitMix64 stream
/// (house rule: dedicated stream via seed XOR a private constant), and
/// re-converges to neutral between bursts (the v13 settle rule).
nonisolated struct TailChannel: Sendable {
    private var rng: SeededRandom
    private var quantizer = CellQuantizer()
    private var burstTicksLeft = 0
    private var burstAge = 0
    /// The pose index: -1 (tailL), 0 (neutral), +1 (tailR).
    private(set) var pose: Int = 0

    static let burstTicks = 6

    /// Per-tick wag burst probability (drawn only while idle): one burst
    /// roughly every ~45 s at tempo 1 — a living wag, not a metronome.
    static func wagP(ticksPerMinute: Float, tempoScale: Float) -> Float {
        max(0, 1.3 / ticksPerMinute * max(0.2, tempoScale))
    }

    init(seed: UInt64) {
        rng = SeededRandom(seed ^ 0x7A67_0C0D)   // dedicated tail stream
    }

    /// Advance one tick. `modeAllows` is false while resting, in a breath
    /// session, under Reduce Motion L2, during vapor, or during acts that
    /// own the tail (quirk) — one focal story (G2).
    mutating func step(modeAllows: Bool, ticksPerMinute: Float, tempoScale: Float) -> Int {
        guard modeAllows else {
            burstTicksLeft = 0
            burstAge = 0
            // Still step the quantizer toward neutral so the pose settles.
            _ = quantizer.step(proposal: 0)
            pose = quantizer.output
            return pose
        }
        if burstTicksLeft > 0 {
            burstTicksLeft -= 1
            burstAge += 1
        } else if rng.nextFloat() < Self.wagP(ticksPerMinute: ticksPerMinute, tempoScale: tempoScale) {
            burstTicksLeft = Self.burstTicks + rng.nextInt(3)
            burstAge = 0
        }
        let proposal = burstTicksLeft > 0 ? PetMotion.tailProposal(age: burstAge) : 0
        _ = quantizer.step(proposal: proposal)
        pose = quantizer.output
        return pose
    }
}
