import Foundation

/// Accessibility motion modes (§8). L1 disables idle gestures and squash &
/// stretch, keeps breathing + blinking; L2 is a static pose + gentle blink.
nonisolated enum MotionAccessibilityMode: Sendable, Equatable {
    case full
    case reduceMotionL1
    case reduceMotionL2
}

/// The avatar engine (§7): composes the layered procedural animation
/// (L0 posture, L1 life loops, L2 idle gestures; L3 reactions and L4 affect
/// are ports) into a pose value type. The engine is UI-framework-free and
/// deterministic: same seed + same frame -> same pose (CI golden frames).
///
/// Single-threaded by design (called from the main render loop); all buffers
/// are pre-allocated, the per-frame path allocates nothing.
nonisolated final class AvatarEngine {
    let skeleton: Skeleton
    let profile: PersonalityProfile
    let visualSet: ArchetypeVisualSet
    let bones: BoneMap
    private(set) var clock: AvatarClock

    // Layers.
    private let posture: PostureLayer
    private let life: LifeLoopLayer
    private let idle: IdleGestureLayer
    private let reactions: ReactionLayer

    // Integration ports.
    /// L4 (Phase C): blended affect over the archetype baseline.
    private var affectInput: (any AffectInput)?
    private var affectEMA: AffectState?
    private let affectEMAAlpha: Float = 0.3
    /// L3 (Phase B): queued interaction events, drained into the reaction
    /// layer on the next step.
    private var pendingEvents: [AvatarEvent] = []
    /// Telemetry (§3 ports).
    private(set) var telemetry: any TelemetrySink

    // Accessibility (§8).
    var accessibilityMode: MotionAccessibilityMode = .full

    // Rest / wake state.
    private(set) var resting = false
    /// 0 -> 1 wake transition progress (<= 600 ms = 18 frames, §8).
    private(set) var wakeBlend: Float = 1
    /// Frames since the last wrist raise; drives the post-wake greeting.
    private var framesSinceWake = 0
    private var restPoseBuffer: AvatarPose
    private var blendScratch: AvatarPose

    // Per-frame state.
    private var pose: AvatarPose
    private var expressions: [Float]
    private(set) var world: [Transform2D]

    // Follow-through springs on appendage chains (12 principles, §7).
    private var antennaAngle: Float = 0
    private var antennaVelocity: Float = 0
    private var tailAngle: Float = 0
    private var tailVelocity: Float = 0

    init(skeleton: Skeleton, profile: PersonalityProfile, seed: UInt64, telemetry: (any TelemetrySink)? = nil) {
        self.skeleton = skeleton
        self.profile = profile
        visualSet = ArchetypeVisualSet(profile: profile)
        bones = BoneMap(skeleton: skeleton)
        clock = AvatarClock(seed: seed)
        posture = PostureLayer(profile: profile)
        life = LifeLoopLayer(profile: profile, seed: seed)
        idle = IdleGestureLayer(profile: profile, seed: seed)
        reactions = ReactionLayer(profile: profile, seed: seed)
        self.telemetry = telemetry ?? NullTelemetrySink()

        pose = AvatarPose(boneCount: skeleton.boneCount)
        expressions = [Float](repeating: 0, count: ExpressionChannel.count)
        world = [Transform2D](repeating: .identity, count: skeleton.boneCount)
        restPoseBuffer = AvatarPose(boneCount: skeleton.boneCount)
        blendScratch = AvatarPose(boneCount: skeleton.boneCount)
        buildRestPose(into: &restPoseBuffer)
    }

    // MARK: - Public update

    /// Advances to `target` frame index, stepping through every intermediate
    /// frame so stochastic schedules stay statistically correct.
    func update(toFrame target: Int) {
        while clock.advance(to: target) {
            step()
        }
    }

    /// Wall-clock entry point for the renderer: maps elapsed time to a frame.
    func update(atElapsed seconds: TimeInterval) {
        update(toFrame: clock.frameIndex(at: seconds))
    }

    /// The live pose (engine-owned; read-only from the renderer).
    var currentPose: AvatarPose { pose }

    var currentWorld: [Transform2D] { world }

    /// Idle gesture telemetry (CI Poisson-budget assertions).
    var triggeredGestureCount: Int { idle.triggeredCount }
    /// Blink telemetry (CI rate-budget assertions).
    var blinkCountForTesting: Int { life.blinkCount }
    /// Reaction telemetry (Phase B tests).
    var reactionCountForTesting: Int { reactions.reactionCount }
    /// The clip the active reaction is playing (tap pool picks; Phase B).
    var currentReactionClip: GestureClip? { reactions.currentClip }

    var activeGestureClip: GestureClip? { idle.currentClip }
    /// Accent-particle phase (§8): fires for big idle gestures AND big
    /// reactions — Ember's long-press spark-trail quirk is a reaction clip.
    /// max() keeps event-free runs identical to the idle-only value, so CI
    /// golden frames are unaffected.
    var activeGesturePhase: Float {
        max(idle.bigClipPhase, reactions.bigClipPhase)
    }

    // MARK: - Rest / wake (§6 rest pose, §8 wake transition)

    /// Static per-archetype sleep pose: eyes closed, slumped, rest channel 1.
    var restPose: AvatarPose { restPoseBuffer }

    func setResting(_ value: Bool) {
        resting = value
        if value {
            wakeBlend = 0
        } else {
            wakeBlend = 0 // wake-up crossfade starts from the rest pose
            framesSinceWake = 0
        }
    }

    private func buildRestPose(into rest: inout AvatarPose) {
        rest.resetToNeutral()
        // Slumped posture, head slightly tilted, eyes closed.
        rest.rotations[bones.spineLower] = 0.06
        rest.rotations[bones.spineUpper] = 0.09
        rest.rotations[bones.neck] = -0.03
        rest.rotations[bones.head] = -0.05
        rest.offsetsY[bones.head] += 2
        rest.offsetsY[bones.lidL] = 5.8
        rest.offsetsY[bones.lidR] = 5.8
        rest.offsetsY[bones.browL] += 1
        rest.offsetsY[bones.browR] += 1
        rest.scalesX[bones.mouth] *= 0.8
        rest.rotations[bones.appendageA] = 0.18
        rest.rotations[bones.appendageB] = 0.3
        rest.rotations[bones.appendageB2] = 0.25
        rest.expressionWeights[ExpressionChannel.rest.rawValue] = 1
    }

    // MARK: - Ports (§13)

    /// Phase C: attach an affect source. The engine blends it (EMA, alpha 0.3)
    /// over the archetype baseline; low confidence holds neutral.
    func setAffectInput(_ input: (any AffectInput)?) {
        affectInput = input
    }

    /// Phase B: the interaction bus delivers avatar events here; the
    /// reaction layer answers taps with a weighted pick from the profile's
    /// gesture pool (per-archetype reaction variety, §5/§7).
    func handleEvent(_ event: AvatarEvent) {
        pendingEvents.append(event)
        telemetry.record(counter: "avatar.event.\(event)", value: 1)
    }

    // MARK: - Per-frame step

    private func step() {
        let frame = clock.frame
        framesSinceWake += 1
        pose.resetToNeutral()
        for i in 0..<expressions.count { expressions[i] = 0 }

        posture.apply(to: &pose, bones: bones)

        switch accessibilityMode {
        case .full:
            life.step(into: &pose, frame: frame, bones: bones, expressions: &expressions)
            idle.step(into: &pose, frame: frame, bones: bones, expressions: &expressions)
        case .reduceMotionL1:
            // Breathing + blinking only. Idle gestures are disabled, so no
            // gesture squash & stretch exists; the life loops' breathing
            // chest scale is explicitly kept (§8).
            life.step(into: &pose, frame: frame, bones: bones, expressions: &expressions)
        case .reduceMotionL2:
            // Static pose + gentle blink only: the life loops run for the
            // blink; all non-lid motion is flattened at the end of the step
            // (after the mixer and follow-through springs write).
            life.step(into: &pose, frame: frame, bones: bones, expressions: &expressions)
        }

        // L3 (Phase B): queued events become reactions, then the reaction
        // layer applies. Reactions are user-initiated, so they stay on in
        // L1; in L2 the flatten below keeps the body static and the
        // reaction reads on the face only (expression channels + lids).
        drainReactionEvents()
        reactions.step(into: &pose, frame: frame, bones: bones, expressions: &expressions)

        blendAffect(into: &expressions)
        addWakeGreeting(into: &expressions)
        ExpressionMixer.apply(expressions: expressions, bones: bones, pose: &pose)
        followThrough(into: &pose)

        if accessibilityMode == .reduceMotionL2 {
            flattenForL2()
        }

        // Publish blended channel weights on the pose (renderer + Phase B/C).
        for i in 0..<pose.expressionWeights.count {
            pose.expressionWeights[i] = min(max(expressions[i], 0), 1)
        }

        if wakeBlend < 1 {
            // Wake-up crossfade (<= 600 ms): rest pose -> live pose. Blends
            // into a scratch buffer, then swaps (no per-frame allocation).
            blendPose(a: restPoseBuffer, b: pose, t: wakeBlend, out: &blendScratch)
            // Eyes lead the wake (staging, §4 appeal): the lids and the rest
            // channel open ahead of the body so the avatar "looks at you"
            // while it is still rising.
            let lead = GestureClipLibrary.easeInOut(min(1, wakeBlend * 1.6))
            for bone in [bones.lidL, bones.lidR] {
                let a = restPoseBuffer.offsetsY[bone]
                let b = pose.offsetsY[bone]
                blendScratch.offsetsY[bone] = a + (b - a) * lead
            }
            let restChannel = ExpressionChannel.rest.rawValue
            let restA = restPoseBuffer.expressionWeights[restChannel]
            let restB = pose.expressionWeights[restChannel]
            blendScratch.expressionWeights[restChannel] = restA + (restB - restA) * lead
            swap(&pose, &blendScratch)
            wakeBlend = min(1, wakeBlend + 1.0 / 18.0)
        }

        skeleton.solve(pose: pose, into: &world)
    }

    /// Post-wake greeting (§8: the wake-up transition is the avatar's key
    /// delight moment): a soft warm smile blooms as the wake crossfade
    /// completes, then fades over ~1 s. Deterministic (no randomness).
    private func addWakeGreeting(into expressions: inout [Float]) {
        if framesSinceWake >= 16, framesSinceWake <= 46 {
            let p = Float(framesSinceWake - 16) / 30
            expressions[ExpressionChannel.warm.rawValue] += sin(p * .pi) * 0.6
        }
    }

    private func drainReactionEvents() {
        // L3 (Phase B): each queued event is offered to the reaction layer.
        // Reactions are suppressed while an idle gesture is active (§7). In
        // Reduce Motion L2 the tap pool is filtered to face-readable clips.
        guard !pendingEvents.isEmpty else { return }
        let frame = clock.frame
        let idleActive = idle.currentClip != nil
        let faceOnly = accessibilityMode == .reduceMotionL2
        for event in pendingEvents {
            reactions.offer(event, frame: frame, idleActive: idleActive, faceOnly: faceOnly)
        }
        pendingEvents.removeAll()
    }

    /// L4 mechanics (§13 design rules): affect is always blended, never
    /// hard-switched (EMA, alpha 0.3); low confidence holds neutral.
    private func blendAffect(into expressions: inout [Float]) {
        guard let input = affectInput, let fresh = input.affect else { return }
        if let current = affectEMA {
            affectEMA = AffectState(
                valence: current.valence + affectEMAAlpha * (fresh.valence - current.valence),
                arousal: current.arousal + affectEMAAlpha * (fresh.arousal - current.arousal),
                confidence: fresh.confidence,
                timestamp: fresh.timestamp
            )
        } else {
            affectEMA = fresh
        }
        guard let blended = affectEMA, blended.confidence > 0.5 else { return }

        // Valence/arousal -> expression channel weights over the baseline.
        let positive = max(0, blended.valence)
        let negative = max(0, -blended.valence)
        expressions[ExpressionChannel.joy.rawValue] += positive * blended.arousal * 0.8
        expressions[ExpressionChannel.warm.rawValue] += positive * (1 - blended.arousal) * 0.7
        expressions[ExpressionChannel.sad.rawValue] += negative * (1 - blended.arousal) * 0.7
        expressions[ExpressionChannel.alert.rawValue] += blended.arousal * 0.5
        expressions[ExpressionChannel.sleepy.rawValue] += (1 - blended.arousal) * 0.4 * negative
    }

    /// Reduces an angle to [-pi, pi] so the follow-through springs track the
    /// shortest rotation. Without this, a full-body spin clip would wind the
    /// springs through +/-2*pi and snap them back on return (§11 continuity).
    private func wrapPi(_ x: Float) -> Float {
        var v = x
        while v > .pi { v -= 2 * .pi }
        while v < -.pi { v += 2 * .pi }
        return v
    }

    private func followThrough(into pose: inout AvatarPose) {
        // Lagged springs on appendage chains (§7 follow-through & overlap).
        // Angle errors are wrapped and velocity clamped so appendages stay
        // expressive but never snap (§11 no-pose-snapping budget): the clamp
        // bounds the amplified outputs too (A2 1.5x, B2 1.4x -> ~0.27 rad/f).
        let antennaTarget = wrapPi(-pose.rotations[bones.head] * 1.6 - antennaAngle)
        antennaVelocity = min(max(antennaVelocity + antennaTarget * 0.14 - antennaVelocity * 0.3, -0.18), 0.18)
        antennaAngle += antennaVelocity
        pose.rotations[bones.appendageA] += antennaAngle
        pose.rotations[bones.appendageA2] += antennaAngle * 1.5

        let tailTarget = wrapPi(-pose.rotations[bones.hips] * 2.2 - pose.offsetsX[bones.hips] * 0.02 - tailAngle)
        tailVelocity = min(max(tailVelocity + tailTarget * 0.12 - tailVelocity * 0.26, -0.18), 0.18)
        tailAngle += tailVelocity
        pose.rotations[bones.appendageB] += tailAngle
        pose.rotations[bones.appendageB2] += tailAngle * 1.4
    }

    /// L2 static mode: keep only the gentle blink (lid offsets).
    private func flattenForL2() {
        for i in 0..<pose.rotations.count where i != bones.lidL && i != bones.lidR {
            pose.rotations[i] = 0
            pose.offsetsX[i] = 0
            pose.offsetsY[i] = 0
            pose.scalesX[i] = 1
            pose.scalesY[i] = 1
        }
        pose.scalesX[bones.chest] = 1
        pose.scalesY[bones.chest] = 1
    }

    private func blendPose(a: AvatarPose, b: AvatarPose, t: Float, out: inout AvatarPose) {
        let e = GestureClipLibrary.easeInOut(t)
        for i in 0..<out.rotations.count {
            out.rotations[i] = a.rotations[i] + (b.rotations[i] - a.rotations[i]) * e
            out.offsetsX[i] = a.offsetsX[i] + (b.offsetsX[i] - a.offsetsX[i]) * e
            out.offsetsY[i] = a.offsetsY[i] + (b.offsetsY[i] - a.offsetsY[i]) * e
            out.scalesX[i] = a.scalesX[i] + (b.scalesX[i] - a.scalesX[i]) * e
            out.scalesY[i] = a.scalesY[i] + (b.scalesY[i] - a.scalesY[i]) * e
        }
        for i in 0..<out.expressionWeights.count {
            out.expressionWeights[i] = a.expressionWeights[i] + (b.expressionWeights[i] - a.expressionWeights[i]) * e
        }
    }
}
