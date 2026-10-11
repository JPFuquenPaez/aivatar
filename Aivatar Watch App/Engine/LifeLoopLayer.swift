import Foundation

/// L1 — Life loops (§7).
///
/// Always-on in active mode: breathing (chest scale), micro-sway, heartbeat
/// shimmer, plus stochastic blinks and saccades from the gaze profile. All
/// stochastic triggers advance one per-frame Bernoulli draw each frame
/// (per-tick probability `lambda * dt`), so same seed -> same behavior.
nonisolated final class LifeLoopLayer {
    private let profile: PersonalityProfile
    private var rng: SeededRandom

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

    /// Named idle gaze targets from the profile (§5 gaze profile), resolved
    /// to pupil offsets in rig points: each archetype's saccades land on its
    /// own target set (Ember glances up, Nimbus darts down, ...).
    private let gazeTargets: [(x: Float, y: Float)]

    // Blink state.
    private var blinkFramesLeft = 0
    /// Total length of the current blink envelope (stretched by the Willow
    /// quirk); elapsed is derived from this, never hardcoded.
    private var blinkTotal = 10
    private var lastBlinkFrame = -1000
    /// Total blinks triggered (CI rate-budget assertions, §7/§11).
    private(set) var blinkCount = 0

    // Nimbus quirk: higher blink variance via a slow-modulated rate.
    private let blinkVariance: Float

    init(profile: PersonalityProfile, seed: UInt64) {
        self.profile = profile
        rng = SeededRandom(seed ^ 0x1_1F_E0_00)
        blinkP = profile.gazeProfile.blinkRatePerMin / 1800.0
        saccadeP = profile.gazeProfile.saccadeRatePerMin / 1800.0
        blinkVariance = profile.traitVector.neuroticism
        gazeTargets = Self.resolveTargets(profile.gazeProfile.idleGazeTargets)
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
        // half-cycle — a visible drift, still under 0.03 rad/frame.
        pose.rotations[bones.hips] += sin(t * 0.55) * 0.035 * profile.motionProfile.amplitudeScale
        pose.offsetsY[bones.hips] += sin(t * 1.1) * 1.6

        // --- Heartbeat shimmer: 60 bpm pulse on the head (~0.6-unit bob).
        let beat = t * Float.pi * 2.0 * 1.0
        let pulse = pow(max(0, sin(beat)), 12)
        pose.offsetsY[bones.head] -= pulse * 0.6

        // --- Saccades: retarget gaze stochastically among the profile's idle
        //     gaze targets; head follows with probability `headPropensity`
        //     (head movement propensity model).
        if rng.nextFloat() < saccadeP {
            let pick = min(rng.nextFloat() * Float(gazeTargets.count), Float(gazeTargets.count - 1))
            let target = gazeTargets[Int(pick)]
            gazeTargetX = target.x + rng.nextSignedFloat() * 0.8
            gazeTargetY = target.y + rng.nextSignedFloat() * 0.5
            gazeSpeed = 0.2 + rng.nextFloat() * 0.35 * profile.motionProfile.tempoScale
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
        //     window (Nimbus "higher blink variance"). Blink is a ~330 ms
        //     close-open envelope (close over 5 frames, open over 5): quick
        //     enough to read as a blink, slow enough that lid travel stays
        //     inside the per-frame continuity budget (§11). Gaze-evoked
        //     blink cadence stays stochastic.
        let varianceMod = 1.0 + sin(t * 0.15) * 0.45 * blinkVariance
        let effectiveBlinkP = blinkP * varianceMod
        if blinkFramesLeft == 0 && rng.nextFloat() < effectiveBlinkP {
            blinkTotal = 10
            blinkFramesLeft = blinkTotal
            lastBlinkFrame = frame
            blinkCount += 1
        }
        // Long soft blinks (Willow quirk) stretch the envelope once at onset.
        if profile.traitVector.agreeableness > 0.8 && blinkFramesLeft == blinkTotal - 1 {
            blinkTotal += 5
            blinkFramesLeft += 5
        }
        if blinkFramesLeft > 0 {
            blinkFramesLeft -= 1
            let elapsed = blinkTotal - blinkFramesLeft
            let openFrames = blinkTotal - 5
            let close: Float
            if elapsed <= 5 {
                close = Float(elapsed) / 5.0
            } else {
                close = 1.0 - Float(elapsed - 5) / Float(openFrames)
            }
            let lid = 5.5 * close
            pose.offsetsY[bones.lidL] += lid
            pose.offsetsY[bones.lidR] += lid
            expressions[ExpressionChannel.rest.rawValue] = max(expressions[ExpressionChannel.rest.rawValue], close * 0.4)
        }
    }

    var isBlinking: Bool { blinkFramesLeft > 0 }
}
