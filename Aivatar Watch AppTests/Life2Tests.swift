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

    // MARK: - Interiority overlays (memory made visible)

    func testInteriorityOverlaysAreAuthoredCells() throws {
        let willow = AuthoredSprites.sprite(for: .willow)
        var t = InteriorityTuning()
        t.sproutGrowth = 1.0
        let sprout = willow.interiorityDiffs(t)
        XCTAssertEqual(sprout.count, 2, "mature sprout = two leaf cells")
        let grid = willow.symbols(frameID: "idle", overlay: sprout)
        XCTAssertEqual(grid[0][10], "A")
        XCTAssertEqual(grid[0][11], "A")

        let compass = AuthoredSprites.sprite(for: .compass)
        t = InteriorityTuning()
        t.streakDays = 4
        let week = compass.interiorityDiffs(t)
        XCTAssertEqual(week.count, 7, "the week grid is seven cells")
        let fishGrid = compass.symbols(frameID: "idle", overlay: week)
        XCTAssertEqual(fishGrid[14][5], "A", "lit streak day")
        XCTAssertEqual(fishGrid[14][8], "A")
        XCTAssertEqual(fishGrid[14][9], "K", "pending day stays ink")

        let prism = AuthoredSprites.sprite(for: .prism)
        t = InteriorityTuning()
        t.trinketPresent = true
        let trinket = prism.interiorityDiffs(t)
        XCTAssertEqual(trinket.count, 2)
        let chamGrid = prism.symbols(frameID: "idle", overlay: trinket)
        XCTAssertEqual(chamGrid[4][12], "A")

        let ember = AuthoredSprites.sprite(for: .ember)
        XCTAssertTrue(ember.interiorityDiffs(.default).isEmpty, "ember keeps no trace cells")
    }

    func testInteriorityOverlayComposesWithinPatchBudget() throws {
        // Overlay + any frame together still respect the craft budget.
        for archetype in Archetype.allCases {
            let sprite = AuthoredSprites.sprite(for: archetype)
            var t = InteriorityTuning()
            t.sproutGrowth = 1.4
            t.streakDays = 7
            t.trinketPresent = true
            let overlay = sprite.interiorityDiffs(t)
            let idle = sprite.symbols(frameID: "idle")
            for frameID in CompanionSprite.frameIDs.dropFirst() {
                let frame = sprite.symbols(frameID: frameID, overlay: overlay)
                var diff = 0
                for y in 0..<CompanionSprite.gridHeight {
                    for x in 0..<CompanionSprite.gridWidth {
                        if idle[y][x] != frame[y][x] { diff += 1 }
                    }
                }
                XCTAssertLessThanOrEqual(diff, 20, "\(archetype.rawValue)/\(frameID) + overlay within budget")
            }
        }
    }
}
