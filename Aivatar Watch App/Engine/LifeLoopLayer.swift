import Foundation

/// L1 — Life loops (§7).
///
/// Always-on in active mode: breathing (chest scale), micro-sway, posture
/// wander, plus stochastic blinks and saccades from the gaze profile. All
/// stochastic triggers advance one per-frame Bernoulli draw each frame
/// (per-tick probability `lambda * dt`), so same seed -> same behavior.
nonisolated final class LifeLoopLayer {
    private let profile: PersonalityProfile
    private var rng: SeededRandom
    /// Posture-wander stream (v4 "alive" pass): a SEPARATE seeded stream so
    /// the blink/saccade Bernoulli schedules — pinned by the rate-budget
    /// tests — are untouched by the wander draws.
    private var wanderRng: SeededRandom

    // Rates as per-frame probabilities (lambda * dt, §7 Poisson model).
    private let blinkP: Float
    private let saccadeP: Float

    // Gaze state.
    private var gazeX: Float = 0
    private var gazeY: Float = 0
    private var gazeTargetX: Float = 0
    private var gazeTargetY: Float = 0
    private var gazeSpeed: Float = 0.15
    private var headFollow: Float = 0
    /// Fixation hold (v3 audit finding 6: darts without holds read
    /// "shifty"). After a saccade lands, no new saccade may start until the
    /// hold expires — look -> hold 400-900 ms -> release.
    private var gazeHoldFrames = 0
    /// Compass's lighthouse sweep alternates user/away on a fixed period.
    private var sweepTowardAway = false

    /// Named idle gaze targets from the profile (§5 gaze profile), resolved
    /// to pupil offsets in rig points: each archetype's saccades land on its
    /// own target set (Ember glances up, Nimbus darts down, ...).
    private let gazeTargets: [(x: Float, y: Float)]

    // Blink state.
    private var blinkFramesLeft = 0
    /// Total length of the current blink envelope (scaled by the v3 blink
    /// grammar — Willow's blinks are watchable, Ember's almost missed).
    private var blinkTotal = 10
    /// Close phase of the blink envelope, frames (scales with the total).
    private var blinkCloseFrames = 4
    private var lastBlinkFrame = -1000
    /// Total blinks triggered (CI rate-budget assertions, §7/§11).
    private(set) var blinkCount = 0
    /// Envelope frames of the most recent blink (CI blink-grammar tests).
    private(set) var lastBlinkEnvelopeFrames = 0

    // Nimbus quirk: higher blink variance via a slow-modulated rate.
    private let blinkVariance: Float

    // Posture wander (v4 "alive" pass, avatarro-inspired): every few
    // seconds the body eases toward a NEW random posture target — lean,
    // tilt, bob depth — so the avatar never settles into a visible loop
    // and never reads static between idle gestures. Per-archetype grammar
    // rides the gaze policy (the personality carrier): Ember shifts often
    // and quick, Willow drifts slow and deep, Compass resets on a
    // metronome (small, exact), Prism's intervals are irregular by
    // design, Nimbus floats the most.
    private var wanderFramesLeft = 0
    private var wanderTargetLeanRot: Float = 0
    private var wanderTargetLeanX: Float = 0
    private var wanderTargetTilt: Float = 0
    private var wanderLeanRot: Float = 0
    private var wanderLeanX: Float = 0
    private var wanderTilt: Float = 0
    private var wanderEase: Float = 0.05
    private var wanderAmp: Float = 1
    private var wanderInterval: Int = 120

    /// v3 grammar: gaze policy + blink shape + idle drift (schema v2; the
    /// v1 traits remain the fallback so a v1 profile still behaves).
    private let gazePolicy: GazePolicy
    private let blinkDurationScale: Float
    private let driftScale: Float

    init(profile: PersonalityProfile, seed: UInt64) {
        self.profile = profile
        rng = SeededRandom(seed ^ 0x1_1F_E0_00)
        wanderRng = SeededRandom(seed ^ 0x4A_11_00_2E)
        blinkP = profile.gazeProfile.blinkRatePerMin / 1800.0
        saccadeP = profile.gazeProfile.saccadeRatePerMin / 1800.0
        blinkVariance = profile.blink?.variance ?? profile.traitVector.neuroticism
        gazePolicy = profile.gazePolicy ?? .wander
        blinkDurationScale = profile.blink?.durationScale ?? 1.0
        driftScale = profile.motionGrammar.map { 0.6 + 0.8 * $0.drift }
            ?? 1.0
        gazeTargets = Self.resolveTargets(profile.gazeProfile.idleGazeTargets)
        // Wander grammar per archetype (gaze policy = the carrier).
        switch gazePolicy {
        case .lock:
            // Ember: frequent, quick, springy shifts.
            wanderInterval = 75
            wanderEase = 0.10
            wanderAmp = 1.25
        case .soft:
            // Willow: slow, deep, continuous drift.
            wanderInterval = 165
            wanderEase = 0.012
            wanderAmp = 1.1
        case .metricSweep:
            // Compass: exact metronome resets, small and tidy.
            wanderInterval = 120
            wanderEase = 0.09
            wanderAmp = 0.7
        case .wander:
            // Prism: irregular by design — intervals redrawn per cycle.
            wanderInterval = 100
            wanderEase = 0.05
            wanderAmp = 1.35
        case .detectThenSettle:
            // Nimbus: the floater — biggest gentle wander.
            wanderInterval = 100
            wanderEase = 0.035
            wanderAmp = 1.6
        }
    }

    private static func resolveTargets(_ names: [String]) -> [(x: Float, y: Float)] {
        var targets = names.map { name -> (Float, Float) in
            switch name {
            case "away": return (-2.6, 0.3)
            case "user": return (0, 0)
            case "up": return (0, -2.2)
            case "down": return (0, 2.0)
            default: return (0, 0)
            }
        }
        if targets.isEmpty { targets = [(0, 0)] }
        return targets
    }

    /// Advances one frame; writes additive contributions into `pose`.
    func step(into pose: inout AvatarPose, frame: Int, bones: BoneMap, expressions: inout [Float]) {
        let t = Float(frame) / 30.0

        // --- Breathing: chest scale, ~20 cycles/min baseline, tempo-scaled.
        // Amplitude floor 0.07: at screen fit ~1.78 pt/rig-unit a 10% chest
        // scale moves the rib silhouette ~10 pt (~20 px) per breath cycle —
        // the "is it alive?" signal. Verified against the §11 continuity
        // budget with ~2 orders of magnitude of headroom (slow sinusoid).
        let breatheRate = Float.pi * 2.0 * 0.33 * profile.motionProfile.tempoScale
        let breath = (sin(t * breatheRate) + 1) * 0.5
        let amp = 0.07 + 0.035 * profile.motionProfile.amplitudeScale
        pose.scalesX[bones.chest] = 1 + breath * amp
        pose.scalesY[bones.chest] = 1 - breath * amp * 0.4
        pose.rotations[bones.chest] += sin(t * breatheRate + 0.4) * 0.02

        // --- Micro-sway: slow full-body rotation around the hips. 0.035 rad
        // swings the head (~100 units above the hips) ~3.5 units lateral per
        // half-cycle — a visible drift, still under 0.03 rad/frame. The v3
        // drift grammar scales it per temperament (Nimbus floats the most,
        // Compass barely moves).
        pose.rotations[bones.hips] += sin(t * 0.55) * 0.035 * profile.motionProfile.amplitudeScale * driftScale
        pose.offsetsY[bones.hips] += sin(t * 1.1) * 1.6 * driftScale

        // v11 motion budget (PIXEL_DESIGN.md v4): the heartbeat shimmer is
        // REMOVED. It lived on the head — the focal point — where a
        // ~0.2-art-pixel tremor reads as jitter, not life. Life on the
        // stage is carried by breathing, sway, posture wander, gaze and
        // blinks; the body keeps its pulse through the wander-modulated
        // breathing depth below.

        // --- Posture wander (v4 "alive" pass): draw a new random posture
        //     target when the current one expires, then ease toward it.
        //     Independent seeded stream -> the blink/saccade schedules are
        //     untouched. Written AFTER the sway/heartbeat contributions
        //     so it composes with them (additive, L1 never replaces).
        if wanderFramesLeft <= 0 {
            wanderFramesLeft = wanderInterval
            if gazePolicy == .wander {
                // Prism: irregular by design — redraw the interval itself
                // (1.5-7 s), never a fixed loop.
                wanderFramesLeft = 45 + Int(wanderRng.nextFloat() * 165)
            }
            let amp = wanderAmp * driftScale
            wanderTargetLeanRot = wanderRng.nextSignedFloat() * 0.030 * amp
            wanderTargetLeanX = wanderRng.nextSignedFloat() * 1.4 * amp
            wanderTargetTilt = wanderRng.nextSignedFloat() * 0.045 * amp
        }
        wanderFramesLeft -= 1
        let ease = wanderEase
        wanderLeanRot += (wanderTargetLeanRot - wanderLeanRot) * ease
        wanderLeanX += (wanderTargetLeanX - wanderLeanX) * ease
        wanderTilt += (wanderTargetTilt - wanderTilt) * ease
        pose.rotations[bones.hips] += wanderLeanRot
        pose.offsetsX[bones.hips] += wanderLeanX
        pose.rotations[bones.spineLower] += wanderTilt

        // --- Saccades: policy-driven (v3 grammar). Every policy lands a
        //     fixation hold after a shift — look -> hold 400-900 ms ->
        //     release — so no archetype reads "shifty" (audit finding 6).
        //     The RNG draws only on frames where a saccade is allowed, so
        //     the deterministic schedule is untouched by the policy gate.
        if gazeHoldFrames > 0 {
            gazeHoldFrames -= 1
        }
        let saccadeAllowed = gazeHoldFrames == 0
        switch gazePolicy {
        case .metricSweep:
            // Compass lighthouse sweep: alternate user <-> away at a fixed
            // 5 s period — metronomic, zero-variance, no RNG draws at all.
            if frame % 150 == 0 {
                sweepTowardAway.toggle()
                if sweepTowardAway, let away = gazeTargets.first(where: { $0.x < 0 }) {
                    gazeTargetX = away.x
                    gazeTargetY = away.y
                } else {
                    gazeTargetX = 0
                    gazeTargetY = 0
                }
                gazeSpeed = 0.35
                headFollow = 0.03
                gazeHoldFrames = 150 // the period is the hold
            }
        case .lock, .soft, .wander, .detectThenSettle:
            guard saccadeAllowed, rng.nextFloat() < saccadeP * (gazePolicy == .detectThenSettle ? 1.3 : 1.0) else { break }
            let pick = min(rng.nextFloat() * Float(gazeTargets.count), Float(gazeTargets.count - 1))
            var target = gazeTargets[Int(pick)]
            switch gazePolicy {
            case .lock:
                // Ember: mostly straight at you; a lock, not a beg.
                if rng.nextFloat() < 0.8 { target = (0, 0) }
            case .soft:
                // Willow: looks *near* you, not at you.
                target = (target.x * 0.35, target.y * 0.35 + rng.nextSignedFloat() * 0.4)
            default:
                break
            }
            gazeTargetX = target.x + rng.nextSignedFloat() * 0.8
            gazeTargetY = target.y + rng.nextSignedFloat() * 0.5
            switch gazePolicy {
            case .lock:
                gazeSpeed = 0.45 + rng.nextFloat() * 0.2
                gazeHoldFrames = 20 + Int(rng.nextFloat() * 7)
            case .soft:
                gazeSpeed = 0.07 + rng.nextFloat() * 0.05
                gazeHoldFrames = 30 + Int(rng.nextFloat() * 10)
            case .wander:
                gazeSpeed = 0.15 + rng.nextFloat() * 0.35 * profile.motionProfile.tempoScale
                gazeHoldFrames = 6 + Int(rng.nextFloat() * 15)
            case .detectThenSettle:
                // Fastest dart of the five, then the longest settle.
                gazeSpeed = 0.5 + rng.nextFloat() * 0.15
                gazeHoldFrames = 30 + Int(rng.nextFloat() * 15)
            default:
                break
            }
            if rng.nextFloat() < profile.gazeProfile.headPropensity {
                headFollow = rng.nextSignedFloat() * 0.06
            } else {
                headFollow = 0
            }
        }
        gazeX += (gazeTargetX - gazeX) * gazeSpeed
        gazeY += (gazeTargetY - gazeY) * gazeSpeed
        pose.offsetsX[bones.pupilL] += gazeX
        pose.offsetsX[bones.pupilR] += gazeX
        pose.offsetsY[bones.pupilL] += gazeY
        pose.offsetsY[bones.pupilR] += gazeY
        pose.rotations[bones.neck] += (gazeX + gazeY * 0.5) * 0.004
        pose.rotations[bones.head] += headFollow

        // --- Blinks: per-tick Bernoulli draw; variance scales the rate
        //     window (Nimbus bursts and long stills). The v3 blink grammar
        //     shapes the envelope: durationScale stretches the whole
        //     close-open arc (Willow's blink is one you can watch happen;
        //     Ember's is almost missed). Blink is a close-open envelope,
        //     quick enough to read as a blink, slow enough that lid travel
        //     stays inside the per-frame continuity budget (§11). Gaze-evoked
        //     blink cadence stays stochastic.
        let varianceMod = 1.0 + sin(t * 0.15) * 0.45 * blinkVariance
        let effectiveBlinkP = blinkP * varianceMod
        if blinkFramesLeft == 0 && rng.nextFloat() < effectiveBlinkP {
            // Envelope floor 10 frames with a >= 4-frame close phase: the
            // lid travel (5.5 units + the mixer's rest-channel ramp) stays
            // inside the per-frame continuity budget (§11, 2.5 units/frame).
            blinkTotal = max(10, Int(Float(10) * blinkDurationScale))
            blinkCloseFrames = max(4, blinkTotal / 3)
            blinkFramesLeft = blinkTotal
            lastBlinkEnvelopeFrames = blinkTotal
            lastBlinkFrame = frame
            blinkCount += 1
        }
        // v1 fallback: Willow's long-soft-blink quirk stretch applies only
        // when the profile carries no v2 blink grammar (which owns the
        // envelope shape at assetVersion 2).
        if profile.blink == nil, profile.traitVector.agreeableness > 0.8, blinkFramesLeft == blinkTotal - 1 {
            blinkTotal += 5
            blinkFramesLeft += 5
        }
        if blinkFramesLeft > 0 {
            blinkFramesLeft -= 1
            let elapsed = blinkTotal - blinkFramesLeft
            let openFrames = blinkTotal - blinkCloseFrames
            let close: Float
            if elapsed <= blinkCloseFrames {
                close = Float(elapsed) / Float(blinkCloseFrames)
            } else {
                close = 1.0 - Float(elapsed - blinkCloseFrames) / Float(openFrames)
            }
            let lid = 5.5 * close
            pose.offsetsY[bones.lidL] += lid
            pose.offsetsY[bones.lidR] += lid
            expressions[ExpressionChannel.rest.rawValue] = max(expressions[ExpressionChannel.rest.rawValue], close * 0.4)
        }
    }

    var isBlinking: Bool { blinkFramesLeft > 0 }
}
