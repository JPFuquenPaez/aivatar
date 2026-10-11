import Foundation

/// L3 — Reactions (Phase B, §7).
///
/// Maps avatar events to short reaction clips: tap → a weighted pick from
/// the profile's `gesturePoolWeights` (each archetype reacts in character),
/// named gestures → that clip, crown ticks → a decaying gaze dart (pupils
/// only). Reactions are user-initiated, so they stay on in Reduce Motion L1
/// (which disables *idle* motion); in L2 the body stays static and the tap
/// pool is filtered to clips that write an expression channel, so every
/// reaction still reads on the face.
///
/// Deterministic: the tap pick draws from a private seeded RNG stream that
/// is consumed only when a reaction actually starts — the engine's other
/// layers never see it, so an engine that reacted still re-converges with
/// an event-free reference (same seed, same frame -> same pose). Cooldown
/// (>= 0.3 s) between reactions; reactions are suppressed while an idle
/// gesture is active (§7 gesture suppression). A tap that cannot start a
/// clip (cooldown, active clip, idle suppression) is never silent: the
/// avatar acknowledges it with a brief eye-contact + focus pulse that
/// interrupts nothing — every touch gets an immediate, visible answer.
nonisolated final class ReactionLayer {
    private let profile: PersonalityProfile
    private var pickRNG: SeededRandom

    // Active reaction playback state.
    private var activeClip: GestureClip?
    private var startFrame = 0
    private var actionFrames = 0
    private var fadeFrames = 9
    private var activeElapsed = 0

    /// Frames of silence required between reactions (9 = 0.3 s — long
    /// enough that two clips never overlap, short enough that the avatar
    /// never feels dead to a second tap).
    private let cooldownFrames = 9
    private var lastReactionEndFrame = -1000

    /// Dropped-tap acknowledgment (§9 responsiveness): frames left in the
    /// eye-contact + focus pulse; 12 frames = 0.4 s, sine in-out envelope.
    private var ackFramesLeft = 0
    private let ackTotal = 12

    /// Crown-driven gaze dart: an impulse that decays. Pupil offset only —
    /// the digital crown drives page navigation on watchOS, so a crown
    /// reaction must never move bones.
    private var crownGazeX: Float = 0

    private(set) var reactionCount = 0

    var currentClip: GestureClip? { activeClip }

    /// Big-clip progress 0...1 for the renderer's accent particles (§8):
    /// mirrors IdleGestureLayer.bigClipPhase so a big *reaction* also emits
    /// (Ember's long-press spark-trail quirk, §5). Reactions play without
    /// anticipation, so the phase is the raw action progress.
    var bigClipPhase: Float {
        guard let clip = activeClip, clip.isBig, actionFrames > 0 else { return 0 }
        return min(max(Float(activeElapsed) / Float(actionFrames), 0), 1)
    }

    init(profile: PersonalityProfile, seed: UInt64) {
        self.profile = profile
        // Separate stream (offset from the engine seed) so reaction picks
        // never disturb the deterministic clock/idle schedules.
        pickRNG = SeededRandom(seed &+ 0x5EAC_7100_0000_0001)
        let seconds = profile.motionProfile.transitionDurationRange.lowerBound
        fadeFrames = max(9, min(21, Int(seconds * 30)))
    }

    /// Offers an event; returns true if a reaction clip started. Crown
    /// ticks never start a clip (they drive the gaze dart). `idleActive`
    /// suppresses reactions while an L2 idle gesture is playing (§7).
    /// `faceOnly` (Reduce Motion L2) restricts the tap pool to clips that
    /// write an expression channel so the reaction reads on the face.
    @discardableResult
    func offer(_ event: AvatarEvent, frame: Int, idleActive: Bool, faceOnly: Bool = false) -> Bool {
        switch event {
        case .crownTick(let delta):
            crownGazeX = min(max(crownGazeX + delta * 0.35, -3), 3)
            return false
        case .wake, .sleep:
            return false // handled by setResting / the wake crossfade
        case .tap, .gesture:
            break
        }

        guard activeClip == nil, frame - lastReactionEndFrame >= cooldownFrames, !idleActive else {
            // The tap cannot start a clip, but it is never dropped
            // silently: acknowledge with eye contact (§9 responsiveness).
            ackFramesLeft = ackTotal
            return false
        }
        var clip: GestureClip?
        switch event {
        case .tap:
            clip = pickFromPool(faceOnly: faceOnly)
        case .gesture(let name):
            // Phase B reaction scripting: explicit clips are honored as-is —
            // except in L2, where the body is flattened and a body-only clip
            // would react invisibly; §8 accessibility trumps scripting, so it
            // degrades to a face-readable in-character pool pick.
            clip = GestureClip(rawValue: name)
            if faceOnly, let explicit = clip, !explicit.writesExpression {
                clip = pickFromPool(faceOnly: true)
            }
        default:
            clip = nil
        }
        guard let clip else { return false }

        activeClip = clip
        startFrame = frame
        actionFrames = GestureClipLibrary.durationFrames(clip, profile: profile)
        activeElapsed = 0
        reactionCount += 1
        return true
    }

    /// Weighted pick from the profile's gesture pool (§5 `gesturePoolWeights`,
    /// weights sum to 1 — validated at build time). Clips with weight 0 are
    /// never drawn; in L2 only clips with a facial channel remain eligible.
    /// Event-time only (not per frame); allocates nothing.
    private func pickFromPool(faceOnly: Bool) -> GestureClip? {
        var total: Float = 0
        for clip in GestureClip.allCases {
            let w = profile.gesturePoolWeights[clip.rawValue] ?? 0
            if w > 0, !(faceOnly && !clip.writesExpression) {
                total += w
            }
        }
        guard total > 0 else { return nil }
        var draw = pickRNG.nextFloat() * total
        for clip in GestureClip.allCases {
            var w = profile.gesturePoolWeights[clip.rawValue] ?? 0
            if w > 0, faceOnly && !clip.writesExpression {
                w = 0
            }
            if w > 0 {
                if draw < w { return clip }
                draw -= w
            }
        }
        // Float rounding can leave draw == total; fall back to the last
        // eligible clip rather than dropping the reaction.
        var last: GestureClip?
        for clip in GestureClip.allCases {
            let w = profile.gesturePoolWeights[clip.rawValue] ?? 0
            if w > 0, !(faceOnly && !clip.writesExpression) { last = clip }
        }
        return last
    }

    /// Applies the active reaction (additive) and advances the gaze dart.
    /// Runs above L2 (idle gestures) in the layer stack (§7).
    func step(into pose: inout AvatarPose, frame: Int, bones: BoneMap, expressions: inout [Float]) {
        if abs(crownGazeX) > 0.01 {
            pose.offsetsX[bones.pupilL] += crownGazeX
            pose.offsetsX[bones.pupilR] += crownGazeX
            crownGazeX *= 0.82
        }

        if let clip = activeClip {
            activeElapsed = frame - startFrame
            let total = actionFrames + fadeFrames
            var w: Float = 1
            if activeElapsed < fadeFrames {
                w = GestureClipLibrary.easeInOut(Float(activeElapsed) / Float(fadeFrames))
            } else if !clip.endsWrapped, activeElapsed >= total - fadeFrames {
                // Wrapped clips (spin) hold weight 1 to the end; their 2*pi end
                // pose is the neutral pose (§11 continuity).
                let tail = Float(activeElapsed - (total - fadeFrames)) / Float(fadeFrames)
                w = GestureClipLibrary.easeInOut(1 - min(tail, 1))
            }
            let u = min(max(Float(activeElapsed) / Float(max(actionFrames, 1)), 0), 1)
            GestureClipLibrary.apply(
                clip,
                u: u,
                anticipation: 0,
                weight: w,
                profile: profile,
                bones: bones,
                pose: &pose,
                expressions: &expressions
            )
            if activeElapsed >= total {
                activeClip = nil
                lastReactionEndFrame = frame
            }
        }

        // Dropped-tap acknowledgment: the eyes answer — lids lift (an
        // "I see you" widening that reads even when the gaze is centered),
        // accumulated pupil deltas (L1 gaze, clip offsets) pull toward the
        // rest direction, and the focus channel pulses. Additive and
        // interrupting nothing; survives L2 (expressions/lids are kept).
        if ackFramesLeft > 0 {
            ackFramesLeft -= 1
            let p = 1 - Float(ackFramesLeft) / Float(ackTotal)
            let envelope = sin(p * .pi)
            let lift = envelope * 1.2
            pose.offsetsY[bones.lidL] -= lift
            pose.offsetsY[bones.lidR] -= lift
            let pull = envelope * 0.4
            for pupil in [bones.pupilL, bones.pupilR] {
                pose.offsetsX[pupil] -= pose.offsetsX[pupil] * pull
                pose.offsetsY[pupil] -= pose.offsetsY[pupil] * pull
            }
            let focus = ExpressionChannel.focus.rawValue
            expressions[focus] = max(expressions[focus], envelope * 0.7)
        }
    }
}
