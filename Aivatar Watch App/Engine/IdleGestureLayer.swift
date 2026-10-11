import Foundation

/// L2 — Idle gestures (§7).
///
/// Poisson scheduling: with `gestureRatePerMin = R`, the per-tick trigger
/// probability is `lambda * dt = R / 1800`, checked once per frame; multiple
/// simultaneous gestures are suppressed. Chosen clip comes from the profile's
/// `gesturePoolWeights`. Crossfading: the clip's contribution ramps 0 -> 1 ->
/// 0 with per-bone ease curves over the profile's transition duration
/// (0.3-0.7 s, tempo-scaled).
nonisolated final class IdleGestureLayer {
    private let profile: PersonalityProfile
    private var rng: SeededRandom
    private let gestureP: Float

    /// Pool of clips with nonzero weight, plus cumulative distribution.
    private let pool: [GestureClip]
    private let cumulative: [Float]

    /// Active gesture playback state.
    private var activeClip: GestureClip?
    private var startFrame = 0
    private var actionFrames = 0
    private var anticipationFrames = 0
    private var fadeFrames = 9
    private var gestureCount = 0

    init(profile: PersonalityProfile, seed: UInt64) {
        self.profile = profile
        rng = SeededRandom(seed ^ 0x1D_1E_0F_02)

        let p = profile.motionProfile.gestureRatePerMin / 1800.0
        gestureP = p

        var pool: [GestureClip] = []
        var cumulative: [Float] = []
        var acc: Float = 0
        for clip in GestureClip.allCases {
            let w = profile.gesturePoolWeights["\(clip)"] ?? 0
            if w > 0 {
                acc += w
                pool.append(clip)
                cumulative.append(acc)
            }
        }
        self.pool = pool
        self.cumulative = cumulative.map { $0 / max(acc, 0.0001) }

        // Crossfade ramp: profile transition duration, tempo-scaled,
        // clamped to the plan's 0.3-0.7 s window.
        let seconds = profile.motionProfile.transitionDurationRange.lowerBound / max(0.5, profile.motionProfile.tempoScale)
        fadeFrames = max(9, min(21, Int(seconds * 30)))
    }

    var currentClip: GestureClip? { activeClip }
    /// Big-clip progress 0...1 for the renderer's accent particles (A3).
    var bigClipPhase: Float {
        guard let clip = activeClip, clip.isBig, actionFrames > 0 else { return 0 }
        let elapsed = activeElapsed
        let u = Float(max(0, elapsed - anticipationFrames)) / Float(actionFrames)
        return min(max(u, 0), 1)
    }

    private var activeElapsed: Int = 0

    func step(
        into pose: inout AvatarPose,
        frame: Int,
        bones: BoneMap,
        expressions: inout [Float]
    ) {
        if let clip = activeClip {
            activeElapsed = frame - startFrame
            let total = anticipationFrames + actionFrames + fadeFrames
            let elapsed = activeElapsed

            // Crossfade weight: fade-in over fadeFrames, hold, fade-out.
            var w: Float = 1
            if elapsed < fadeFrames {
                w = GestureClipLibrary.easeInOut(Float(elapsed) / Float(fadeFrames))
            } else if !clip.endsWrapped, elapsed >= total - fadeFrames {
                // Wrapped clips (spin) hold weight 1 to the end: their 2*pi
                // end pose is the neutral pose, and fading it would unwind a
                // full turn backwards (§11 continuity).
                let tail = Float(elapsed - (total - fadeFrames)) / Float(fadeFrames)
                w = GestureClipLibrary.easeInOut(1 - min(tail, 1))
            }

            let aPhase = elapsed < anticipationFrames
                ? Float(elapsed) / Float(max(anticipationFrames, 1))
                : 1
            let u = min(max(Float(elapsed - anticipationFrames) / Float(max(actionFrames, 1)), 0), 1)

            GestureClipLibrary.apply(
                clip,
                u: u,
                anticipation: aPhase < 1 ? aPhase : 0,
                weight: w,
                profile: profile,
                bones: bones,
                pose: &pose,
                expressions: &expressions
            )

            if elapsed >= total {
                activeClip = nil
            }
            return
        }

        // Poisson idle scheduling: one Bernoulli check per tick; while a
        // gesture is active no new one is scheduled (suppression, §7).
        if rng.nextFloat() < gestureP, !pool.isEmpty {
            let roll = rng.nextFloat()
            var picked = pool[0]
            for (i, c) in cumulative.enumerated() where roll <= c {
                picked = pool[i]
                break
            }
            activeClip = picked
            startFrame = frame
            actionFrames = GestureClipLibrary.durationFrames(picked, profile: profile)
            anticipationFrames = GestureClipLibrary.anticipationFrames(picked, profile: profile)
            activeElapsed = 0
            gestureCount += 1
        }
    }

    /// Number of gestures triggered (CI budget/statistics assertion hook).
    var triggeredCount: Int { gestureCount }
}
