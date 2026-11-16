import XCTest
@testable import Aivatar_Watch_App

/// v15/v16 "Life 2.0" suite (Tools/PIXEL_DESIGN.md §7): the life floor
/// (breathing + idle variants), the mood model, anticipation wind-ups,
/// yawn, the self-play mote, and the interiority overlay cells. All
/// deterministic per seed — same discipline as the rest of the director.
final class Life2Tests: XCTestCase {

    private func director(_ archetype: Archetype, seed: UInt64 = 20261104) throws -> SpriteDirector {
        SpriteDirector(profile: try PersonalityProfile.load(archetype), seed: seed)
    }

    private func frames(_ d: SpriteDirector, ticks: Int) -> [String] {
        (0..<ticks).map { _ in
            d.advance(toTick: d.tick + 1)
            return d.currentFrame
        }
    }

    // MARK: - Life floor

    func testBreathingFloorExistsAndIsSlow() throws {
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            let seq = frames(d, ticks: 120)
            let breaths = seq.filter { $0 == "breathe" }.count
            XCTAssertGreaterThan(breaths, 4, "\(archetype.rawValue): the companion breathes")
            XCTAssertLessThan(breaths, 30, "\(archetype.rawValue): breath rate is slow, not panting")
        }
    }

    func testIdleVariantsRotate() throws {
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            let seq = frames(d, ticks: 400)
            XCTAssertTrue(seq.contains("idleA") || seq.contains("idleB"),
                          "\(archetype.rawValue): idle drifts between variants")
        }
    }

    func testLifeFloorIsStaticUnderL2() throws {
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            d.accessibilityMode = .reduceMotionL2
            let seq = frames(d, ticks: 300)
            XCTAssertTrue(seq.allSatisfy { $0 == "idle" || $0 == "blink" },
                          "\(archetype.rawValue): L2 never shows the moving floor")
        }
    }

    // MARK: - Mood

    func testMoodGoesLonelyUnattendedAndRecoversOnTouch() throws {
        let d = try director(.ember)
        _ = frames(d, ticks: 400)
        XCTAssertEqual(d.mood, .lonely, "unattended for a while -> lonely")
        d.handleEvent(.tap)
        XCTAssertNotEqual(d.mood, .lonely, "a touch answers the loneliness")
    }

    func testMoodPlayfulAfterInteractionBurst() throws {
        let d = try director(.nimbus)
        _ = frames(d, ticks: 20)
        for _ in 0..<4 { d.handleEvent(.tap); d.advance(toTick: d.tick + 2) }
        XCTAssertEqual(d.mood, .playful, "a burst of attention reads as play")
    }

    func testMoodIsDeterministicPerSeed() throws {
        let a = try director(.willow)
        let b = try director(.willow)
        var ma: [SpriteMood] = []
        var mb: [SpriteMood] = []
        for _ in 0..<600 {
            a.advance(toTick: a.tick + 1); b.advance(toTick: b.tick + 1)
            ma.append(a.mood); mb.append(b.mood)
        }
        XCTAssertEqual(ma, mb)
    }

    func testLonelyPokesAreRateCapped() throws {
        // No interaction for 50 director-minutes: the attention pokes are
        // bounded (~one per 36 s), never a needy spam loop.
        let d = try director(.compass)
        let seq = frames(d, ticks: 3000)
        let pokes = seq.filter { $0 == "perk" }.count
        XCTAssertGreaterThanOrEqual(pokes, 5, "lonely companion does poke for attention")
        XCTAssertLessThanOrEqual(pokes, 25, "pokes + quirk wind-ups stay rate-capped")
        XCTAssertLessThanOrEqual(d.actCount, 80, "total idle acts stay bounded")
    }

    // MARK: - Anticipation & yawn

    func testQuirkAlwaysWindsUpWithPerk() throws {
        for archetype in Archetype.allCases {
            // v28: the wind-up length is profile-driven (any nonzero
            // anticipation earns >= 1 perk tick); anticipation exactly 0
            // (willow) is a deliberate no-wind-up — the frog just croaks.
            let profile = try PersonalityProfile.load(archetype)
            let windup = SpriteDirector.perkWindupTicks(anticipation: profile.motionGrammar?.anticipation ?? 0)
            let d = try director(archetype)
            let seq = frames(d, ticks: 3000)
            for i in 1..<seq.count
            where seq[i] == "quirk" && seq[i - 1] != "quirk" {
                if windup > 0 {
                    XCTAssertEqual(seq[i - 1], "perk",
                                   "\(archetype.rawValue): a signature move is anticipated, not random")
                } else {
                    XCTAssertNotEqual(seq[i - 1], "perk",
                                      "\(archetype.rawValue): zero-anticipation archetypes never wind up")
                }
            }
        }
    }

    func testOneYawnPerLongUnattendedStretch() throws {
        let d = try director(.prism)
        let seq = frames(d, ticks: 2000)
        let yawns = seq.filter { $0 == "yawn" }.count
        XCTAssertGreaterThanOrEqual(yawns, 1, "a long unattended stretch earns a yawn")
        XCTAssertLessThanOrEqual(yawns, 2, "yawns never spam (4.5 min cooldown)")
    }

    // MARK: - Autonomy: the self-play mote

    func testMoteSelfPlaySpawnsChasesAndFades() throws {
        let d = try director(.ember)
        var activeTicks = 0
        var sawGlanceAfterSpawn = false
        var wasNil = true
        for _ in 0..<4000 {
            d.advance(toTick: d.tick + 1)
            let hasMote = d.moteCell != nil
            if hasMote { activeTicks += 1 }
            if hasMote && wasNil {
                // the companion glances toward the mote at the spawn tick
                // (v28 dart-and-hold) or within the next few ticks — capture
                // the spawn frame BEFORE frames() advances the clock
                let spawnFrame = d.currentFrame
                let upcoming = frames(d, ticks: 3)
                if spawnFrame == "glanceL" || spawnFrame == "glanceR"
                    || upcoming.contains("glanceL") || upcoming.contains("glanceR") {
                    sawGlanceAfterSpawn = true
                }
            }
            wasNil = !hasMote
        }
        XCTAssertGreaterThan(activeTicks, 40, "the mote actually appears and lives a while")
        XCTAssertLessThan(Double(activeTicks) / 4000.0, 0.20, "mote duty cycle stays quiet")
        XCTAssertTrue(sawGlanceAfterSpawn, "the companion chases the mote it spawned")
    }

    func testMoteNeverAppearsUnderL2OrRest() throws {
        let d = try director(.nimbus)
        d.accessibilityMode = .reduceMotionL2
        for _ in 0..<1000 {
            d.advance(toTick: d.tick + 1)
            XCTAssertNil(d.moteCell, "L2: no self-play mote")
        }
        let d2 = try director(.nimbus)
        d2.setResting(true)
        for _ in 0..<200 {
            d2.advance(toTick: d2.tick + 1)
            XCTAssertNil(d2.moteCell, "rest: no self-play mote")
        }
    }

    // MARK: - Interiority (memory made visible, v3: props only)

    func testInteriorityRidesPropsPerFamily() throws {
        // Willow's mature sprout is a head prop; at growth 0 it is hidden.
        var t = InteriorityTuning()
        t.sproutGrowth = 1.0
        var willowDrive = PuppetDrive(archetype: .willow, frameID: "idle")
        willowDrive.interiority = t
        XCTAssertTrue(PuppetPoser.resolve(willowDrive).props.sprout, "mature sprout visible")
        var bare = willowDrive
        bare.interiority = InteriorityTuning(sproutGrowth: 0, streakDays: 0,
                                              trinketPresent: false, confidantMemento: false)
        XCTAssertFalse(PuppetPoser.resolve(bare).props.sprout)
        // The sprout never leaks onto another family.
        var foreign = bare
        foreign.archetype = .ember
        foreign.interiority = t
        XCTAssertFalse(PuppetPoser.resolve(foreign).props.sprout, "sprout is willow-only")

        // Compass's week grid: lit streak days, total seven, clamped.
        var week = InteriorityTuning()
        week.streakDays = 4
        var compassDrive = PuppetDrive(archetype: .compass, frameID: "idle")
        compassDrive.interiority = week
        let weekProps = PuppetPoser.resolve(compassDrive).props
        XCTAssertEqual(weekProps.weekLit, 4)
        XCTAssertEqual(weekProps.weekTotal, 7)

        // Prism's trinket.
        var trinket = InteriorityTuning()
        trinket.trinketPresent = true
        var prismDrive = PuppetDrive(archetype: .prism, frameID: "idle")
        prismDrive.interiority = trinket
        XCTAssertTrue(PuppetPoser.resolve(prismDrive).props.trinket)

        // Ember keeps no trace props at default interiority.
        let idle = PuppetPoser.resolve(PuppetDrive(archetype: .ember, frameID: "idle")).props
        XCTAssertFalse(idle.sprout)
        XCTAssertEqual(idle.weekLit, 0)
        XCTAssertFalse(idle.trinket)
        XCTAssertEqual(idle.mementoAlpha, 0)
    }

    func testInteriorityNeverMovesTheBody() throws {
        // The strongest form of the old budget rule: memory is visible via
        // PROPS (drawn beside/on the puppet); it never changes the pose, on
        // any frame, for any family.
        for archetype in Archetype.allCases {
            for frame in ["idle", "idleA", "idleB", "blink", "sleepy", "happy",
                          "glanceL", "glanceR", "quirk", "perk", "yawn"] {
                var rich = InteriorityTuning()
                rich.sproutGrowth = 1.4
                rich.streakDays = 7
                rich.trinketPresent = true
                rich.confidantMemento = true
                var plain = PuppetDrive(archetype: archetype, frameID: frame)
                var laden = plain
                laden.interiority = rich
                laden.mementoSteady = true
                XCTAssertEqual(PuppetPoser.resolve(plain).pose,
                               PuppetPoser.resolve(laden).pose,
                               "\(archetype.rawValue)/\(frame): memory never poses the body")
            }
        }
    }
}
