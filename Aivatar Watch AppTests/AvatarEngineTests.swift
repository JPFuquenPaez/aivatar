import XCTest
@testable import Aivatar_Watch_App

/// A2 engine tests: determinism, Poisson scheduling budgets, crossfade
/// continuity, rest/wake, accessibility modes, and the §13 ports.
final class AvatarEngineTests: XCTestCase {
    private func makeEngine(_ archetype: Archetype = .ember, seed: UInt64 = 42) throws -> AvatarEngine {
        AvatarEngine(
            skeleton: try Skeleton(document: try RigDocument.load(bundle: .main)),
            profile: try PersonalityProfile.load(archetype, bundle: .main),
            seed: seed
        )
    }

    // MARK: Determinism (§7 hard requirement)

    func testSameSeedSamePoseSequence() throws {
        let a = try makeEngine(.prism, seed: 987)
        let b = try makeEngine(.prism, seed: 987)

        for frame in 1...900 {
            a.update(toFrame: frame)
            b.update(toFrame: frame)
            XCTAssertEqual(a.currentPose, b.currentPose, "pose diverged at frame \(frame)")
            XCTAssertEqual(a.currentWorld, b.currentWorld)
        }
    }

    func testDifferentSeedsDiverge() throws {
        let a = try makeEngine(.ember, seed: 1)
        let b = try makeEngine(.ember, seed: 2)
        a.update(toFrame: 300)
        b.update(toFrame: 300)
        XCTAssertNotEqual(a.currentPose, b.currentPose)
    }

    /// v4 "alive" pass: the posture wander must keep every archetype
    /// visibly, randomly moving between idle gestures — the hips lean
    /// wanders across a measurable range and the posture at distant
    /// windows is never a repeating loop. Determinism is covered by
    /// testSameSeedSamePoseSequence (the wander rides a seeded stream).
    func testPostureWanderKeepsBodyAlive() throws {
        for archetype in Archetype.allCases {
            let engine = try makeEngine(archetype, seed: 4242)

            var leanMin: Float = 0
            var leanMax: Float = 0
            var leanAt600: Float = 0
            var leanAt900: Float = 0
            for frame in 1...900 {
                engine.update(toFrame: frame)
                let lean = engine.currentPose.rotations[engine.bones.hips]

                leanMin = min(leanMin, lean)
                leanMax = max(leanMax, lean)
                if frame == 600 { leanAt600 = lean }
                if frame == 900 { leanAt900 = lean }
            }
            XCTAssertGreaterThan(
                leanMax - leanMin, 0.02,
                "\(archetype.rawValue): hips lean must wander visibly (range \(leanMax - leanMin))"
            )
            // Not a loop: the posture 10 s apart differs (wander targets
            // are redrawn every few seconds).
            XCTAssertNotEqual(
                leanAt600, leanAt900, "\(archetype.rawValue): posture must not repeat between windows"
            )
        }
    }

    func testSteppingThroughFramesEqualsJumping() throws {
        // update(toFrame:) steps through every frame so stochastic state stays
        // identical to a ticked run.
        let ticked = try makeEngine(.nimbus, seed: 7)
        for frame in 1...600 { ticked.update(toFrame: frame) }

        let jumped = try makeEngine(.nimbus, seed: 7)
        jumped.update(toFrame: 300)
        jumped.update(toFrame: 600)

        XCTAssertEqual(ticked.currentPose, jumped.currentPose)
        XCTAssertEqual(ticked.triggeredGestureCount, jumped.triggeredGestureCount)
    }

    // MARK: Poisson idle scheduling (§7)

    func testGestureRateMatchesProfileBudget() throws {
        // Ember: 6 gestures/min -> 10 min (18000 frames) should trigger ~60.
        let engine = try makeEngine(.ember, seed: 20261010)
        engine.update(toFrame: 18_000)
        let count = engine.triggeredGestureCount
        XCTAssertEqual(Double(count), 60.0, accuracy: 25.0, "ember gesture rate off: \(count) in 10 min")
    }

    func testBlinkRateMatchesProfileBudget() throws {
        // Ember: 22 blinks/min -> ~220 in 10 min (blink variance is 0 for
        // ember's low neuroticism).
        let engine = try makeEngine(.ember, seed: 20261010)
        engine.update(toFrame: 18_000)
        XCTAssertEqual(Double(engine.blinkCountForTesting), 220.0, accuracy: 60.0)
    }

    func testSlowerArchetypeGesturesLess() throws {
        let ember = try makeEngine(.ember, seed: 5)
        let compass = try makeEngine(.compass, seed: 5)
        ember.update(toFrame: 9_000)
        compass.update(toFrame: 9_000)
        XCTAssertGreaterThan(ember.triggeredGestureCount, compass.triggeredGestureCount,
                            "ember (6/min) must gesture more than compass (1.5/min)")
    }

    // MARK: Crossfade continuity (§11 "no pose snapping")

    func testNoPoseSnappingAcrossGestures() throws {
        let engine = try makeEngine(.ember, seed: 20261010)
        let pupils = Set([engine.bones.pupilL, engine.bones.pupilR])
        var previous = engine.currentPose
        var snaps: [String] = []
        var maxRotationDelta: Float = 0
        var maxOffsetDelta: Float = 0
        for frame in 1...1_800 { // 1 min of frames, including several gestures
            engine.update(toFrame: frame)
            let current = engine.currentPose
            for i in 0..<current.rotations.count {
                // Rotation continuity is angular: a 2*pi wrap (the spin clip
                // ends its action on a full turn) is visually seamless, so
                // deltas are compared on the circle, not linearly.
                var rd = abs(current.rotations[i] - previous.rotations[i])
                rd = rd.truncatingRemainder(dividingBy: 2 * .pi)
                if rd > .pi { rd = 2 * .pi - rd }
                let ox = abs(current.offsetsX[i] - previous.offsetsX[i])
                let oy = abs(current.offsetsY[i] - previous.offsetsY[i])
                if rd > maxRotationDelta || (!pupils.contains(i) && max(ox, oy) > maxOffsetDelta) {
                    if rd > 0.3 || (!pupils.contains(i) && max(ox, oy) > 2.5) {
                        let name = engine.skeleton.bones[i].name
                        snaps.append("f\(frame)/\(name)/rot\(String(format: "%.2f", rd))/ox\(String(format: "%.2f", ox))/oy\(String(format: "%.2f", oy))/clip=\(String(describing: engine.activeGestureClip))")
                    }
                }
                maxRotationDelta = max(maxRotationDelta, rd)
                if !pupils.contains(i) {
                    maxOffsetDelta = max(maxOffsetDelta, max(ox, oy))
                }
            }
            previous = current
        }
        // 0.3 rad/frame = 9 rad/s. The fastest designed motion is the spin
        // clip's full turn (peak ~0.24 rad/frame at ember tempo); hard snaps
        // (e.g. an unwrapped spring at ~3.5 rad/frame) fail this.
        XCTAssertLessThan(maxRotationDelta, 0.3, "snaps: \(snaps.prefix(12).joined(separator: ", "))")
        XCTAssertLessThan(maxOffsetDelta, 2.5, "a bone teleported between frames; snaps: \(snaps.prefix(12).joined(separator: ", "))")
        XCTAssertGreaterThan(engine.triggeredGestureCount, 0, "no gestures ran; continuity check was vacuous")
    }

    // MARK: Rest pose / wake (§6, §8)

    func testRestPoseIsAsleep() throws {
        let engine = try makeEngine(.willow, seed: 1)
        let rest = engine.restPose
        XCTAssertEqual(rest.expressionWeights[ExpressionChannel.rest.rawValue], 1)
        XCTAssertGreaterThan(rest.offsetsY[engine.bones.lidL], 4, "lids must be closed in rest pose")
        XCTAssertGreaterThan(rest.offsetsY[engine.bones.lidR], 4)
    }

    func testWakeCrossfadeCompletesWithinBudget() throws {
        let engine = try makeEngine(.ember, seed: 3)
        engine.setResting(true)
        engine.setResting(false) // wrist raise
        XCTAssertEqual(engine.wakeBlend, 0)
        var frames = 0
        repeat {
            engine.update(toFrame: engine.clock.frame + 1)
            frames += 1
        } while engine.wakeBlend < 1 && frames < 30
        XCTAssertLessThanOrEqual(frames, 18, "wake must complete within 600 ms (18 frames)")
        XCTAssertEqual(engine.wakeBlend, 1)
    }

    // MARK: Accessibility modes (§8)

    func testReduceMotionL1DisablesGesturesKeepsBreathing() throws {
        let engine = try makeEngine(.ember, seed: 20261010)
        engine.accessibilityMode = .reduceMotionL1
        engine.update(toFrame: 9_000)
        XCTAssertEqual(engine.triggeredGestureCount, 0, "L1 must disable idle gestures")

        // Breathing continues: chest scale oscillates.
        var minScale: Float = 2
        var maxScale: Float = 0
        for frame in 9_001...9_120 {
            engine.update(toFrame: frame)
            let s = engine.currentPose.scalesX[engine.bones.chest]
            minScale = min(minScale, s)
            maxScale = max(maxScale, s)
        }
        XCTAssertGreaterThan(maxScale - minScale, 0.01, "breathing must continue in L1")
    }

    func testReduceMotionL2IsStaticWithBlink() throws {
        let engine = try makeEngine(.ember, seed: 20261010)
        engine.accessibilityMode = .reduceMotionL2
        engine.update(toFrame: 100)
        let baseline = engine.currentPose
        engine.update(toFrame: 160)
        let after = engine.currentPose
        for i in 0..<baseline.rotations.count where i != engine.bones.lidL && i != engine.bones.lidR {
            XCTAssertEqual(after.rotations[i], baseline.rotations[i], "L2 must be static outside blinks")
            XCTAssertEqual(after.offsetsX[i], baseline.offsetsX[i])
            XCTAssertEqual(after.offsetsY[i], baseline.offsetsY[i])
        }
        XCTAssertGreaterThan(engine.blinkCountForTesting, 0, "gentle blinking stays on in L2")
    }

    // MARK: Ports (§13)

    func testNullAffectInputDoesNotDisturbEngine() throws {
        let plain = try makeEngine(.ember, seed: 11)
        let withNull = try makeEngine(.ember, seed: 11)
        withNull.setAffectInput(NullAffectInput())
        for frame in 1...600 {
            plain.update(toFrame: frame)
            withNull.update(toFrame: frame)
        }
        XCTAssertEqual(plain.currentPose, withNull.currentPose)
    }

    func testAffectBlendingIsGatedByConfidence() throws {
        struct HighConfidenceHappy: AffectInput {
            var affect: AffectState? {
                AffectState(valence: 1, arousal: 0.8, confidence: 1, timestamp: Date(timeIntervalSince1970: 0))
            }
        }
        struct LowConfidenceHappy: AffectInput {
            var affect: AffectState? {
                AffectState(valence: 1, arousal: 0.8, confidence: 0.2, timestamp: Date(timeIntervalSince1970: 0))
            }
        }

        let low = try makeEngine(.compass, seed: 2)
        low.setAffectInput(LowConfidenceHappy())
        low.update(toFrame: 120)
        XCTAssertEqual(low.currentPose.expressionWeights[ExpressionChannel.joy.rawValue], 0,
                       "low confidence must hold neutral")

        let high = try makeEngine(.compass, seed: 2)
        high.setAffectInput(HighConfidenceHappy())
        high.update(toFrame: 120)
        XCTAssertGreaterThan(high.currentPose.expressionWeights[ExpressionChannel.joy.rawValue], 0,
                             "positive valence + high arousal blends joy")
        // Blended, never hard-switched: baseline posture unchanged by affect.
        let reference = try makeEngine(.compass, seed: 2)
        reference.update(toFrame: 120)
        XCTAssertEqual(high.currentPose.rotations[high.bones.spineLower], reference.currentPose.rotations[reference.bones.spineLower])
    }

    // MARK: Phase B — L3 reactions

    func testTapTriggersPooledReactionAndFades() throws {
        let engine = try makeEngine(.ember, seed: 11)
        let reference = try makeEngine(.ember, seed: 11)
        engine.handleEvent(.tap)
        for frame in 1...20 { // mid-reaction (shortest ember clip: ~30 + fade)
            engine.update(toFrame: frame)
            reference.update(toFrame: frame)
        }
        XCTAssertEqual(engine.reactionCountForTesting, 1, "tap must trigger a reaction")
        XCTAssertNotNil(engine.currentReactionClip, "a pooled clip must be active mid-reaction")
        XCTAssertNotEqual(engine.currentPose, reference.currentPose, "the reaction must alter the pose")
        // Reactions are transient: the engine re-converges with a
        // reference that never saw the event (the pick RNG is a separate
        // stream and is never consumed by the pose path).
        for frame in 21...140 {
            engine.update(toFrame: frame)
            reference.update(toFrame: frame)
        }
        XCTAssertEqual(engine.currentPose, reference.currentPose, "the reaction must fully fade")
    }

    func testNamedGestureEventPlaysThatClip() throws {
        // Phase B reaction scripting: an explicit gesture event bypasses
        // the weighted pool and plays exactly the requested clip.
        let engine = try makeEngine(.willow, seed: 17)
        engine.update(toFrame: 50)
        engine.handleEvent(.gesture(name: "nod"))
        engine.update(toFrame: 51)
        XCTAssertEqual(engine.currentReactionClip, .nod, "named gesture events play the named clip")
    }

    func testReactionCooldown() throws {
        let engine = try makeEngine(.ember, seed: 5)
        engine.handleEvent(.tap)
        engine.update(toFrame: 5)
        engine.handleEvent(.tap) // inside the active reaction + cooldown
        engine.update(toFrame: 10)
        XCTAssertEqual(engine.reactionCountForTesting, 1, "reactions inside the cooldown are dropped")
        // Decouple from the schedules (v5b quirk clips shifted them): the
        // first tap may now pick a longer clip (preen), so advance until
        // neither a reaction nor an idle gesture is active — plus the
        // 9-frame post-reaction cooldown — then the assertion measures
        // cooldown behavior, not timing luck.
        var frame = 60
        while frame < 600 && (engine.currentReactionClip != nil || engine.activeGestureClip != nil) {
            frame += 3
            engine.update(toFrame: frame)
        }
        frame += 15
        engine.update(toFrame: frame)
        engine.handleEvent(.tap)
        engine.update(toFrame: frame + 5)
        XCTAssertEqual(
            engine.reactionCountForTesting, 2,
            "a tap after the cooldown reacts (diag: frame=\(frame) reaction=\(String(describing: engine.currentReactionClip)) idle=\(String(describing: engine.activeGestureClip)) count=\(engine.reactionCountForTesting))"
        )
    }

    func testDroppedTapIsAcknowledgedWithEyeContact() throws {
        // Every touch answers (§9 responsiveness): a tap that cannot start a
        // clip (here: inside the active reaction) makes the avatar glance at
        // the user — pupil pull toward the rest direction + a focus pulse —
        // deterministically and without consuming the pick RNG stream.
        let engine = try makeEngine(.ember, seed: 5)
        let reference = try makeEngine(.ember, seed: 5)
        engine.handleEvent(.tap)
        engine.update(toFrame: 5)
        engine.handleEvent(.tap) // dropped: inside the active reaction
        engine.update(toFrame: 8)
        XCTAssertEqual(engine.reactionCountForTesting, 1, "no second clip may start inside the cooldown")
        let focus = ExpressionChannel.focus.rawValue
        XCTAssertGreaterThan(engine.currentPose.expressionWeights[focus],
                             reference.currentPose.expressionWeights[focus],
                             "a dropped tap must pulse the focus channel")
        XCTAssertLessThan(engine.currentPose.offsetsY[engine.bones.lidL],
                          reference.currentPose.offsetsY[reference.bones.lidL],
                          "a dropped tap must lift the lids (an always-visible answer)")
        // The acknowledgment is transient: the engine re-converges with the
        // event-free reference once the pulse has fully faded (the pick RNG
        // stream was never consumed by the dropped tap).
        for frame in 9...90 {
            engine.update(toFrame: frame)
            reference.update(toFrame: frame)
        }
        XCTAssertEqual(engine.currentPose, reference.currentPose,
                       "the acknowledgment must fully fade back to the reference pose")
    }

    func testReactionsSuppressedDuringIdleGesture() throws {
        // With a fixed seed, find the first frame an idle gesture is active;
        // a tap there must not start a reaction (§7 suppression).
        let probe = try makeEngine(.ember, seed: 20261010)
        var gestureFrame = -1
        for frame in 1...1_800 {
            probe.update(toFrame: frame)
            if probe.activeGestureClip != nil {
                gestureFrame = frame
                break
            }
        }
        XCTAssertGreaterThan(gestureFrame, 0, "expected at least one idle gesture in 1 minute")

        let engine = try makeEngine(.ember, seed: 20261010)
        for frame in 1..<gestureFrame {
            engine.update(toFrame: frame)
        }
        engine.handleEvent(.tap)
        engine.update(toFrame: gestureFrame + 1)
        XCTAssertEqual(engine.reactionCountForTesting, 0, "reactions are suppressed during idle gestures")
    }

    func testCrownTickProducesGazeDart() throws {
        let engine = try makeEngine(.ember, seed: 7)
        let reference = try makeEngine(.ember, seed: 7)
        engine.update(toFrame: 100)
        reference.update(toFrame: 100)
        engine.handleEvent(.crownTick(delta: 2))
        engine.update(toFrame: 101)
        reference.update(toFrame: 101)
        XCTAssertEqual(engine.reactionCountForTesting, 0, "crown ticks are a gaze response, not a clip")
        XCTAssertNotEqual(
            engine.currentPose.offsetsX[engine.bones.pupilL],
            reference.currentPose.offsetsX[reference.bones.pupilL],
            "crown ticks must dart the gaze"
        )
        var converged = false
        for frame in 102...140 {
            engine.update(toFrame: frame)
            reference.update(toFrame: frame)
            if engine.currentPose == reference.currentPose {
                converged = true
                break
            }
        }
        XCTAssertTrue(converged, "the gaze dart must decay and the engines re-converge")
    }

    func testL1ReactionsStayOn() throws {
        // L1 disables *idle* motion; reactions are user-initiated and stay.
        // Whichever pooled clip the tap picks, it must move the avatar.
        let engine = try makeEngine(.ember, seed: 3)
        engine.accessibilityMode = .reduceMotionL1
        engine.update(toFrame: 100)
        let reference = try makeEngine(.ember, seed: 3)
        reference.accessibilityMode = .reduceMotionL1
        reference.update(toFrame: 100)
        engine.handleEvent(.tap)
        engine.update(toFrame: 105)
        reference.update(toFrame: 105)
        XCTAssertEqual(engine.reactionCountForTesting, 1)
        XCTAssertNotNil(engine.currentReactionClip, "a pooled clip must be active in L1")
        XCTAssertNotEqual(engine.currentPose, reference.currentPose,
                          "the reaction must move the avatar in L1")
    }

    func testL2ReactionsAreFaceOnly() throws {
        // L2: the body stays static; the tap pool is filtered to clips
        // that write an expression channel, so the reaction reads on the face.
        let engine = try makeEngine(.ember, seed: 3)
        engine.accessibilityMode = .reduceMotionL2
        engine.update(toFrame: 100)
        let baseline = engine.currentPose
        engine.handleEvent(.tap)
        engine.update(toFrame: 105)
        let after = engine.currentPose
        XCTAssertEqual(engine.reactionCountForTesting, 1, "user-initiated reactions stay on in L2")
        guard let clip = engine.currentReactionClip else {
            return XCTFail("a reaction clip must be active in L2")
        }
        XCTAssertTrue(clip.writesExpression, "the L2 tap pool must be filtered to face-readable clips")
        for i in 0..<baseline.rotations.count where i != engine.bones.lidL && i != engine.bones.lidR {
            XCTAssertEqual(after.rotations[i], baseline.rotations[i], "L2 must stay static outside blinks")
            XCTAssertEqual(after.offsetsX[i], baseline.offsetsX[i])
            XCTAssertEqual(after.offsetsY[i], baseline.offsetsY[i])
        }
        if let channel = TestFacialChannels.channel(for: clip) {
            XCTAssertGreaterThan(
                after.expressionWeights[channel.rawValue],
                baseline.expressionWeights[channel.rawValue],
                "the \(clip.rawValue) reaction must read on the face"
            )
        }
    }

    // MARK: Phase B — per-archetype tap pool (B2a)

    /// Taps the engine repeatedly and records which pooled clip answered.
    /// Dropped taps (idle-gesture suppression) are retried at the next
    /// frame; the schedule is deterministic for a given seed.
    private func collectTapPicks(
        _ archetype: Archetype, seed: UInt64,
        mode: MotionAccessibilityMode = .full, count: Int
    ) throws -> [GestureClip] {
        let engine = try makeEngine(archetype, seed: seed)
        engine.accessibilityMode = mode
        let profile = try PersonalityProfile.load(archetype)
        let fade = max(9, min(21, Int(profile.motionProfile.transitionDurationRange.lowerBound * 30)))
        var frame = 30
        engine.update(toFrame: frame)
        var picks: [GestureClip] = []
        var attempts = 0
        while picks.count < count && attempts < count * 30 {
            attempts += 1
            engine.handleEvent(.tap)
            engine.update(toFrame: frame + 1)
            if let clip = engine.currentReactionClip {
                picks.append(clip)
                // Jump past the clip end + cooldown (9) + margin.
                let total = GestureClipLibrary.durationFrames(clip, profile: profile) + fade
                frame += total + 16
                engine.update(toFrame: frame)
            } else {
                frame += 1 // suppressed during an idle gesture — retry
            }
        }
        return picks
    }

    /// Mirrors GestureClipLibrary's clip -> expression channel mapping so
    /// face-readability assertions can name the channel they expect.
    private enum TestFacialChannels {
        static func channel(for clip: GestureClip) -> ExpressionChannel? {
            switch clip {
            case .wave: return .warm
            case .stretch, .sparkle: return .joy
            case .spin: return .wry
            case .lookAround: return .focus
            case .shiver: return .startle
            case .doubleTake: return .surprise
            case .puff: return .alert
            case .preen: return .joy
            case .swayCatch: return .warm
            case .tick: return .focus
            case .mirror: return .surprise
            case .driftFloat: return .warm
            default: return nil
            }
        }
    }

    func testTapPicksOnlyFromProfilePool() throws {
        // Every archetype answers taps in character: only clips with a
        // nonzero profile weight are drawn (§5 gesturePoolWeights).
        for archetype in Archetype.allCases {
            let profile = try PersonalityProfile.load(archetype)
            let pool = Set(profile.gesturePoolWeights.filter { $0.value > 0 }.keys)
            XCTAssertFalse(pool.isEmpty, "\(archetype.rawValue): pool must not be empty")
            let picks = try collectTapPicks(archetype, seed: 99, count: 20)
            XCTAssertGreaterThanOrEqual(picks.count, 10,
                                        "\(archetype.rawValue): expected tap reactions")
            for clip in picks {
                XCTAssertTrue(pool.contains(clip.rawValue),
                              "\(archetype.rawValue) must not react with \(clip.rawValue) (weight 0)")
            }
        }
    }

    func testTapPickSequenceIsDeterministic() throws {
        // Same seed + same event schedule -> same reaction picks (CI
        // replayability, §7 deterministic clock & seeded randomness).
        let a = try collectTapPicks(.ember, seed: 4242, count: 20)
        let b = try collectTapPicks(.ember, seed: 4242, count: 20)
        XCTAssertEqual(a, b, "reaction pick sequences must match for the same seed")
        XCTAssertFalse(a.allSatisfy { $0 == a.first }, "a 4-clip pool should vary across 20 picks")
    }

    func testL2TapPoolIsFaceOnly() throws {
        // In Reduce Motion L2 every tap answer must be a face-readable clip.
        let picks = try collectTapPicks(.ember, seed: 7, mode: .reduceMotionL2, count: 15)
        XCTAssertGreaterThanOrEqual(picks.count, 8)
        for clip in picks {
            XCTAssertTrue(clip.writesExpression, "L2 tap pool must exclude body-only clips (got \(clip.rawValue))")
        }
    }

    func testPoolDistributionRoughlyMatchesWeights() throws {
        // Statistical check on a fixed seed (no flakiness): the empirical
        // pick frequency tracks the profile weights.
        let profile = try PersonalityProfile.load(.ember)
        let picks = try collectTapPicks(.ember, seed: 1234, count: 150)
        var counts: [String: Int] = [:]
        for clip in picks { counts[clip.rawValue, default: 0] += 1 }
        for (name, weight) in profile.gesturePoolWeights where weight > 0 {
            let empirical = Double(counts[name] ?? 0) / Double(picks.count)
            XCTAssertEqual(empirical, Double(weight), accuracy: 0.12,
                           "tap pick frequency for \(name) should track its pool weight")
        }
    }

    // MARK: Phase B — notification bridge (B2b)

    func testNotificationDefaultsAreFaceReadablePerArchetype() throws {
        // Notification reactions must read in Reduce Motion L2 too: every
        // default attention gesture writes an expression channel (explicit
        // gesture events bypass the L2 pool filter, so the defaults must
        // be face-readable by construction).
        for archetype in Archetype.allCases {
            let clip = NotificationAvatarBridge.defaultAttentionGesture(for: archetype)
            XCTAssertTrue(clip.writesExpression,
                          "\(archetype.rawValue) default attention gesture must be face-readable")
        }
    }

    func testNotificationPayloadOverridesDefaultGesture() throws {
        let defaults: [Archetype: GestureClip] = [
            .ember: .wave, .willow: .wave, .compass: .lookAround,
            .prism: .doubleTake, .nimbus: .puff,
        ]
        for (archetype, clip) in defaults {
            XCTAssertEqual(NotificationAvatarBridge.attentionGesture(userInfo: [:], archetype: archetype), clip)
        }
        // An explicit, valid payload wins for every archetype.
        for archetype in Archetype.allCases {
            let userInfo: [AnyHashable: Any] = [NotificationAvatarBridge.gestureUserInfoKey: "shiver"]
            XCTAssertEqual(NotificationAvatarBridge.attentionGesture(userInfo: userInfo, archetype: archetype), .shiver)
            // Unknown clip names fall back to the default (never dropped).
            let bad: [AnyHashable: Any] = [NotificationAvatarBridge.gestureUserInfoKey: "backflip"]
            XCTAssertEqual(NotificationAvatarBridge.attentionGesture(userInfo: bad, archetype: archetype),
                           NotificationAvatarBridge.defaultAttentionGesture(for: archetype))
        }
    }

    func testNotificationGestureEventReachesEngine() throws {
        // End-to-end port check: the bridge's gesture event triggers an L3
        // reaction on the engine — the same port the stage's taps use (§13).
        let engine = try makeEngine(.nimbus, seed: 8)
        engine.update(toFrame: 40)
        engine.handleEvent(.gesture(name: NotificationAvatarBridge.defaultAttentionGesture(for: .nimbus).rawValue))
        engine.update(toFrame: 41)
        XCTAssertEqual(engine.currentReactionClip, .puff, "the notification gesture must play on the engine")
    }

    // MARK: Phase B — companion personality picker (B2c)

    func testArchetypeSelectionPrecedence() throws {
        // Launch argument (CI/smoke reproducibility) > persisted choice >
        // default; corrupt stored values never crash (§9/§10).
        XCTAssertEqual(ArchetypeSelection.resolve(launchOverride: nil, storedRawValue: nil), .ember)
        XCTAssertEqual(ArchetypeSelection.resolve(launchOverride: nil, storedRawValue: "nimbus"), .nimbus)
        XCTAssertEqual(ArchetypeSelection.resolve(launchOverride: .prism, storedRawValue: "nimbus"), .prism,
                       "the launch argument must win for reproducible test runs")
        XCTAssertEqual(ArchetypeSelection.resolve(launchOverride: nil, storedRawValue: "bogus"), .ember,
                       "a corrupted stored value must fall back to the default")
        XCTAssertNil(ArchetypeSelection.fromLaunchArguments([]))
        XCTAssertNil(ArchetypeSelection.fromLaunchArguments(["-archetype", "bogus"]))
        XCTAssertEqual(ArchetypeSelection.fromLaunchArguments(["-archetype", "willow"]), .willow)
    }

    func testEveryArchetypeHasPickerCopy() throws {
        // The picker presents all five at their likable pole (§5 guardrail:
        // no archetype reads as a negative trait).
        for archetype in Archetype.allCases {
            XCTAssertFalse(archetype.displayName.isEmpty)
            XCTAssertFalse(archetype.tagline.isEmpty,
                            "\(archetype.rawValue) needs a likable-pole tagline for the picker")
        }
    }

    // MARK: A5b — v3 motion grammar (gaze policy, blink grammar, settle, tells)

    func testLockGazeStaysNearTheUser() throws {
        // Ember (lock): the gaze spends its life near the user — the mean
        // |pupil offset| over a minute must stay small (a lock, not a beg).
        let ember = try makeEngine(.ember, seed: 20261010)
        var mean: Float = 0
        var samples = 0
        for frame in stride(from: 300, to: 1800, by: 10) {
            ember.update(toFrame: frame)
            mean += abs(ember.currentPose.offsetsX[ember.bones.pupilL])
            samples += 1
        }
        mean /= Float(samples)
        XCTAssertLessThan(mean, 2.0, "ember's lock gaze stays near the user (mean |offset| \(mean))")
    }

    func testMetricSweepIsMetronomicAndRNGFree() throws {
        // Compass's lighthouse sweep alternates user/away on a fixed 150-frame
        // period with no randomness: two engines with different seeds must
        // produce IDENTICAL pupil tracks (policy overrides the saccade RNG).
        let a = try makeEngine(.compass, seed: 1)
        let b = try makeEngine(.compass, seed: 999)
        for frame in 1...900 {
            a.update(toFrame: frame)
            b.update(toFrame: frame)
        }
        XCTAssertEqual(
            a.currentPose.offsetsX[a.bones.pupilL],
            b.currentPose.offsetsX[b.bones.pupilL],
            "the metric sweep must be seed-independent (metronomic, zero variance)"
        )
        XCTAssertNotEqual(
            a.currentPose.offsetsX[a.bones.pupilL], 0,
            "at frame 900 the sweep must be mid-cycle (away phase), not stuck at zero"
        )
    }

    func testDetectThenSettleHasLongFixationHolds() throws {
        // Nimbus: fast darts, then the longest settle — after a saccade the
        // gaze must HOLD (no retargeting) for at least 400 ms (12 frames).
        let nimbus = try makeEngine(.nimbus, seed: 20261010)
        var previous: (x: Float, y: Float) = (0, 0)
        var holdFrames = 0
        var minHold = Int.max
        var saccades = 0
        for frame in 1...1800 {
            nimbus.update(toFrame: frame)
            let x = nimbus.currentPose.offsetsX[nimbus.bones.pupilL]
            let y = nimbus.currentPose.offsetsY[nimbus.bones.pupilL]
            let moved = abs(x - previous.x) > 0.08 || abs(y - previous.y) > 0.08
            if moved {
                if holdFrames > 0, saccades > 0 { minHold = min(minHold, holdFrames) }
                saccades += 1
                holdFrames = 0
            } else {
                holdFrames += 1
            }
            previous = (x, y)
        }
        XCTAssertGreaterThan(saccades, 4, "expected multiple saccades in 60 s")
        XCTAssertGreaterThanOrEqual(minHold, 12,
                                    "every fixation must hold >= 400 ms before release (audit finding 6)")
    }

    func testBlinkGrammarScalesEnvelopePerArchetype() throws {
        // Willow's blink (durationScale 1.8) must be measurably longer than
        // Ember's (0.7): the blink-grammar hook reports the envelope.
        func firstBlinkEnvelope(_ archetype: Archetype) throws -> Int {
            let engine = try makeEngine(archetype, seed: 3)
            var frame = 1
            while frame <= 5400 {
                engine.update(toFrame: frame)
                if engine.blinkCountForTesting > 0 {
                    return engine.lastBlinkEnvelopeFramesForTesting
                }
                frame += 1
            }
            return 0
        }
        let willowLength = try firstBlinkEnvelope(.willow)
        let emberLength = try firstBlinkEnvelope(.ember)
        XCTAssertGreaterThan(willowLength, 0, "willow must blink within 3 minutes")
        XCTAssertGreaterThan(emberLength, 0, "ember must blink within 3 minutes")
        XCTAssertGreaterThan(Float(willowLength), Float(emberLength) * 1.5,
                             "willow's blink must be watchable vs ember's flick (got \(willowLength) vs \(emberLength))")
    }

    func testStartleClipsGetPrecue() throws {
        // Audit finding 6: a startle without a pre-cue reads jump-scare.
        // Shiver always gets a 250 ms (8 frame) pre-cue, scaled by nothing.
        let nimbusProfile = try PersonalityProfile.load(.nimbus)
        XCTAssertEqual(GestureClipLibrary.anticipationFrames(.shiver, profile: nimbusProfile), 8)
        // Big clips keep the plan's >= 120 ms anticipation floor for every
        // archetype, even the bloom-tempo ones (willow dial 0 -> 4 frames).
        let willowProfile = try PersonalityProfile.load(.willow)
        XCTAssertGreaterThanOrEqual(
            GestureClipLibrary.anticipationFrames(.bounce, profile: willowProfile), 4
        )
        // The pre-cue visibly moves the pose before the action: at 3 frames
        // into a shiver reaction the head is already bracing (offset differs
        // from a reference with no event).
        let engine = try makeEngine(.nimbus, seed: 8)
        let reference = try makeEngine(.nimbus, seed: 8)
        engine.update(toFrame: 40)
        reference.update(toFrame: 40)
        engine.handleEvent(.gesture(name: "shiver"))
        engine.update(toFrame: 43)
        reference.update(toFrame: 43)
        XCTAssertNotEqual(engine.currentPose.offsetsY[engine.bones.head],
                          reference.currentPose.offsetsY[reference.bones.head],
                          "the startle pre-cue must brace the head before the flinch")
    }

    func testSettleResidualMatchesGrammar() throws {
        // Willow (settleComplete 0.15): a clip end charges the settle
        // residual and it decays over the following seconds — visible
        // post-gesture life. Compass (1.0): the amplitude contribution is
        // exactly zero (lands like a machine closing). Driven by a named
        // gesture event so the schedule is deterministic, not statistical.
        let willow = try makeEngine(.willow, seed: 20261010)
        willow.update(toFrame: 30)
        willow.handleEvent(.gesture(name: "nod"))  // willow's pool clip
        var charged = false
        var decayed = false
        for frame in 31...220 {
            willow.update(toFrame: frame)
            let amp = willow.settleResidualAmplitudeForTesting
            if amp > 0.005 { charged = true }
            if charged, amp > 0, amp < 0.001 { decayed = true; break }
        }
        XCTAssertTrue(charged, "willow's clip end must charge the settle residual")
        XCTAssertTrue(decayed, "the residual must decay (clamp to zero) after the gesture")

        let compass = try makeEngine(.compass, seed: 5)
        compass.update(toFrame: 30)
        compass.handleEvent(.tap)
        for frame in 31...220 {
            compass.update(toFrame: frame)
            XCTAssertEqual(compass.settleResidualAmplitudeForTesting, 0,
                           "compass lands exactly — the residual amplitude must be zero (settleComplete 1.0)")
        }
    }

    func testTellsTriggerPerArchetype() throws {
        // Compass: the approval tick fires when a reaction completes.
        let compass = try makeEngine(.compass, seed: 5)
        compass.update(toFrame: 30)
        compass.handleEvent(.tap)
        var tickSeen = false
        for frame in 31...120 {
            compass.update(toFrame: frame)
            if compass.tellPhase > 0 { tickSeen = true; break }
        }
        XCTAssertTrue(tickSeen, "compass's approval tick must fire at reaction completion")

        // Nimbus: the luminous pulse starts after any reaction.
        let nimbus = try makeEngine(.nimbus, seed: 5)
        nimbus.update(toFrame: 30)
        nimbus.handleEvent(.tap)
        var pulseSeen = false
        for frame in 31...120 {
            nimbus.update(toFrame: frame)
            if nimbus.tellPhase > 0 { pulseSeen = true; break }
        }
        XCTAssertTrue(pulseSeen, "nimbus's luminous pulse must start after a reaction")

        // Prism: the chromatic flicker triggers on the delight rising edge.
        let prism = try makeEngine(.prism, seed: 5)
        prism.update(toFrame: 30)
        prism.handleEvent(.gesture(name: "sparkle"))  // joy pulse 0.9
        var flickerSeen = false
        for frame in 31...120 {
            prism.update(toFrame: frame)
            if prism.tellPhase > 0 { flickerSeen = true; break }
        }
        XCTAssertTrue(flickerSeen, "prism's chromatic flicker must trigger on delight")

        // Willow: the leaf tell is idle-scheduled (~ every 50 s) — expect at
        // least one in 3 minutes, and the schedule must be deterministic.
        func leafCount(seed: UInt64) -> Int {
            let willow = try! makeEngine(.willow, seed: seed)
            willow.update(toFrame: 5400)
            return willow.tellTriggerCountForTesting
        }
        XCTAssertGreaterThan(leafCount(seed: 20261010), 0,
                             "willow's leaf must fall at least once in 3 idle minutes")
        XCTAssertEqual(leafCount(seed: 20261010), leafCount(seed: 20261010),
                       "the leaf schedule must be deterministic (same seed, same schedule)")
    }

    func testTellsSuppressedInReduceMotionL2() throws {
        // L2 = static pose + gentle blink only (§8): no tells.
        let compass = try makeEngine(.compass, seed: 5)
        compass.accessibilityMode = .reduceMotionL2
        compass.update(toFrame: 30)
        compass.handleEvent(.tap)
        for frame in 31...120 {
            compass.update(toFrame: frame)
            XCTAssertEqual(compass.tellPhase, 0, "tells must be suppressed in Reduce Motion L2")
        }
    }

    // MARK: Phase B — long-press quirk dialogue (B2d)

    func testQuirkGestureMappingPerArchetype() throws {
        // Each archetype's long-press quirk maps its §5 quirk to a clip.
        let expected: [Archetype: GestureClip] = [
            .ember: .spin, .willow: .shiftWeight, .compass: .lookAround,
            .prism: .doubleTake, .nimbus: .shiver,
        ]
        for (archetype, clip) in expected {
            XCTAssertEqual(archetype.quirkGesture, clip)
        }
        XCTAssertTrue(Archetype.ember.quirkGesture.isBig,
                      "Ember's spark-trail quirk must be a big clip (drives §8 accent particles)")
    }

    func testReactionBigClipsDriveSparkPhase() throws {
        // The §8 spark pool fires for big reaction clips too (Ember's
        // long-press spark-trail), not just idle gestures.
        let engine = try makeEngine(.ember, seed: 31)
        // Find a quiet frame (no idle gesture, no phase).
        var frame = 1
        while frame < 600 {
            engine.update(toFrame: frame)
            if engine.activeGestureClip == nil, engine.activeGesturePhase == 0 { break }
            frame += 5
        }
        XCTAssertEqual(engine.activeGesturePhase, 0, "expected a quiet frame with no idle gesture")
        engine.handleEvent(.gesture(name: "spin"))
        // Step past the anticipation/pre-cue frames (ember: 5) into the
        // action phase — the spark trail starts with the action.
        engine.update(toFrame: frame + 10)
        XCTAssertGreaterThan(engine.activeGesturePhase, 0,
                             "a big reaction clip must drive the accent-particle phase")
    }

    func testL2BodyOnlyQuirkDegradesToFaceReadable() throws {
        // In L2 the body is flattened: Willow's weight-shift quirk would
        // react invisibly, so it degrades to a face-readable in-character
        // pick (§8 trumps scripting). Full mode honors it as-is.
        let l2 = try makeEngine(.willow, seed: 3)
        l2.accessibilityMode = .reduceMotionL2
        l2.update(toFrame: 50)
        l2.handleEvent(.gesture(name: "shiftWeight"))
        l2.update(toFrame: 51)
        guard let degraded = l2.currentReactionClip else {
            return XCTFail("the quirk must still react in L2")
        }
        XCTAssertNotEqual(degraded, .shiftWeight, "a body-only clip must not play invisibly in L2")
        XCTAssertTrue(degraded.writesExpression, "the L2 quirk degradation must be face-readable")

        let full = try makeEngine(.willow, seed: 3)
        full.update(toFrame: 50)
        full.handleEvent(.gesture(name: "shiftWeight"))
        full.update(toFrame: 51)
        XCTAssertEqual(full.currentReactionClip, .shiftWeight,
                       "full mode honors explicit gesture events as-is")
    }

    // MARK: Painter (§8)

    func testPainterProducesCommandsForEverySlotWithinCapacity() throws {
        let engine = try makeEngine(.prism, seed: 1)
        engine.update(toFrame: 60)
        let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
        painter.paint(world: engine.currentWorld, pose: engine.currentPose, rest: false)
        XCTAssertGreaterThan(painter.commandCount, 0)
        XCTAssertLessThanOrEqual(painter.commandCount, painter.commandCapacity)

        let slotCount = engine.skeleton.document.slots.count
        XCTAssertGreaterThanOrEqual(painter.commandCount, slotCount)

        // Colors resolved: face features use a non-black face accent.
        let face = painter.roleColors[.face] ?? (0, 0, 0)
        XCTAssertFalse(face.0 == 0 && face.1 == 0 && face.2 == 0)
    }

    // MARK: Performance (§11 frame budget, CPU side)

    func testEngineUpdateCostPerFrame() throws {
        // Full A2 engine + FK + follow-through. This measures the CPU cost of
        // the engine half of the frame budget (the renderer half was measured
        // in A0); sim numbers only — Instruments on hardware is the §11 gate.
        let engine = try makeEngine(.nimbus, seed: 9)
        engine.update(toFrame: 300)
        let start = CFAbsoluteTimeGetCurrent()
        for frame in 301...1300 {
            engine.update(toFrame: frame)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perFrameMs = elapsed / 1000 * 1000
        XCTAssertLessThan(perFrameMs, 2.0, "engine update must stay far under the 33 ms frame budget, got \(perFrameMs) ms/frame")
    }

    // MARK: A3 — Expression channel coverage & archetype separation

    func testEveryExpressionChannelMovesTheFace() throws {
        // §6: each of the 10 channels is a curve mixing brow/lid/mouth/
        // pupil — every channel must drive at least one face bone.
        let engine = try makeEngine(.willow, seed: 1)
        let bones = engine.bones
        let faceBones = [
            bones.browL, bones.browR, bones.lidL, bones.lidR,
            bones.pupilL, bones.pupilR, bones.mouth, bones.jaw,
        ]
        for channel in ExpressionChannel.allCases {
            var baseline = AvatarPose(boneCount: engine.skeleton.boneCount)
            baseline.resetToNeutral()
            var expressions = [Float](repeating: 0, count: ExpressionChannel.count)
            expressions[channel.rawValue] = 1
            ExpressionMixer.apply(expressions: expressions, bones: bones, pose: &baseline)
            let moved = faceBones.contains {
                baseline.rotations[$0] != 0
                    || baseline.offsetsX[$0] != 0
                    || baseline.offsetsY[$0] != 0
                    || baseline.scalesX[$0] != 1
                    || baseline.scalesY[$0] != 1
            }
            XCTAssertTrue(moved, "\(channel) must drive at least one face bone (§6)")
        }
    }

    func testArchetypeExpressionSetsSeparate() throws {
        // A3 separation gate: each archetype's gesture pool drives its
        // signature expression channels over a deterministic 10-minute run
        // (the wake greeting is excluded by starting after frame 60).
        func observedChannels(_ archetype: Archetype) throws -> Set<Int> {
            let engine = try makeEngine(archetype, seed: 20261010)
            var seen = Set<Int>()
            for frame in 61...18_000 {
                engine.update(toFrame: frame)
                for (i, weight) in engine.currentPose.expressionWeights.enumerated() where weight > 0.05 {
                    seen.insert(i)
                }
            }
            return seen
        }

        let warm = ExpressionChannel.warm.rawValue
        let joy = ExpressionChannel.joy.rawValue
        let wry = ExpressionChannel.wry.rawValue
        let focus = ExpressionChannel.focus.rawValue
        let surprise = ExpressionChannel.surprise.rawValue
        let startle = ExpressionChannel.startle.rawValue
        let alert = ExpressionChannel.alert.rawValue

        let ember = try observedChannels(.ember)
        let willow = try observedChannels(.willow)
        let compass = try observedChannels(.compass)
        let prism = try observedChannels(.prism)
        let nimbus = try observedChannels(.nimbus)

        XCTAssertFalse(ember.isDisjoint(with: [warm, joy, wry]), "ember pool (wave/stretch/spin) drives warm, joy or wry")
        XCTAssertFalse(willow.isDisjoint(with: [warm, joy]), "willow pool (wave/stretch) drives warm or joy")
        XCTAssertFalse(compass.isDisjoint(with: [warm, focus]), "compass pool (wave/lookAround) drives warm or focus")
        XCTAssertGreaterThanOrEqual(prism.count, 2, "prism pool (stretch/spin/doubleTake/sparkle) drives several channels")
        XCTAssertFalse(nimbus.isDisjoint(with: [startle, alert, joy]), "nimbus pool (shiver/puff/sparkle) drives startle, alert or joy")

        // Separation proxy (§11): the five observed channel sets are not all
        // identical — personalities must not read as the same character.
        let sets = [ember, willow, compass, prism, nimbus]
        let distinct = Set(sets.map { $0.sorted() })
        XCTAssertGreaterThan(distinct.count, 1, "archetype expression sets must separate")
    }

    // MARK: A3 — Wake/sleep transition (§8 delight moment)

    func testWakeGreetingBloomAndEyesLead() throws {
        let engine = try makeEngine(.ember, seed: 3)
        engine.setResting(true)
        engine.setResting(false) // wrist raise

        // Warm greeting blooms through the wake, then fades within ~1 s.
        var peak: Float = 0
        var late: Float = -1
        for frame in 1...70 {
            engine.update(toFrame: frame)
            let warmWeight = engine.currentPose.expressionWeights[ExpressionChannel.warm.rawValue]
            if frame <= 50 { peak = max(peak, warmWeight) } else { late = warmWeight }
        }
        XCTAssertGreaterThan(peak, 0.2, "warm greeting must bloom after wake")
        XCTAssertLessThan(late, 0.05, "greeting must fade within ~1 s")

        // Eyes lead the wake (§4 staging): at wake frame 12 the lids are at
        // their live pose while the head is still rising from the rest pose.
        let waking = try makeEngine(.ember, seed: 3)
        waking.setResting(true)
        waking.setResting(false)
        let live = try makeEngine(.ember, seed: 3)
        for frame in 1...12 {
            waking.update(toFrame: frame)
            live.update(toFrame: frame)
        }
        let lidDelta = abs(waking.currentPose.offsetsY[waking.bones.lidL] - live.currentPose.offsetsY[live.bones.lidL])
        let headDelta = abs(waking.currentPose.offsetsY[waking.bones.head] - live.currentPose.offsetsY[live.bones.head])
        XCTAssertLessThan(lidDelta, 0.3, "lids must reach the live pose ahead of the body")
        XCTAssertGreaterThan(headDelta, 0.5, "the body must still be mid-blend while the eyes have led")
    }

    // MARK: A4 — Reduce Motion parity across all five archetypes (§11)

    func testReduceMotionModesPassForAllArchetypes() throws {
        for archetype in Archetype.allCases {
            // L1: idle gestures disabled, breathing + blinking continue.
            let l1 = try makeEngine(archetype, seed: 20261010)
            l1.accessibilityMode = .reduceMotionL1
            l1.update(toFrame: 9_000)
            XCTAssertEqual(l1.triggeredGestureCount, 0, "\(archetype): L1 must disable idle gestures")
            var minScale: Float = 2
            var maxScale: Float = 0
            for frame in 9_001...9_120 {
                l1.update(toFrame: frame)
                let s = l1.currentPose.scalesX[l1.bones.chest]
                minScale = min(minScale, s)
                maxScale = max(maxScale, s)
            }
            XCTAssertGreaterThan(maxScale - minScale, 0.01, "\(archetype): breathing must continue in L1")

            // L2: static pose outside blinks.
            let l2 = try makeEngine(archetype, seed: 20261010)
            l2.accessibilityMode = .reduceMotionL2
            l2.update(toFrame: 100)
            let baseline = l2.currentPose
            l2.update(toFrame: 160)
            let after = l2.currentPose
            for i in 0..<baseline.rotations.count
            where i != l2.bones.lidL && i != l2.bones.lidR {
                XCTAssertEqual(after.rotations[i], baseline.rotations[i], "\(archetype): L2 must be static outside blinks")
                XCTAssertEqual(after.offsetsX[i], baseline.offsetsX[i])
                XCTAssertEqual(after.offsetsY[i], baseline.offsetsY[i])
            }
        }
    }

    // MARK: A4 — Cold launch (§11: < 1 s to first frame, engine side)

    func testColdStartToFirstFrameCost() throws {
        // The engine half of cold launch: load rig + profile, build engine,
        // first update, first paint. App process spin-up and the first
        // CoreAnimation frame are on-device Instruments work (blocked: no
        // hardware); this bounds the part the avatar code owns.
        let start = CFAbsoluteTimeGetCurrent()
        let engine = try makeEngine(.ember, seed: 42)
        engine.update(toFrame: 1)
        let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
        painter.paint(world: engine.currentWorld, pose: engine.currentPose, rest: false)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 1.0, "engine-side cold start to first frame must be < 1 s, got \(elapsed) s")
    }
}

// MARK: - A4 performance measurements (§11 frame budget, CPU side)

final class AvatarPerformanceTests: XCTestCase {
    private func makeEngine(_ archetype: Archetype, seed: UInt64 = 9) throws -> AvatarEngine {
        AvatarEngine(
            skeleton: try Skeleton(document: try RigDocument.load(bundle: .main)),
            profile: try PersonalityProfile.load(archetype, bundle: .main),
            seed: seed
        )
    }

    /// Engine update cost: the layered update + FK + follow-through per frame.
    /// Budget: far under 33 ms (30 FPS); target < 2 ms so the renderer and
    /// system get the rest of the frame.
    func testMeasureEngineUpdatePerFrame() throws {
        let engine = try makeEngine(.nimbus)
        engine.update(toFrame: 300)
        // Each measure iteration must advance fresh frames: once the clock
        // reaches a target, update(toFrame:) is a no-op, so the window moves
        // forward every iteration.
        var base = 300
        measure {
            for frame in (base + 1)...(base + 300) {
                engine.update(toFrame: frame)
            }
            base += 300
        }
    }

    /// Painter command-buffer cost per frame (pre-allocated; the Canvas
    /// closure then just replays commands). Same < 2 ms target.
    func testMeasurePaintCostPerFrame() throws {
        let engine = try makeEngine(.ember)
        engine.update(toFrame: 600)
        let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
        measure {
            for _ in 0..<300 {
                painter.paint(
                    world: engine.currentWorld,
                    pose: engine.currentPose,
                    rest: false,
                    accentPhase: engine.activeGesturePhase
                )
            }
        }
    }

    /// Hi-bit pixel stage cost (§11.3): rasterize + LUT snap of the 51x63
    /// grid must stay a small fraction of the 33 ms frame budget (the
    /// stage also halves its tick rate to 15 fps).
    func testMeasurePixelRasterizeCostPerFrame() throws {
        let engine = try makeEngine(.ember)
        engine.update(toFrame: 600)
        let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
        let rasterizer = PixelStageRasterizer(painter: painter)
        painter.paint(
            world: engine.currentWorld,
            pose: engine.currentPose,
            rest: false,
            accentPhase: engine.activeGesturePhase,
            tell: engine.tell,
            tellPhase: engine.tellPhase
        )
        measure {
            for _ in 0..<300 {
                rasterizer.rasterize(painter: painter)
            }
        }
    }
}

// MARK: - A3 Golden-frame visual regression (§10, §11)

/// Builds an engine for a deterministic golden-frame render.
private func makeGoldenEngine(_ archetype: Archetype, seed: UInt64 = 42) throws -> AvatarEngine {
    AvatarEngine(
        skeleton: try Skeleton(document: try RigDocument.load(bundle: .main)),
        profile: try PersonalityProfile.load(archetype, bundle: .main),
        seed: seed
    )
}

/// A CPU-rasterized frame's pixels (RGBA8, 205x251), copied out of the
/// raster context so it outlives the context.
private struct RasterBytes {
    let width = 205
    let height = 251
    let bytes: [UInt8]

    /// Binary silhouette mask: any channel above the background threshold
    /// (matches the smoke test's lit-pixel definition).
    func silhouetteMask(threshold: UInt8 = 8) -> [Bool] {
        var mask = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) {
            let o = i * 4
            mask[i] = max(bytes[o], max(bytes[o + 1], bytes[o + 2])) > threshold
        }
        return mask
    }

    /// Mean color of lit pixels (0...255 per channel) — the tint signal.
    func meanLitColor(threshold: UInt8 = 8) -> (Double, Double, Double) {
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for i in 0..<(width * height) {
            let o = i * 4
            if max(bytes[o], max(bytes[o + 1], bytes[o + 2])) > threshold {
                r += Double(bytes[o]); g += Double(bytes[o + 1]); b += Double(bytes[o + 2]); n += 1
            }
        }
        guard n > 0 else { return (0, 0, 0) }
        return (r / n, g / n, b / n)
    }

    /// Intersection-over-union of two binary masks (1 = identical).
    static func iou(_ a: [Bool], _ b: [Bool]) -> Double {
        var inter = 0, union = 0
        for i in 0..<a.count {
            if a[i] { union += 1 }
            if b[i] { union += b[i] && !a[i] ? 1 : 0 }
            if a[i] && b[i] { inter += 1 }
        }
        guard union > 0 else { return 1 }
        return Double(inter) / Double(union)
    }
}

/// Golden-frame rasterizer (§10): renders the painter's command buffer
/// offscreen with CoreGraphics (CPU rasterization, deterministic) and hashes
/// the pixels with FNV-1a. Same seed + frame -> same hash, so any visual
/// change (geometry, palette, mixer, engine) shows up as a hash change.
private enum GoldenFrameRasterizer {
    static func render(archetype: Archetype, seed: UInt64 = 42, frame: Int = 300,
                       interiority: InteriorityTuning = .default) throws -> RasterBytes {
        let engine = try makeGoldenEngine(archetype, seed: seed)
        engine.update(toFrame: frame)
        let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet,
                                          interiority: interiority)
        painter.paint(
            world: engine.currentWorld,
            pose: engine.currentPose,
            rest: false,
            accentPhase: engine.activeGesturePhase,
            tell: engine.tell,
            tellPhase: engine.tellPhase
        )

        let width = 205
        let height = 251
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "GoldenFrameRasterizer", code: 1)
        }

        // Rig space is y-down with the origin at the canvas CENTER (head
        // chain up, tail down). Flip for y-up CG space and add the center
        // offset — same mapping as the live Canvas path.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let centerX = CGFloat(width) / 2
        let centerY = CGFloat(height) / 2
        for i in 0..<painter.commandCount {
            let command = painter.commands[i]
            ctx.saveGState()
            ctx.translateBy(x: centerX + CGFloat(command.tx), y: centerY + CGFloat(command.ty))
            ctx.rotate(by: CGFloat(command.rotation))
            ctx.scaleBy(x: CGFloat(command.scaleX), y: CGFloat(command.scaleY))
            ctx.addPath(painter.shapes[command.shapeIndex].paths[command.pathIndex])
            if command.useGradient {
                // Volumetric fill, same span math as the live Canvas path.
                // Gradients are cached per stop pair (static set per
                // archetype -> cache warm after first use).
                let shape = painter.shapes[command.shapeIndex]
                let startY: CGFloat
                let endY: CGFloat
                if shape.perPathGradient {
                    startY = -CGFloat(shape.pathHeights[command.pathIndex]) / 2
                    endY = CGFloat(shape.pathHeights[command.pathIndex]) / 2
                } else {
                    let offset = CGFloat(shape.offsetsY[command.pathIndex])
                    startY = -(CGFloat(shape.height) / 2 + offset)
                    endY = CGFloat(shape.height) / 2 - offset
                }
                let gradient = try Self.cachedGradient(command: command)
                ctx.clip()
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: startY),
                    end: CGPoint(x: 0, y: endY),
                    options: []
                )
            } else {
                ctx.setFillColor(CGColor(
                    colorSpace: CGColorSpaceCreateDeviceRGB(),
                    components: [CGFloat(command.r), CGFloat(command.g), CGFloat(command.b), CGFloat(command.a)]
                )!)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }

        guard let data = ctx.data else { throw NSError(domain: "GoldenFrameRasterizer", code: 2) }
        let raw = data.assumingMemoryBound(to: UInt8.self)
        let bytes = [UInt8](UnsafeBufferPointer(start: raw, count: width * height * 4))
        return RasterBytes(bytes: bytes)
    }

    static func hash(archetype: Archetype, seed: UInt64 = 42, frame: Int = 300) throws -> UInt64 {
        let raster = try render(archetype: archetype, seed: seed, frame: frame)
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a offset basis
        for byte in raster.bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3 // FNV-1a prime
        }
        return hash
    }

    /// CGGradient cache per stop pair (v3 volumetric shading) — static set
    /// per archetype, so this fills once and never churns. Test-only.
    private nonisolated(unsafe) static var gradientCache: [UInt64: CGGradient] = [:]

    private static func cachedGradient(command: SpriteCommand) throws -> CGGradient {
        func q(_ v: Float) -> UInt64 { UInt64(max(0, min(255, v * 255))) }
        let key = (q(command.r) << 40) | (q(command.g) << 32) | (q(command.b) << 24)
            | (q(command.r2) << 16) | (q(command.g2) << 8) | q(command.b2)
        if let cached = gradientCache[key] { return cached }
        let colors = [
            CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                    components: [CGFloat(command.r), CGFloat(command.g), CGFloat(command.b), 1])!,
            CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                    components: [CGFloat(command.r2), CGFloat(command.g2), CGFloat(command.b2), 1])!,
        ]
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 1]
        )!
        gradientCache[key] = gradient
        return gradient
    }
}

/// Golden-frame visual regression per archetype (§10 pipeline, §11
/// continuity): each archetype's frame-300 render is pinned by hash; renders
/// are deterministic across engine instances and pairwise distinct (the
/// silhouette/palette separation proxy until the A4 perception study).
final class GoldenFrameTests: XCTestCase {
    func testGoldenFramesMatchRecordedHashes() throws {
        // Recorded from the watchOS simulator (CPU-rasterized, stable).
        // Update deliberately — and say why — when a visual change is intended.
        // v2: re-recorded after fixing the rig-origin mapping (the rig origin
        // is the canvas center; the first pins captured off-screen slivers).
        // v3 (nimbus only): Nimbus's head is now the three-puff brand cloud
        // (logo geometry) and its primary palette is harmonized with the
        // logo's lavender family (#9C86DB).
        // v4: L1 life-loop amplitudes raised for visible motion (breathing
        // chest scale ~2.3x, sway rotation ~3x, heartbeat bob ~2.4x) — the
        // post-polish assessment found the avatar read as frozen between
        // blinks (~2% pixels moved per second).
        // v5 (A5a): the v3 unified cloud-species — every archetype is now
        // the cloud anatomy (3-puff head, puff masses, wisp antenna, no
        // limbs) with tint + token + tell; wave/stretch re-authored
        // whole-body; catchlights on the pupils.
        // v6 (A5b): motion grammar live — gaze policies (fixation holds,
        // metric sweep), drift-scaled sway, blink grammar envelopes,
        // anticipation/pre-cue phases, settle residual, tell rendering.
        // v7 (A5b.1): volumetric shading — per-mass gradients (top lit),
        // per-puff occlusion on the cloud head, foliage/flame gradients.
        // v8 (A5b.2): bounce-light lift on gradient bottoms (fake SSS) +
        // rim-light crescent on the head (species spec silver rim).
        // v9 (A6.1): vivid v4 palettes (§11.2) — muted tints replaced with
        // saturated hue-separated bodies.
        // v10 (A6.2): per-archetype body plans — flame/gem/pyramid heads,
        // chamfered/sag masses, reference decorations.
        // v11 (A6.3): posture wander (alive pass) + facet contrast polish.
        // v12 (v5): radical body plans (flame/bush/gem/pyramid/cloud) +
        // pixel-stage default + nimbus indigo palette.
        // v13 (v5b): quirk clips — pool weights changed the seeded idle
        // schedule, but the pinned frames carry no active gesture, so the
        // v12 hashes carry over unchanged.
        // v14 (v7): pixel-design cute pass (Tools/PIXEL_DESIGN.md) — ears
        // on every species, enlarged pupils + catchlights, face inset,
        // so the command buffer at the golden pose changed deliberately.
        let expected: [Archetype: UInt64] = [
            .ember: 10_797_589_159_950_752_963,
            .willow: 11_632_248_360_311_394_863,
            .compass: 12_846_232_288_341_441_366,
            .prism: 329_223_719_153_816_148,
            .nimbus: 18_338_159_615_810_752_377,
        ]

        var actual: [Archetype: UInt64] = [:]
        for archetype in Archetype.allCases {
            let hash = try GoldenFrameRasterizer.hash(archetype: archetype)
            actual[archetype] = hash
            let pin = expected[archetype] ?? 0
            if pin != 0 {
                XCTAssertEqual(hash, pin, "\(archetype.rawValue) golden frame changed")
            }
        }

        let recorded = Archetype.allCases
            .map { "\($0.rawValue) = \(actual[$0]!)" }
            .joined(separator: ", ")
        XCTAssertTrue(
            expected.values.allSatisfy { $0 != 0 },
            "RECORD MODE — golden hashes to pin: \(recorded)"
        )
    }

    func testGoldenFramesAreDeterministicAcrossEngines() throws {
        for archetype in Archetype.allCases {
            let first = try GoldenFrameRasterizer.hash(archetype: archetype)
            let second = try GoldenFrameRasterizer.hash(archetype: archetype)
            XCTAssertEqual(first, second, "\(archetype.rawValue) golden frame must be reproducible (same seed, same frame)")
        }
    }

    func testArchetypeGoldenFramesArePairwiseDistinct() throws {
        var seen: [UInt64] = []
        for archetype in Archetype.allCases {
            let hash = try GoldenFrameRasterizer.hash(archetype: archetype)
            XCTAssertFalse(seen.contains(hash), "\(archetype.rawValue) golden frame collides with an earlier archetype — visual sets must separate")
            seen.append(hash)
        }
    }
}

/// Machine proxy for the §11 silhouette-readability criterion (the A1
/// v3 species invariants (A5a, §6 v2). The silhouette is deliberately
/// CONSTANT across all five archetypes — motion-only personality attribution
/// is the A4 experiment, so anatomy must not be a confound. Distinctness
/// rests on the tint + token + tell stack: pairwise silhouette IoU must stay
/// high (constancy), and the mean lit color (tint) must separate pairwise.
///
/// This SUPERSEDES the v1 silhouette-readability gate (§11 amendment,
/// ratified with the v3 direction): with one species, "identify the
/// archetype from silhouette alone" is void by design. The acceptance
/// criterion becomes stance legibility (<= 3 s, motion + tint + tell),
/// measured in the A4 perception study.
final class SpeciesInvariantsTests: XCTestCase {
    /// Constancy: every pair of archetypes shares the same cloud silhouette.
    /// 0.85 leaves room for the sanctioned trait tokens — Willow's drooping
    /// base + leaf wisps + sprout measure 0.881-0.888 vs the others — while
    /// failing hard if anatomy ever diverges (a square head lands ~0.6-0.7).
    /// v4 shadow test (§11.1, §11.2 — SUPERSEDES the v3 constancy
    /// invariant): distinctness moved to the SILHOUETTE level; every pair
    /// must be identifiable from its black silhouette alone. Machine
    /// proxy: pairwise silhouette IoU must stay low enough that the body
    /// plans are pairwise distinguishable (flame / weeping bush / gem /
    /// pyramid / cloud).
    func testSilhouettesSeparateAcrossArchetypes() throws {
        var masks: [Archetype: [Bool]] = [:]
        for archetype in Archetype.allCases {
            let raster = try GoldenFrameRasterizer.render(archetype: archetype)
            masks[archetype] = raster.silhouetteMask()
        }
        let sorted = Archetype.allCases
        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                let a = sorted[i], b = sorted[j]
                let overlap = RasterBytes.iou(masks[a]!, masks[b]!)
                XCTAssertLessThan(
                    overlap, 0.60,
                    "\(a.rawValue)/\(b.rawValue) silhouettes too similar (IoU \(String(format: "%.3f", overlap)) >= 0.60) — v5 body plans must diverge radically (shadow test; the v4 0.92 bar let all five pass at ~0.75-0.83, which read as recolors of one body)"
                )
            }
        }
    }

    /// Tint separation: the mean lit color of each golden frame must differ
    /// pairwise by a visible margin (0...255 scale) — identity is tint,
    /// so two archetypes drifting to the same tint is a regression.
    func testTintSeparatesArchetypes() throws {        var tints: [Archetype: (Double, Double, Double)] = [:]
        for archetype in Archetype.allCases {
            let raster = try GoldenFrameRasterizer.render(archetype: archetype)
            tints[archetype] = raster.meanLitColor()
        }
        let sorted = Archetype.allCases
        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                let a = sorted[i], b = sorted[j]
                let ta = tints[a]!, tb = tints[b]!
                let distance = sqrt(
                    pow(ta.0 - tb.0, 2) + pow(ta.1 - tb.1, 2) + pow(ta.2 - tb.2, 2)
                )
                XCTAssertGreaterThanOrEqual(
                    distance, 20,
                    "\(a.rawValue)/\(b.rawValue) tints too close (distance \(String(format: "%.1f", distance)) < 20) — the token stack must separate"
                )
            }
        }
    }
}

extension SpeciesInvariantsTests {
    /// v3 volumetric shading (A5b.1): every mass shades light-top ->
    /// dark-bottom under the key light. Measured on the head's middle puff
    /// with EXACT geometry: the band rows come from the head bone's world
    /// position (the puff spans +/-21.5 rig units around it), not from a
    /// lit-run scan — a scan anchors late on the puff's narrow top arc and
    /// its "chin" band then leaks into the bright torso-top gradient, which
    /// is what the earlier inverted measurements were. (A whole-silhouette
    /// upper/lower split is NOT the invariant: Willow's drooping base and
    /// Prism's patches legitimately brighten the lower region.)
    func testHeadMassShadesTopToBottom() throws {
        // v4: only the blob-head archetypes (willow, nimbus) have the
        // three-puff head geometry this test measures (±21.5 around the
        // head bone); the flame/gem/pyramid heads shade via the same
        // gradient machinery but have different extents.
        for archetype in blobHeads {
            let engine = try makeGoldenEngine(archetype)
            engine.update(toFrame: 300)
            let raster = try GoldenFrameRasterizer.render(archetype: archetype)
            let headWorld = engine.currentWorld[engine.bones.head]
            let centerY = Double(raster.height) / 2
            // v5: head slot heights are per-archetype now — the puff extent
            // comes from the v5 scale table, not the old fixed ±21.5.
            let headScale = AvatarSpritePainter.speciesSlotScale(archetype: archetype, slotName: "head") ?? (w: 1, h: 1)
            let puffHalf = 46.0 * Double(headScale.h) * 0.934 / 2
            let puffTop = Int(centerY + Double(headWorld.ty) - puffHalf)
            let puffBottom = Int(centerY + Double(headWorld.ty) + puffHalf)

            func meanLum(_ y0: Int, _ y1: Int) -> (Double, Int) {
                let lo = max(0, y0)
                let hi = min(raster.height, y1)
                guard lo < hi else { return (0, 0) }
                var lum = 0.0
                var n = 0
                for y in lo..<hi {
                    for x in (raster.width / 3)..<(2 * raster.width / 3) {
                        let o = (y * raster.width + x) * 4
                        guard max(raster.bytes[o], max(raster.bytes[o + 1], raster.bytes[o + 2])) > 8 else { continue }
                        lum += 0.299 * Double(raster.bytes[o])
                            + 0.587 * Double(raster.bytes[o + 1])
                            + 0.114 * Double(raster.bytes[o + 2])
                        n += 1
                    }
                }
                return (lum / Double(max(n, 1)), n)
            }
            // Bands inside the middle puff, clear of the antenna (above),
            // the eyes (middle) and the torso top (below the puff bottom).
            let (top, topN) = meanLum(puffTop, puffTop + 10)
            let (chin, chinN) = meanLum(puffBottom - 10, puffBottom)
            // Diagnostic trace (failure message only).
            var trace: [String] = []
            for y in stride(from: max(puffTop - 6, 0), to: min(puffBottom + 6, raster.height), by: 6) {
                let (lum, n) = meanLum(y, y + 4)
                trace.append("y\(y)=\(Int(lum))(n\(n))")
            }
            XCTAssertGreaterThan(topN, 20, "\(archetype.rawValue): head top band should be lit")
            XCTAssertGreaterThan(chinN, 20, "\(archetype.rawValue): head chin band should be lit")
            XCTAssertGreaterThan(
                top, chin + 10,
                "\(archetype.rawValue): the head mass must shade light-top -> dark-bottom (top \(String(format: "%.1f", top)) vs chin \(String(format: "%.1f", chin))); trace: \(trace.joined(separator: " "))"
            )
        }
    }

    /// A5b.2 rim light: the blob-head archetypes (willow, nimbus — v4
    /// keeps the round cloud head for them) each emit a flat, translucent,
    /// near-silver crescent command (species spec §6 v2 "faint silver rim
    /// light") — and the rest LOD must NOT emit it (wrist-down is the
    /// designed sleep pose; no highlights on a sleeping body). The v4
    /// non-blob heads (flame, gem, pyramid) carry their silhouette
    /// identity instead — no rim.
    private var blobHeads: [Archetype] { [.willow, .nimbus] }

    func testHeadRimLightCommand() throws {
        for archetype in Archetype.allCases {
            let engine = try makeGoldenEngine(archetype)
            engine.update(toFrame: 300)
            let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
            painter.paint(
                world: engine.currentWorld,
                pose: engine.currentPose,
                rest: false,
                accentPhase: engine.activeGesturePhase,
                tell: engine.tell,
                tellPhase: engine.tellPhase
            )
            var rimCommands = 0
            for i in 0..<painter.commandCount {
                let command = painter.commands[i]
                let shape = painter.shapes[command.shapeIndex]
                guard command.pathIndex < shape.pathShades.count,
                      shape.pathShades[command.pathIndex] < 0 else { continue }
                rimCommands += 1
                XCTAssertFalse(command.useGradient, "\(archetype.rawValue): rim light must be a flat fill")
                XCTAssertEqual(command.a, AvatarSpritePainter.rimLightAlpha, accuracy: 0.001, "\(archetype.rawValue): rim light is translucent (a highlight, not a sticker)")
                XCTAssertEqual(command.r, AvatarSpritePainter.rimLight.0, accuracy: 0.001)
                XCTAssertEqual(command.g, AvatarSpritePainter.rimLight.1, accuracy: 0.001)
                XCTAssertEqual(command.b, AvatarSpritePainter.rimLight.2, accuracy: 0.001)
            }
            XCTAssertEqual(rimCommands, blobHeads.contains(archetype) ? 1 : 0,
                           "\(archetype.rawValue): rim-light crescent exists only on blob-head archetypes")

            // Rest LOD: the rim path must blend in (full alpha) so the
            // sleep pose carries no highlight.
            painter.paint(
                world: engine.currentWorld,
                pose: engine.currentPose,
                rest: true,
                accentPhase: 0,
                tell: nil,
                tellPhase: 0
            )
            for i in 0..<painter.commandCount {
                let command = painter.commands[i]
                let shape = painter.shapes[command.shapeIndex]
                guard command.pathIndex < shape.pathShades.count,
                      shape.pathShades[command.pathIndex] < 0 else { continue }
                XCTAssertEqual(command.a, 1, accuracy: 0.001, "\(archetype.rawValue): rest LOD must not render a rim highlight")
            }
        }
    }
}

// MARK: - A6.1 hi-bit pixel stage (§11.3 v4)

/// Pixel-frame visual regression: renders the 51x63 LUT-snapped grid per
/// archetype at the golden pose and pins it by FNV-1a hash (same
/// determinism contract as the vector golden frames — same seed, same
/// pose, same pixels).
final class PixelStageTests: XCTestCase {
    private func makeRasterizer(_ archetype: Archetype, seed: UInt64 = 42, frame: Int = 300) throws -> PixelStageRasterizer {
        let engine = try makeGoldenEngine(archetype, seed: seed)
        engine.update(toFrame: frame)
        let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
        painter.paint(
            world: engine.currentWorld,
            pose: engine.currentPose,
            rest: false,
            accentPhase: engine.activeGesturePhase,
            tell: engine.tell,
            tellPhase: engine.tellPhase
        )
        let rasterizer = PixelStageRasterizer(painter: painter)
        rasterizer.rasterize(painter: painter)
        return rasterizer
    }

    private func hash(_ bytes: [UInt8]) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return value
    }

    func testPixelFramesMatchRecordedHashes() throws {
        // v1 (A6.1): first pixel-stage pins — vivid v4 palettes, 51x63
        // grid, LUT snap. Update deliberately — and say why.
        // v2 (bugfix): restDim removed from the active snap candidates
        // (face-mud fix).
        // v3 (A6.2): per-archetype body plans.
        // v4 (A6.3): posture wander + facet contrast polish.
        // v5 (v5): radical body plans + 64x78 grid + pixel-stage default.
        // v6 (v5b): quirk clips — pool weights changed the seeded idle
        // schedule, but the pinned frames carry no active gesture, so the
        // v5 hashes carry over unchanged.
        // v7 (v6 hi-bit mascot polish): Bayer-ordered dithering in the LUT
        // snap + dithered 1-px halo contour + frame-driven ambient motes.
        // Deliberate visual change — the pinned frame is active mode at
        // frame 0, so it now carries the dithered ramp tones, halo ring,
        // and the frame-0 mote field.
        // v8 (v7 pixel-design cute pass, Tools/PIXEL_DESIGN.md): authored
        // ramp tones joined the LUT (§1), edge fringes snap clean so only
        // interior ramps dither (§2), ears + big pupils + face inset +
        // accent-tinted halo (§3-5).
        let expected: [Archetype: UInt64] = [
            .ember: 13_117_810_475_208_761_603,
            .willow: 9_754_344_364_845_908_826,
            .compass: 8_416_969_851_222_770_231,
            .prism: 6_149_455_984_412_039_409,
            .nimbus: 541_852_625_801_170_022,
        ]
        var actual: [Archetype: UInt64] = [:]
        for archetype in Archetype.allCases {
            let bytes = try makeRasterizer(archetype).snapshotBytes()
            actual[archetype] = hash(bytes)
            let pin = expected[archetype] ?? 0
            if pin != 0 {
                XCTAssertEqual(actual[archetype]!, pin, "\(archetype.rawValue) pixel frame changed")
            }
        }
        let recorded = Archetype.allCases
            .map { "\($0.rawValue) = \(actual[$0]!)" }
            .joined(separator: ", ")
        XCTAssertTrue(
            expected.values.allSatisfy { $0 != 0 },
            "RECORD MODE — pixel hashes to pin: \(recorded)"
        )
    }

    func testPixelFramesAreDeterministic() throws {
        for archetype in Archetype.allCases {
            let first = hash(try makeRasterizer(archetype).snapshotBytes())
            let second = hash(try makeRasterizer(archetype).snapshotBytes())
            XCTAssertEqual(first, second, "\(archetype.rawValue) pixel frame must be reproducible")
        }
    }

    func testPixelFramesArePairwiseDistinct() throws {
        var seen: [UInt64] = []
        for archetype in Archetype.allCases {
            let value = hash(try makeRasterizer(archetype).snapshotBytes())
            XCTAssertFalse(seen.contains(value), "\(archetype.rawValue) pixel frame collides with an earlier archetype")
            seen.append(value)
        }
    }

    /// Every non-background pixel is EXACTLY a LUT color — the snap is
    /// what makes the stage read as pixel art (no continuous shading).
    func testPixelColorsSnapToLUT() throws {
        for archetype in Archetype.allCases {
            let rasterizer = try makeRasterizer(archetype)
            let bytes = rasterizer.snapshotBytes()
            let lut = rasterizer.lutForTesting
            var lit = 0
            for i in 0..<(PixelStageRasterizer.gridWidth * PixelStageRasterizer.gridHeight) {
                let o = i * 4
                guard max(bytes[o], max(bytes[o + 1], bytes[o + 2])) > 8 else { continue }
                lit += 1
                let r = Double(bytes[o]) / 255, g = Double(bytes[o + 1]) / 255, b = Double(bytes[o + 2]) / 255
                XCTAssertTrue(
                    lut.contains { abs(Double($0.0) - r) < 0.01 && abs(Double($0.1) - g) < 0.01 && abs(Double($0.2) - b) < 0.01 },
                    "\(archetype.rawValue): pixel (\(bytes[o]),\(bytes[o + 1]),\(bytes[o + 2])) is not a LUT color"
                )
            }
            XCTAssertGreaterThan(lit, 150, "\(archetype.rawValue): pixel grid should be substantially lit")
        }
    }

    /// v4 vivid palettes (§11.2): the DOMINANT lit color of each grid must
    /// be strongly saturated — the muted-lavender washout was the v3
    /// sameness diagnosis. v6: the measurement excludes the stage tones
    /// (the halo contour + motes) — the invariant is about the BODY tint,
    /// and the halo ring is a uniform gray that would otherwise dominate
    /// the histogram by construction.
    func testPixelPalettesAreVivid() throws {
        for archetype in Archetype.allCases {
            let rasterizer = try makeRasterizer(archetype)
            let bytes = rasterizer.snapshotBytes()
            let stageKeys = Set(rasterizer.stageTonesForTesting.map {
                Int($0.0 * 255) << 16 | Int($0.1 * 255) << 8 | Int($0.2 * 255)
            })
            var counts: [Int: Int] = [:]
            for i in 0..<(PixelStageRasterizer.gridWidth * PixelStageRasterizer.gridHeight) {
                let o = i * 4
                guard max(bytes[o], max(bytes[o + 1], bytes[o + 2])) > 30 else { continue }
                let key = Int(bytes[o]) << 16 | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2])
                if stageKeys.contains(key) { continue }
                counts[key, default: 0] += 1
            }
            let dominant = counts.max { $0.value < $1.value }!.key
            let r = Double((dominant >> 16) & 0xFF) / 255
            let g = Double((dominant >> 8) & 0xFF) / 255
            let b = Double(dominant & 0xFF) / 255
            let maxC = max(r, max(g, b))
            let sat = maxC > 0 ? (maxC - min(r, min(g, b))) / maxC : 0
            XCTAssertGreaterThan(sat, 0.4, "\(archetype.rawValue): dominant body color must be vivid (saturation \(String(format: "%.2f", sat)))")
        }
    }

    /// The face-muddiness regression (A6.1 bug): antialiased blends
    /// between bright body tones and the dark face color used to snap to
    /// restDim and smear dark bands across the face. restDim must never
    /// appear in an ACTIVE frame.
    func testActivePixelFramesContainNoRestDim() throws {
        for archetype in Archetype.allCases {
            let engine = try makeGoldenEngine(archetype)
            engine.update(toFrame: 300)
            let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
            painter.paint(
                world: engine.currentWorld,
                pose: engine.currentPose,
                rest: false,
                accentPhase: engine.activeGesturePhase,
                tell: engine.tell,
                tellPhase: engine.tellPhase
            )
            let rasterizer = PixelStageRasterizer(painter: painter)
            rasterizer.rasterize(painter: painter)
            let bytes = rasterizer.snapshotBytes()
            guard let restDim = painter.roleColors[.restDim] else { continue }
            let rr = Int(restDim.0 * 255), rg = Int(restDim.1 * 255), rb = Int(restDim.2 * 255)
            var offenders = 0
            for i in 0..<(PixelStageRasterizer.gridWidth * PixelStageRasterizer.gridHeight) {
                let o = i * 4
                if bytes[o] == rr && bytes[o + 1] == rg && bytes[o + 2] == rb {
                    offenders += 1
                }
            }
            XCTAssertEqual(offenders, 0, "\(archetype.rawValue): active frames must not contain restDim pixels (the A6.1 face-mud bug)")
        }
    }

    /// Wrist-down rest (§8): the rest grid must render far dimmer than the
    /// active grid — the sleep pose carries no glow.
    func testPixelRestFrameIsDim() throws {
        for archetype in Archetype.allCases {
            let engine = try makeGoldenEngine(archetype)
            engine.update(toFrame: 300)
            let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)

            painter.paint(
                world: engine.currentWorld, pose: engine.currentPose, rest: false,
                accentPhase: engine.activeGesturePhase, tell: engine.tell, tellPhase: engine.tellPhase
            )
            let active = PixelStageRasterizer(painter: painter)
            active.rasterize(painter: painter)
            let activeBytes = active.snapshotBytes()

            painter.paint(world: engine.currentWorld, pose: engine.currentPose, rest: true)
            let rest = PixelStageRasterizer(painter: painter)
            rest.rasterize(painter: painter, rest: true)
            let restBytes = rest.snapshotBytes()

            func meanLum(_ bytes: [UInt8]) -> Double {
                var total = 0.0
                for i in 0..<(PixelStageRasterizer.gridWidth * PixelStageRasterizer.gridHeight) {
                    let o = i * 4
                    total += 0.299 * Double(bytes[o]) + 0.587 * Double(bytes[o + 1]) + 0.114 * Double(bytes[o + 2])
                }
                return total / Double(PixelStageRasterizer.gridWidth * PixelStageRasterizer.gridHeight)
            }
            XCTAssertLessThan(
                meanLum(restBytes) + 1, meanLum(activeBytes) * 0.55,
                "\(archetype.rawValue): rest grid must render dimmer than the active grid (restDim is 0.22x bodyLight; the active mean runs below full bodyLight, so the designed ratio is ~0.35-0.4 — a rest pose at active brightness fails this)"
            )
        }
    }

    // MARK: v6 hi-bit mascot polish (halo contour, motes, dither, face beats)

    /// v6 halo: the active frame carries a dithered 1-px contour in the
    /// halo tone, and every halo pixel touches a lit non-stage pixel —
    /// the ring is exactly one pixel out from the silhouette, never chained.
    func testHaloRingIsOnePixelContour() throws {
        let width = PixelStageRasterizer.gridWidth
        let height = PixelStageRasterizer.gridHeight
        for archetype in Archetype.allCases {
            let rasterizer = try makeRasterizer(archetype)
            let bytes = rasterizer.snapshotBytes()
            guard let halo = rasterizer.stageTonesForTesting.first else {
                XCTFail("\(archetype.rawValue): no halo tone in the LUT")
                continue
            }
            let hr = Int(halo.0 * 255), hg = Int(halo.1 * 255), hb = Int(halo.2 * 255)
            func isHalo(_ i: Int) -> Bool {
                let o = i * 4
                return bytes[o] == UInt8(hr) && bytes[o + 1] == UInt8(hg) && bytes[o + 2] == UInt8(hb)
            }
            func litBody(_ i: Int) -> Bool {
                let o = i * 4
                guard max(bytes[o], max(bytes[o + 1], bytes[o + 2])) > 24 else { return false }
                return !isHalo(i)
            }
            var haloCount = 0
            for i in 0..<(width * height) where isHalo(i) {
                haloCount += 1
                let x = i % width, y = i / width
                let touchesBody = (x > 0 && litBody(i - 1)) || (x < width - 1 && litBody(i + 1))
                    || (y > 0 && litBody(i - width)) || (y < height - 1 && litBody(i + width))
                XCTAssertTrue(touchesBody, "\(archetype.rawValue): halo pixel \(i) floats off the silhouette")
            }
            XCTAssertGreaterThan(haloCount, 20, "\(archetype.rawValue): the halo contour should ring the silhouette")
        }
    }

    /// v6 motes: a deterministic function of the frame index (same frame ->
    /// same field, different frame -> moved), present in active frames and
    /// completely absent from the rest LOD (the sleep stage stays dark).
    func testMotesAreDeterministicFrameDrivenAndRestFree() throws {
        for archetype in Archetype.allCases {
            let engine = try makeGoldenEngine(archetype)
            engine.update(toFrame: 300)
            let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
            painter.paint(
                world: engine.currentWorld, pose: engine.currentPose, rest: false,
                accentPhase: engine.activeGesturePhase, tell: engine.tell, tellPhase: engine.tellPhase
            )
            let a = PixelStageRasterizer(painter: painter)
            a.rasterize(painter: painter, frame: 40)
            let frame40 = a.snapshotBytes()
            let b = PixelStageRasterizer(painter: painter)
            b.rasterize(painter: painter, frame: 40)
            XCTAssertEqual(frame40, b.snapshotBytes(), "\(archetype.rawValue): same frame must give the same mote field")
            let c = PixelStageRasterizer(painter: painter)
            c.rasterize(painter: painter, frame: 140)
            XCTAssertNotEqual(frame40, c.snapshotBytes(), "\(archetype.rawValue): motes must drift with the frame index")

            guard let mote = painter.roleColors[.mote] else { continue }
            let mr = Int(mote.0 * 255), mg = Int(mote.1 * 255), mb = Int(mote.2 * 255)
            func moteCount(_ bytes: [UInt8]) -> Int {
                var n = 0
                for i in 0..<(PixelStageRasterizer.gridWidth * PixelStageRasterizer.gridHeight) {
                    let o = i * 4
                    if bytes[o] == UInt8(mr) && bytes[o + 1] == UInt8(mg) && bytes[o + 2] == UInt8(mb) { n += 1 }
                }
                return n
            }
            var activeMotes = 0
            for frame in 0..<60 {
                let r = PixelStageRasterizer(painter: painter)
                r.rasterize(painter: painter, frame: frame)
                activeMotes += moteCount(r.snapshotBytes())
            }
            XCTAssertGreaterThan(activeMotes, 0, "\(archetype.rawValue): active frames should carry twinkling motes")

            painter.paint(world: engine.currentWorld, pose: engine.currentPose, rest: true)
            let rest = PixelStageRasterizer(painter: painter)
            rest.rasterize(painter: painter, rest: true, frame: 40)
            XCTAssertEqual(moteCount(rest.snapshotBytes()), 0, "\(archetype.rawValue): the rest LOD carries no motes")
        }
    }

    /// v6 face beat: joy/warm blooms the blush cheeks (a command in the
    /// blush tone with alpha > 0); a neutral face emits none, so
    /// event-free golden frames stay byte-identical.
    func testBlushCheeksFollowExpressionWeights() throws {
        for archetype in Archetype.allCases {
            let engine = try makeGoldenEngine(archetype)
            engine.update(toFrame: 300)
            let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
            func hasBlushCommand() -> Bool {
                guard let blush = painter.roleColors[.blush] else { return false }
                for i in 0..<painter.commandCount {
                    let c = painter.commands[i]
                    if c.a > 0.05 && abs(c.r - blush.0) < 0.01 && abs(c.g - blush.1) < 0.01 && abs(c.b - blush.2) < 0.01 {
                        return true
                    }
                }
                return false
            }
            var pose = engine.currentPose
            for i in 0..<pose.expressionWeights.count { pose.expressionWeights[i] = 0 }
            painter.paint(world: engine.currentWorld, pose: pose, rest: false)
            XCTAssertEqual(painter.lastBlushAlphaForTesting, 0, "\(archetype.rawValue): neutral face paints no blush")
            XCTAssertFalse(hasBlushCommand(), "\(archetype.rawValue): neutral frame has no blush command")

            pose.expressionWeights[ExpressionChannel.joy.rawValue] = 1
            painter.paint(world: engine.currentWorld, pose: pose, rest: false)
            XCTAssertGreaterThan(painter.lastBlushAlphaForTesting, 0.3, "\(archetype.rawValue): joy must bloom the blush")
            XCTAssertTrue(hasBlushCommand(), "\(archetype.rawValue): joy frame must emit the blush commands")
        }
    }
}

// MARK: - v6 touch-gaze + happy squint (engine-level)

/// The v6 interaction beats: a `.gazeAt` touch event darts the pupils and
/// head toward the finger on a fast attack, then decays back to exactly
/// zero — so an event-free reference engine re-converges bit-exactly (the
/// CI determinism contract survives interaction). And joy closes the lids
/// (the ^-^ happy squint) instead of opening them.
final class V6InteractionTests: XCTestCase {
    func testGazeAtDartsPupilsTowardTouchThenReConverges() throws {
        let engine = try makeGoldenEngine(.ember)
        let reference = try makeGoldenEngine(.ember)
        engine.update(toFrame: 200)
        reference.update(toFrame: 200)
        let bones = BoneMap(skeleton: engine.skeleton)
        let before = engine.currentPose.offsetsX[bones.pupilL]

        engine.handleEvent(.gazeAt(x: 1, y: 0))
        engine.update(toFrame: 201)
        let after = engine.currentPose.offsetsX[bones.pupilL]
        XCTAssertGreaterThan(after, before + 1.0, "pupils must dart toward a +x touch")
        XCTAssertGreaterThan(engine.gazePokeLevelForTesting, 0.9, "fast attack on touch")

        // After the poke decays to exactly 0, the pose must re-converge
        // bit-exactly with the event-free reference (CI determinism).
        engine.update(toFrame: 1000)
        reference.update(toFrame: 1000)
        XCTAssertEqual(engine.gazePokeLevelForTesting, 0, "poke must decay to exactly zero")
        XCTAssertEqual(engine.currentPose, reference.currentPose, "a decayed poke must leave no residue")
    }

    func testGazeAtIsClampedAndNeverStartsAClip() throws {
        let engine = try makeGoldenEngine(.willow)
        engine.update(toFrame: 100)
        engine.handleEvent(.gazeAt(x: 99, y: -99))
        engine.update(toFrame: 101)
        XCTAssertNil(engine.currentReactionClip, "gazeAt is not a reaction clip")
        XCTAssertGreaterThan(engine.currentPose.offsetsX[BoneMap(skeleton: engine.skeleton).pupilR], 0)
    }

    func testJoySquintsLidsClosed() throws {
        let engine = try makeGoldenEngine(.nimbus)
        let bones = BoneMap(skeleton: engine.skeleton)
        var expressions = [Float](repeating: 0, count: ExpressionChannel.count)
        var pose = AvatarPose(boneCount: engine.skeleton.boneCount)
        ExpressionMixer.apply(expressions: expressions, bones: bones, pose: &pose)
        let neutralLid = pose.offsetsY[bones.lidL]

        expressions[ExpressionChannel.joy.rawValue] = 1
        ExpressionMixer.apply(expressions: expressions, bones: bones, pose: &pose)
        XCTAssertGreaterThan(pose.offsetsY[bones.lidL], neutralLid + 2.5, "joy must close the lids (happy ^-^ squint)")

        var expressions2 = [Float](repeating: 0, count: ExpressionChannel.count)
        expressions2[ExpressionChannel.surprise.rawValue] = 1
        var pose2 = AvatarPose(boneCount: engine.skeleton.boneCount)
        ExpressionMixer.apply(expressions: expressions2, bones: bones, pose: &pose2)
        XCTAssertLessThan(pose2.offsetsY[bones.lidL], pose.offsetsY[bones.lidL], "surprise keeps the eyes wide where joy squints them shut")
        XCTAssertEqual(pose2.offsetsY[bones.lidL], 0, "surprise opens the lids fully (clamped at 0)")
    }
}

// MARK: - v5b quirk clips (one per archetype — the "act the same" fix)

/// Each archetype owns exactly one quirk clip no other archetype performs:
/// Ember preens, Willow catches a leaf, Compass ticks, Prism mirror-flips,
/// Nimbus float-wanders. The clips' motion signatures must be pairwise
/// distinct — five behaviors, not five parameterizations of one bob.
final class QuirkClipTests: XCTestCase {
    private let owners: [GestureClip: Archetype] = [
        .preen: .ember,
        .swayCatch: .willow,
        .tick: .compass,
        .mirror: .prism,
        .driftFloat: .nimbus,
    ]

    func testQuirkClipsAreOwnerExclusive() throws {
        for (clip, owner) in owners {
            for archetype in Archetype.allCases {
                let profile = try PersonalityProfile.load(archetype)
                let weight = profile.gesturePoolWeights["\(clip)"] ?? 0
                if archetype == owner {
                    XCTAssertGreaterThan(
                        weight, 0,
                        "\(clip.rawValue) must be in \(archetype.rawValue)'s pool"
                    )
                } else {
                    XCTAssertEqual(
                        weight, 0,
                        "\(clip.rawValue) belongs to \(owner.rawValue) only — \(archetype.rawValue) must not perform it"
                    )
                }
            }
        }
    }

    func testQuirkClipsHaveDistinctMotionSignatures() throws {
        // Sampled at multiple phases (a clip's mid-point can be a zero
        // crossing — swayCatch's sway passes through neutral at u = 0.5).
        let engine = try makeGoldenEngine(.nimbus)
        var signatures: [GestureClip: [Float]] = [:]
        for clip in owners.keys {
            var signature: [Float] = []
            for u: Float in [0.1, 0.25, 0.5, 0.75, 0.9] {
                var pose = AvatarPose(boneCount: engine.skeleton.boneCount)
                var expressions = [Float](repeating: 0, count: ExpressionChannel.count)
                GestureClipLibrary.apply(
                    clip, u: u, anticipation: 0, weight: 1,
                    profile: engine.profile, bones: engine.bones,
                    pose: &pose, expressions: &expressions
                )
                let b = engine.bones
                signature.append(contentsOf: [
                    pose.rotations[b.head],
                    pose.rotations[b.spineUpper],
                    pose.offsetsY[b.hips],
                    pose.offsetsX[b.hips],
                    pose.scalesY[b.head] - 1,
                    pose.scalesX[b.chest] - 1,
                ])
            }
            signatures[clip] = signature
        }
        let clips = Array(owners.keys)
        for i in 0..<clips.count {
            for j in (i + 1)..<clips.count {
                let a = signatures[clips[i]]!
                let c = signatures[clips[j]]!
                var d: Float = 0
                for k in 0..<a.count {
                    let diff = a[k] - c[k]
                    d += diff * diff
                }
                XCTAssertGreaterThan(
                    d, 0.001,
                    "\(clips[i].rawValue) and \(clips[j].rawValue) must have distinct motion signatures (squared distance \(d))"
                )
            }
        }
    }

    func testTickSettlesExactlyToNeutral() throws {
        // Compass's tell is ONE exact metronome bob: zero overshoot, and
        // the pose returns to exactly neutral by u = 1 — one pixel of
        // imprecision destroys it (§1 Compass).
        let engine = try makeGoldenEngine(.compass)
        var pose = AvatarPose(boneCount: engine.skeleton.boneCount)
        var expressions = [Float](repeating: 0, count: ExpressionChannel.count)
        GestureClipLibrary.apply(
            .tick, u: 1, anticipation: 0, weight: 1,
            profile: engine.profile, bones: engine.bones,
            pose: &pose, expressions: &expressions
        )
        XCTAssertEqual(
            pose, AvatarPose(boneCount: engine.skeleton.boneCount),
            "tick must settle exactly to neutral at u = 1"
        )
    }
}

// MARK: - A5c bonding mechanics (slow-blink ritual, farewell beat)

final class RitualTests: XCTestCase {
    private func applyRitual(
        _ clip: GestureClip, u: Float, engine: AvatarEngine,
        pose: inout AvatarPose, expressions: inout [Float]
    ) {
        GestureClipLibrary.apply(
            clip, u: u, anticipation: 0, weight: 1,
            profile: engine.profile, bones: engine.bones,
            pose: &pose, expressions: &expressions
        )
    }

    /// U8 — the slow-blink exchange: mutual gaze hold, a blink you can
    /// watch happen (lids fully closed mid-ritual, using the same 5.5-unit
    /// lid travel as the life-loop blink), open again by the end.
    func testSlowBlinkRitualEnvelope() throws {
        let engine = try makeGoldenEngine(.willow)
        let b = engine.bones
        // Open at the start of the gaze hold.
        do {
            var pose = AvatarPose(boneCount: engine.skeleton.boneCount)
            var expressions = [Float](repeating: 0, count: ExpressionChannel.count)
            applyRitual(.slowBlink, u: 0.05, engine: engine, pose: &pose, expressions: &expressions)
            XCTAssertLessThan(pose.offsetsY[b.lidL], 0.5, "lids open during the gaze hold")
        }
        // Fully closed mid-ritual (u = 0.5 is inside the 0.45-0.6 hold).
        do {
            var pose = AvatarPose(boneCount: engine.skeleton.boneCount)
            var expressions = [Float](repeating: 0, count: ExpressionChannel.count)
            applyRitual(.slowBlink, u: 0.5, engine: engine, pose: &pose, expressions: &expressions)
            XCTAssertGreaterThan(pose.offsetsY[b.lidL], 4.5, "lids fully closed mid-ritual")
            XCTAssertGreaterThan(pose.offsetsY[b.lidR], 4.5, "both lids close together")
        }
        // Open again by the end.
        do {
            var pose = AvatarPose(boneCount: engine.skeleton.boneCount)
            var expressions = [Float](repeating: 0, count: ExpressionChannel.count)
            applyRitual(.slowBlink, u: 0.95, engine: engine, pose: &pose, expressions: &expressions)
            XCTAssertLessThan(pose.offsetsY[b.lidL], 0.5, "lids reopen before the ritual ends")
        }
        // Mutual gaze: accumulated pupil wander is pulled toward neutral.
        do {
            var pose = AvatarPose(boneCount: engine.skeleton.boneCount)
            var expressions = [Float](repeating: 0, count: ExpressionChannel.count)
            pose.offsetsX[b.pupilL] = 3
            pose.offsetsX[b.pupilR] = 3
            applyRitual(.slowBlink, u: 0.3, engine: engine, pose: &pose, expressions: &expressions)
            XCTAssertLessThan(pose.offsetsX[b.pupilL], 2.0, "the ritual pulls the gaze back to the user")
        }
    }

    /// The ritual is EVENT-ONLY (long-press): weight 0 in every pool — it
    /// must never surface from the idle schedule, or it stops being a
    /// ritual and becomes a tic.
    func testSlowBlinkIsNeverIdleScheduled() throws {
        for archetype in Archetype.allCases {
            let profile = try PersonalityProfile.load(archetype)
            XCTAssertEqual(profile.gesturePoolWeights["slowBlink"] ?? 0, 0,
                           "\(archetype.rawValue): slowBlink is event-only (weight must be 0)")
        }
    }

    /// Willow owns the softest version (§10.5.2): tempo-scaled duration —
    /// Willow's ritual (0.8x tempo) outlasts Ember's (1.2x).
    func testWillowRitualIsTheSoftest() throws {
        let willow = try PersonalityProfile.load(.willow)
        let ember = try PersonalityProfile.load(.ember)
        let willowFrames = GestureClipLibrary.durationFrames(.slowBlink, profile: willow)
        let emberFrames = GestureClipLibrary.durationFrames(.slowBlink, profile: ember)
        XCTAssertGreaterThan(
            willowFrames, emberFrames,
            "Willow's slow blink must outlast Ember's (tempo-scaled softness)"
        )
    }

    /// U9 — the farewell beat: every archetype's wrist-drop goodbye is a
    /// SOLO small clip (no anticipation wind-up, no squash-and-stretch) —
    /// never a guilt gesture and never a big finish.
    func testFarewellGestureIsSoftForEveryArchetype() throws {
        for archetype in Archetype.allCases {
            let clip = archetype.farewellGesture
            XCTAssertFalse(
                clip.isBig,
                "\(archetype.rawValue): the farewell must be a small clip (got \(clip.rawValue))"
            )
        }
    }
}

// MARK: - A5d interiority (unobserved behavior with persistence)

/// §1: what the character does when nobody is watching — and the traces
/// it leaves. The memory is a pure function of (previous state, now);
/// the painter artifacts are neutral by default so pinned renders never
/// drift.
final class InteriorityTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "interiority-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return Calendar.current.date(from: components)!
    }

    private func store() -> CompanionMemoryStore {
        CompanionMemoryStore(defaults: defaults)
    }

    /// First visit: streak starts at 1, sprout just sprouted, nothing to
    /// present — the interiority pass never fabricates absence.
    func testFirstVisitBaseline() throws {
        let summary = store().recordVisit(now: date(2026, 10, 10))
        XCTAssertEqual(summary.absenceDays, 0)
        XCTAssertEqual(summary.streakDays, 1)
        XCTAssertFalse(summary.trinketPresent)
        XCTAssertLessThan(summary.sproutGrowth, 0.35, "a fresh sprout is small")
    }

    /// Streak (Compass): yesterday extends it, a gap resets it to day 1 —
    /// the reset is an invitation, never an accusation.
    func testStreakExtendsThenResets() throws {
        let s = store()
        _ = s.recordVisit(now: date(2026, 10, 8))
        let second = s.recordVisit(now: date(2026, 10, 9))
        XCTAssertEqual(second.streakDays, 2, "a visit yesterday extends the streak")
        let third = s.recordVisit(now: date(2026, 10, 15))
        XCTAssertEqual(third.streakDays, 1, "a gap resets the streak to day 1")
        XCTAssertEqual(third.absenceDays, 6)
    }

    /// Sprout (Willow): it kept watering while you were away — growth
    /// accumulates with attended days (absence included), toward maturity.
    func testSproutGrowsWithAbsence() throws {
        let s = store()
        let first = s.recordVisit(now: date(2026, 10, 1))
        let afterThreeWeeks = s.recordVisit(now: date(2026, 10, 22))
        XCTAssertGreaterThan(afterThreeWeeks.sproutGrowth, first.sproutGrowth,
                            "the sprout grew while nobody was watching")
        XCTAssertGreaterThanOrEqual(afterThreeWeeks.sproutGrowth, 0.95,
                                    "three attended weeks reach maturity")
    }

    /// Rehearsal (Ember): the practiced dance improves with sessions,
    /// capped at 5 — a practiced performer, never a maniac.
    func testRehearsalLevelGrowsAndCaps() throws {
        let s = store()
        var last = s.recordVisit(now: date(2026, 10, 1))
        for day in 2...60 {
            last = s.recordVisit(now: date(2026, 10, 1).addingTimeInterval(Double(day) * 86_400))
        }
        XCTAssertEqual(last.rehearsalLevel, 5, "60 sessions cap the rehearsal at level 5")
    }

    /// Trinket (Prism): a fresh find per day of absence; a same-day
    /// re-open never invents a second one.
    func testTrinketFoundAfterAbsenceOnly() throws {
        let s = store()
        _ = s.recordVisit(now: date(2026, 10, 8))
        let nextDay = s.recordVisit(now: date(2026, 10, 9))
        XCTAssertTrue(nextDay.trinketPresent, "it found something while you were out")
        let sameDayAgain = s.recordVisit(now: date(2026, 10, 9, hour: 20))
        XCTAssertFalse(sameDayAgain.trinketPresent, "the same day twice is never the same event — but the trinket is already presented")
    }

    /// Barometer (Nimbus): it learns the rhythm of your returns and
    /// recognizes your usual time — anticipation without being told.
    func testBarometerLearnsUsualHour() throws {
        let s = store()
        // A routine: three visits around 08:00.
        _ = s.recordVisit(now: date(2026, 10, 6, hour: 8))
        _ = s.recordVisit(now: date(2026, 10, 7, hour: 8, minute: 10))
        _ = s.recordVisit(now: date(2026, 10, 8, hour: 7, minute: 50))
        let usual = s.recordVisit(now: date(2026, 10, 9, hour: 8))
        XCTAssertTrue(usual.nearUsualHour, "8:00 is the learned usual time")
        let odd = s.recordVisit(now: date(2026, 10, 10, hour: 15))
        XCTAssertFalse(odd.nearUsualHour, "3 PM is not your usual time (yet)")
    }

    /// Painter artifacts: the week grid and the trinket are ADDITIVE —
    /// neutral by default, present when the memory says so.
    func testPainterArtifactsAreNeutralByDefault() throws {
        let engine = try makeGoldenEngine(.compass)
        let plain = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
        let audited = AvatarSpritePainter(
            skeleton: engine.skeleton, visualSet: engine.visualSet,
            interiority: InteriorityTuning(sproutGrowth: 1, streakDays: 7, trinketPresent: false)
        )
        XCTAssertEqual(audited.shapes.count - plain.shapes.count, 7,
                       "a 7-day streak draws the full week grid")

        let prismEngine = try makeGoldenEngine(.prism)
        let plainPrism = AvatarSpritePainter(skeleton: prismEngine.skeleton, visualSet: prismEngine.visualSet)
        let withTrinket = AvatarSpritePainter(
            skeleton: prismEngine.skeleton, visualSet: prismEngine.visualSet,
            interiority: InteriorityTuning(sproutGrowth: 1, streakDays: 0, trinketPresent: true)
        )
        XCTAssertEqual(withTrinket.shapes.count - plainPrism.shapes.count, 1,
                       "the found trinket adds exactly one diamond")
    }

    /// Willow's sprout growth scales the leaf — small at 0.2, the pinned
    /// default at 1.0.
    func testSproutGrowthScalesTheLeaf() throws {
        let engine = try makeGoldenEngine(.willow)
        func sproutHeight(_ growth: Float) -> Float {
            let painter = AvatarSpritePainter(
                skeleton: engine.skeleton, visualSet: engine.visualSet,
                interiority: InteriorityTuning(sproutGrowth: growth, streakDays: 0, trinketPresent: false)
            )
            let index = try! XCTUnwrap(painter.sproutLeafShapeIndex)
            return painter.shapes[index].height
        }
        let small = sproutHeight(0.2)
        let mature = sproutHeight(1.0)
        XCTAssertEqual(mature, 7.0, accuracy: 0.001, "growth 1.0 = the pinned sprout size")
        XCTAssertLessThan(small, mature * 0.7, "a fresh sprout is visibly smaller")
    }
}

// MARK: - v7 pixel design practices (Tools/PIXEL_DESIGN.md)

/// The v7 best-practice invariants: authored ramp tones in the LUT, big
/// cute eyes, face spacing tuned per head width, and the two-ear
/// creature cue on every species.
final class V7PixelDesignTests: XCTestCase {
    /// §1: the rasterizer LUT must contain the authored gradient ramp
    /// stops (lifted top + deepened bottom per painted role) — otherwise
    /// gradient pixels snap to whatever palette color is nearest and the
    /// body reads as noise.
    func testLUTContainsAuthoredRampTones() throws {
        for archetype in Archetype.allCases {
            let engine = try makeGoldenEngine(archetype)
            let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
            let ramps = painter.rampTonesForRasterizer
            XCTAssertGreaterThanOrEqual(ramps.count, 8, "\(archetype.rawValue): expected ramp stops from the painted roles")
            let rasterizer = PixelStageRasterizer(painter: painter)
            for tone in ramps {
                let found = rasterizer.lutForTesting.contains {
                    abs($0.0 - tone.0) < 0.01 && abs($0.1 - tone.1) < 0.01 && abs($0.2 - tone.2) < 0.01
                }
                XCTAssertTrue(found, "\(archetype.rawValue): ramp tone missing from the LUT")
            }
        }
    }

    /// §3: big eyes on every species — the pupil slot scale floor.
    func testPupilsScaleUpForCuteness() {
        for archetype in Archetype.allCases {
            let scale = AvatarSpritePainter.speciesSlotScale(archetype: archetype, slotName: "pupilL")
            XCTAssertEqual(scale?.w ?? 0, 1.4, accuracy: 0.001, "\(archetype.rawValue): pupil width scale")
            XCTAssertEqual(scale?.h ?? 0, 1.45, accuracy: 0.001, "\(archetype.rawValue): pupil height scale")
            let mirror = AvatarSpritePainter.speciesSlotScale(archetype: archetype, slotName: "pupilR")
            XCTAssertEqual(scale?.w ?? 0, mirror?.w ?? 0, accuracy: 0.001, "pupils must stay symmetric")
            XCTAssertEqual(scale?.h ?? 0, mirror?.h ?? 0, accuracy: 0.001, "pupils must stay symmetric")
        }
    }

    /// §3: eye spacing follows head width — the catchlight span (the two
    /// white eye dots) must be widest on Willow's wide dome and narrowest
    /// on Ember's whip head.
    func testFaceInsetFollowsHeadWidth() throws {
        func eyeSpan(_ archetype: Archetype) throws -> Float {
            let engine = try makeGoldenEngine(archetype)
            engine.update(toFrame: 300)
            let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
            painter.paint(
                world: engine.currentWorld, pose: engine.currentPose, rest: false,
                accentPhase: engine.activeGesturePhase, tell: engine.tell, tellPhase: engine.tellPhase
            )
            var xs: [Float] = []
            for i in 0..<painter.commandCount {
                let c = painter.commands[i]
                if c.r > 0.98 && c.g > 0.98 && c.b > 0.98 && c.a > 0.9 { xs.append(c.tx) }
            }
            XCTAssertEqual(xs.count, 2, "\(archetype.rawValue): expected exactly two catchlights")
            return abs(xs[1] - xs[0])
        }
        let ember = try eyeSpan(.ember)
        let willow = try eyeSpan(.willow)
        XCTAssertLessThan(ember, 22, "Ember's narrow flame head pulls the eyes in")
        XCTAssertGreaterThan(willow, 38, "Willow's wide dome spreads the eyes out")
        XCTAssertLessThan(ember, willow, "eye span must track head width")
    }

    /// §4: the creature cue — every species carries a two-ear cluster.
    func testSpeciesCarryEars() throws {
        for archetype in Archetype.allCases {
            let engine = try makeGoldenEngine(archetype)
            let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
            XCTAssertEqual(painter.earCountForTesting, 2, "\(archetype.rawValue): every species carries two ears")
        }
    }
}
