import Foundation

/// L3 — Reactions (Phase B, §7).
///
/// Maps avatar events to short reaction clips: tap → sparkle (joy pulse),
/// named gestures → that clip, crown ticks → a decaying gaze dart (pupils
/// only). Reactions are user-initiated, so they stay on in Reduce Motion L1
/// (which disables *idle* motion); in L2 the body stays static and reactions
/// read on the face only (expression channels + lid openness).
///
/// Deterministic: no randomness — a reaction is a pure function of the
/// event and frame. Cooldown (>= 0.5 s) between reactions; reactions are
/// suppressed while an idle gesture is active (§7 gesture suppression).
nonisolated final class ReactionLayer {
    private let profile: PersonalityProfile

    // Active reaction playback state.
    private var activeClip: GestureClip?
    private var startFrame = 0
    private var actionFrames = 0
    private var fadeFrames = 9
    private var activeElapsed = 0

    /// Frames of silence required between reactions (15 = 0.5 s).
    private let cooldownFrames = 15
    private var lastReactionEndFrame = -1000

    /// Crown-driven gaze dart: an impulse that decays. Pupil offset only —
    /// the digital crown drives page navigation on watchOS, so a crown
    /// reaction must never move bones.
    private var crownGazeX: Float = 0

    private(set) var reactionCount = 0

    var currentClip: GestureClip? { activeClip }

    init(profile: PersonalityProfile) {
        self.profile = profile
        let seconds = profile.motionProfile.transitionDurationRange.lowerBound
        fadeFrames = max(9, min(21, Int(seconds * 30)))
    }

    /// Offers an event; returns true if a reaction clip started. Crown
    /// ticks never start a clip (they drive the gaze dart). `idleActive`
    /// suppresses reactions while an L2 idle gesture is playing (§7).
    @discardableResult
    func offer(_ event: AvatarEvent, frame: Int, idleActive: Bool) -> Bool {
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
            return false
        }
        let clip: GestureClip?
        switch event {
        case .tap:
            clip = .sparkle
        case .gesture(let name):
            clip = GestureClip(rawValue: name)
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

    /// Applies the active reaction (additive) and advances the gaze dart.
    /// Runs above L2 (idle gestures) in the layer stack (§7).
    func step(into pose: inout AvatarPose, frame: Int, bones: BoneMap, expressions: inout [Float]) {
        if abs(crownGazeX) > 0.01 {
            pose.offsetsX[bones.pupilL] += crownGazeX
            pose.offsetsX[bones.pupilR] += crownGazeX
            crownGazeX *= 0.82
        }

        guard let clip = activeClip else { return }
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
}
