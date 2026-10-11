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
        engine.update(toFrame: 60) // past the reaction end + cooldown
        engine.handleEvent(.tap)
        engine.update(toFrame: 65)
        XCTAssertEqual(engine.reactionCountForTesting, 2, "a tap after the cooldown reacts")
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
                // Jump past the clip end + cooldown (15) + margin.
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
        engine.update(toFrame: frame + 3)
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
    static func render(archetype: Archetype, seed: UInt64 = 42, frame: Int = 300) throws -> RasterBytes {
        let engine = try makeGoldenEngine(archetype, seed: seed)
        engine.update(toFrame: frame)
        let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
        painter.paint(
            world: engine.currentWorld,
            pose: engine.currentPose,
            rest: false,
            accentPhase: engine.activeGesturePhase
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
            ctx.setFillColor(CGColor(
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                components: [CGFloat(command.r), CGFloat(command.g), CGFloat(command.b), CGFloat(command.a)]
            )!)
            ctx.addPath(painter.shapes[command.shapeIndex].paths[command.pathIndex])
            ctx.fillPath()
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
        let expected: [Archetype: UInt64] = [
            .ember: 12_016_137_667_541_340_369,
            .willow: 18_097_399_317_908_289_734,
            .compass: 13_126_774_808_885_116_185,
            .prism: 9_954_699_415_628_735_132,
            .nimbus: 5_352_135_130_477_461_359,
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
/// silhouette gate): binarizes the golden rasters (lit pixels = silhouette,
/// palette-free) and measures pairwise IoU. High overlap means two
/// archetypes read as the same shape at a glance — the §12 "personalities
/// don't separate" risk, quantified. The n>=12 human study remains the
/// acceptance authority; this test guards regressions between studies.
final class SilhouetteSeparationTests: XCTestCase {
    /// Pairwise IoU ceilings: measured + 0.02 margin, so any silhouette
    /// regression fails CI and any deliberate improvement requires (and
    /// gets) a fresh measurement. Empty table = RECORD MODE (prints the
    /// measured matrix).
    ///
    /// Measured v1 (frame 300, seed 42, after Willow's §5 leaf accents):
    /// ember-willow 0.939, ember-compass 0.823, ember-prism 0.957,
    /// ember-nimbus 0.818, willow-compass 0.821, willow-prism 0.939,
    /// willow-nimbus 0.815, compass-prism 0.816, compass-nimbus 0.792,
    /// prism-nimbus 0.834.
    ///
    /// FINDING: the round trio (ember/willow/prism) overlaps at ~0.94-0.96
    /// because §5 assigns all three a circle head; compass (square) and
    /// nimbus (cloud) separate from everything. The ember/prism overlap is
    /// inherent to the plan's §5 shape tokens, so the §11 "identify pairs
    /// from silhouette alone" bar is at risk for that pair — flagged, with
    /// a minimal amendment proposed (a faceted head for Prism), NOT applied.
    /// The n>=12 human study remains the acceptance authority.
    private static let ceilings: [String: Double] = [
        "ember-willow": 0.959,
        "ember-compass": 0.843,
        "ember-prism": 0.977,
        "ember-nimbus": 0.838,
        "willow-compass": 0.841,
        "willow-prism": 0.959,
        "willow-nimbus": 0.835,
        "compass-prism": 0.836,
        "compass-nimbus": 0.812,
        "prism-nimbus": 0.854,
    ]

    func testPairwiseSilhouetteSeparation() throws {
        var masks: [Archetype: [Bool]] = [:]
        var litCounts: [Archetype: Int] = [:]
        for archetype in Archetype.allCases {
            let raster = try GoldenFrameRasterizer.render(archetype: archetype)
            let mask = raster.silhouetteMask()
            masks[archetype] = mask
            litCounts[archetype] = mask.filter { $0 }.count
        }

        let sorted = Archetype.allCases
        var overlaps: [(Archetype, Archetype, Double)] = []
        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                let a = sorted[i], b = sorted[j]
                let overlap = RasterBytes.iou(masks[a]!, masks[b]!)
                overlaps.append((a, b, overlap))
                if let ceiling = Self.ceilings["\(a.rawValue)-\(b.rawValue)"] {
                    XCTAssertLessThanOrEqual(
                        overlap, ceiling,
                        "\(a.rawValue)/\(b.rawValue) silhouettes regressed (IoU \(overlap) > ceiling \(ceiling)) — §11 separation risk"
                    )
                }
            }
        }

        let lit = sorted.map { "\($0.rawValue)=\(litCounts[$0]!)" }.joined(separator: " ")
        let matrix = overlaps
            .map { String(format: "%@-%@=%.3f", $0.0.rawValue, $0.1.rawValue, $0.2) }
            .joined(separator: ", ")
        if Self.ceilings.isEmpty {
            XCTFail("RECORD MODE — lit: \(lit); \(matrix)")
        }
    }
}
