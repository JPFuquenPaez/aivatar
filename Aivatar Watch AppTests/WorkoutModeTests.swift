import XCTest
@testable import Aivatar_Watch_App

/// v21 F6 "workout companion mode" suite: the bridge's pure cores (pace
/// bands, split detection, force-quit recovery), and the director's run
/// grammar (cadence from pace band, one focal story, split cheers with the
/// 45 s cap, L2 flattening, determinism).
final class WorkoutModeTests: XCTestCase {

    private func director(_ archetype: Archetype, seed: UInt64 = 20261110) throws -> SpriteDirector {
        SpriteDirector(profile: try PersonalityProfile.load(archetype), seed: seed)
    }

    // MARK: - Bridge pure cores

    func testPaceBands() {
        XCTAssertEqual(WorkoutCompanionBridge.paceBand(metersPerSec: 1.0), 0)
        XCTAssertEqual(WorkoutCompanionBridge.paceBand(metersPerSec: 2.0), 1)
        XCTAssertEqual(WorkoutCompanionBridge.paceBand(metersPerSec: 3.0), 2)
        XCTAssertEqual(WorkoutCompanionBridge.paceBand(metersPerSec: 4.0), 3)
        XCTAssertEqual(WorkoutCompanionBridge.paceBand(metersPerSec: 5.5), 4)
        XCTAssertEqual(WorkoutCompanionBridge.paceBand(metersPerSec: 7.0), 5)
        XCTAssertEqual(WorkoutCompanionBridge.paceBand(metersPerSec: 0), 0)
    }

    func testSplitDetection() {
        XCTAssertNil(WorkoutCompanionBridge.nextSplitKm(after: 0, distanceMeters: 999))
        XCTAssertEqual(WorkoutCompanionBridge.nextSplitKm(after: 0, distanceMeters: 1_000), 1)
        XCTAssertEqual(WorkoutCompanionBridge.nextSplitKm(after: 0, distanceMeters: 2_600), 2)
        XCTAssertNil(WorkoutCompanionBridge.nextSplitKm(after: 2, distanceMeters: 2_600))
        XCTAssertEqual(WorkoutCompanionBridge.nextSplitKm(after: 2, distanceMeters: 3_001), 3)
    }

    func testForceQuitRecoveryDecisions() {
        let now = Date(timeIntervalSince1970: 1_793_620_800)
        XCTAssertEqual(WorkoutCompanionBridge.recovery(saved: nil, now: now), .none)
        let short = WorkoutCompanionBridge.InProgress(
            activityRaw: 37, startedAt: now.addingTimeInterval(-30), lastDistanceMeters: 100, lastSync: now)
        XCTAssertEqual(WorkoutCompanionBridge.recovery(saved: short, now: now), .discard,
                       "under 60 s is never a workout")
        let real = WorkoutCompanionBridge.InProgress(
            activityRaw: 37, startedAt: now.addingTimeInterval(-1_800), lastDistanceMeters: 5_200, lastSync: now)
        XCTAssertEqual(WorkoutCompanionBridge.recovery(saved: real, now: now),
                       .finishPartial(durationSec: 1_800, distanceMeters: 5_200))
    }

    // MARK: - Director run grammar

    func testWorkoutModeRunsAlternatingCycleAtPaceCadence() throws {
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            d.setWorkoutMode(true, paceBand: 4)
            XCTAssertTrue(d.workoutMode)
            var seq: [String] = []
            for _ in 0..<40 { d.advance(toTick: d.tick + 1); seq.append(d.currentFrame) }
            let acts = Set(seq.filter { $0 == "idleA" || $0 == "idleB" })
            XCTAssertEqual(acts, ["idleA", "idleB"], "\(archetype.rawValue): the run cycle alternates")
            XCTAssertFalse(seq.contains("quirk") || seq.contains("glanceL") || seq.contains("glanceR"),
                           "\(archetype.rawValue): one focal story — no random quirks/glances during a run")
            XCTAssertNil(d.moteCell, "no motes during a run")
        }
    }

    func testRunCadenceFollowsPaceBand() throws {
        XCTAssertEqual(SpriteDirector.runCycleTicks(0), 5)
        XCTAssertEqual(SpriteDirector.runCycleTicks(2), 3)
        XCTAssertEqual(SpriteDirector.runCycleTicks(5), 2)
        XCTAssertEqual(SpriteDirector.runCycleTicks(99), 2, "clamped")
        // Faster pace -> faster alternation (measured over 60 ticks).
        func alternations(_ band: Int) throws -> Int {
            let d = try director(.ember)
            d.setWorkoutMode(true, paceBand: band)
            var seq: [String] = []
            for _ in 0..<60 { d.advance(toTick: d.tick + 1); seq.append(d.currentFrame) }
            var switches = 0
            for i in 1..<seq.count where seq[i] != seq[i - 1] { switches += 1 }
            return switches
        }
        XCTAssertGreaterThan(try alternations(5), try alternations(0), "sprint cadence beats walk cadence")
    }

    func testSplitCheerPlaysAndIsRateCapped() throws {
        let d = try director(.ember)
        d.setWorkoutMode(true)
        d.handleLifeEvent(.split(distanceKm: 1))
        XCTAssertEqual(d.splitCount, 1)
        XCTAssertEqual(d.lifeEventCount, 1)
        // Same kind inside 45 s is swallowed (split channel, no wake gate).
        d.handleLifeEvent(.split(distanceKm: 2))
        XCTAssertEqual(d.splitCount, 1, "split channel caps at 1/45 s even mid-run")
        d.advance(toTick: d.tick + SpriteDirector.splitCooldownTicks + 1)
        d.handleLifeEvent(.split(distanceKm: 2))
        XCTAssertEqual(d.splitCount, 2, "after 45 s the next split cheers again")
        // The one-per-wake gate does NOT block workout events.
        XCTAssertEqual(d.lifeEventCount, 2)
    }

    func testSplitCheerActPerArchetype() {
        for archetype in Archetype.allCases {
            XCTAssertNotNil(SpriteDirector.splitCheer(distanceKm: 1, archetype: archetype))
            XCTAssertNotNil(SpriteDirector.reactionAct(for: .split(distanceKm: 1), archetype: archetype))
        }
        XCTAssertNil(SpriteDirector.reactionAct(for: .workoutLive(paceBand: 3), archetype: .ember),
                     "pace bands steer, they don't act")
    }

    func testWorkoutLiveSetsPaceBand() throws {
        let d = try director(.willow)
        d.setWorkoutMode(true)
        d.handleLifeEvent(.workoutLive(paceBand: 5))
        XCTAssertEqual(d.workoutPaceBand, 5)
        d.handleLifeEvent(.workoutLive(paceBand: 99))
        XCTAssertEqual(d.workoutPaceBand, 5, "clamped")
    }

    func testWorkoutModeFlattensUnderL2() throws {
        let d = try director(.compass)
        d.accessibilityMode = .reduceMotionL2
        d.setWorkoutMode(true)
        d.handleLifeEvent(.split(distanceKm: 1))  // split still counts, face-only
        XCTAssertEqual(d.splitCount, 1)
        var seq: [String] = []
        for _ in 0..<30 { d.advance(toTick: d.tick + 1); seq.append(d.currentFrame) }
        XCTAssertTrue(seq.allSatisfy { $0 == "idle" || $0 == "blink" },
                      "L2 workout: static pose + blink only (splits announced by VoiceOver/haptic)")
    }

    func testWorkoutModeDeterministicPerSeed() throws {
        func run() throws -> [String] {
            let d = try director(.nimbus)
            d.setWorkoutMode(true, paceBand: 3)
            d.handleLifeEvent(.split(distanceKm: 1))
            var s: [String] = []
            for _ in 0..<200 { d.advance(toTick: d.tick + 1); s.append(d.currentFrame) }
            return s
        }
        XCTAssertEqual(try run(), try run())
    }

    func testSplitKindHashStable() {
        XCTAssertEqual(LifeSenseMapping.kindHash(of: .split(distanceKm: 3)), LifeKind.hash(of: .split))
        XCTAssertEqual(SpriteDirector.kind(of: .split(distanceKm: 1)), .split)
    }
}
