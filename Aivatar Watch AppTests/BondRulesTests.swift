import XCTest
@testable import Aivatar_Watch_App

/// v16 F1 "Ritual Bonding" suite (Ambient Life spec F1 + §0 G4/G7/G8):
/// BondRules purity and monotonicity, once-per-day gates, level-up
/// detection, the additive memory schema v3 (legacy payloads decode with
/// defaults), the life-log ring buffer, and the director's bond-biased
/// idle schedule. All deterministic under injected dates/seeds.
final class BondRulesTests: XCTestCase {

    private func fnv(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// A fixed base date: 2026-11-03 12:00 UTC.
    private let base = Date(timeIntervalSince1970: 1_793_620_800)

    private func memory() -> CompanionMemory {
        CompanionMemory(firstLaunch: base, lastSeen: base)
    }

    // MARK: - XP table & thresholds

    func testRitualXPValues() {
        XCTAssertEqual(BondRules.xp(for: .slowBlink), 4)
        XCTAssertEqual(BondRules.xp(for: .firstGreetingOfDay), 3)
        XCTAssertEqual(BondRules.xp(for: .farewellAcknowledged), 2)
        XCTAssertEqual(BondRules.xp(for: .namingCeremony), 25)
        XCTAssertEqual(BondRules.xp(for: .dailyPresence), 5)
    }

    func testLevelThresholds() {
        XCTAssertEqual(BondRules.level(forXP: 0), 1)
        XCTAssertEqual(BondRules.level(forXP: 9), 1)
        XCTAssertEqual(BondRules.level(forXP: 10), 2)
        XCTAssertEqual(BondRules.level(forXP: 29), 2)
        XCTAssertEqual(BondRules.level(forXP: 30), 3)
        XCTAssertEqual(BondRules.level(forXP: 60), 4)
        XCTAssertEqual(BondRules.level(forXP: 100), 5)
        XCTAssertEqual(BondRules.level(forXP: 10_000), 5, "level caps at confidant")
    }

    // MARK: - G4: monotonic, no decay

    func testBondIsMonotonicAndNeverDecays() {
        var m = memory()
        var level = 1
        // 60 days of mixed rituals + long absences: the level can only grow.
        for day in 0..<60 {
            let now = base.addingTimeInterval(Double(day) * 86_400)
            for ritual in BondRitual.allCases {
                let award = BondRules.award(&m, ritual, now: now, calendar: utc)
                XCTAssertGreaterThanOrEqual(award.newLevel, level, "level never drops")
                XCTAssertGreaterThanOrEqual(award.newXP, m.bondXP - award.xpGained)
                level = award.newLevel
            }
            // A 30-day absence changes nothing — there is no decay path.
            let afterAbsence = BondRules.level(forXP: m.bondXP)
            XCTAssertEqual(afterAbsence, level)
        }
        XCTAssertGreaterThan(m.bondXP, 0)
    }

    // MARK: - Once-per-day gates (deterministic under injected dates)

    func testDailyPresenceAwardsOncePerDay() {
        var m = memory()
        let day1 = base
        let a1 = BondRules.award(&m, .dailyPresence, now: day1, calendar: utc)
        XCTAssertEqual(a1.xpGained, 5)
        let a2 = BondRules.award(&m, .dailyPresence, now: day1.addingTimeInterval(3_600), calendar: utc)
        XCTAssertEqual(a2.xpGained, 0, "same day, no double award")
        let day2 = day1.addingTimeInterval(86_400)
        let a3 = BondRules.award(&m, .dailyPresence, now: day2, calendar: utc)
        XCTAssertEqual(a3.xpGained, 5, "next day awards again")
    }

    func testFirstGreetingIsIndependentOfPresenceGate() {
        var m = memory()
        let a1 = BondRules.award(&m, .dailyPresence, now: base, calendar: utc)
        let a2 = BondRules.award(&m, .firstGreetingOfDay, now: base, calendar: utc)
        XCTAssertEqual(a1.xpGained, 5)
        XCTAssertEqual(a2.xpGained, 3, "greeting has its own once-per-day gate")
        let a3 = BondRules.award(&m, .firstGreetingOfDay, now: base, calendar: utc)
        XCTAssertEqual(a3.xpGained, 0)
    }

    func testLevelUpFiresExactlyOnCrossing() {
        var m = memory()
        // 5 + 3 = 8 XP (level 1), then a slow blink (4) crosses 10 -> level 2.
        XCTAssertFalse(BondRules.award(&m, .dailyPresence, now: base, calendar: utc).leveledUp)
        XCTAssertFalse(BondRules.award(&m, .firstGreetingOfDay, now: base, calendar: utc).leveledUp)
        let crossing = BondRules.award(&m, .slowBlink, now: base, calendar: utc)
        XCTAssertTrue(crossing.leveledUp)
        XCTAssertEqual(crossing.previousLevel, 1)
        XCTAssertEqual(crossing.newLevel, 2)
        // Next slow blink: 16 XP, still level 2 — no double announcement.
        XCTAssertFalse(BondRules.award(&m, .slowBlink, now: base, calendar: utc).leveledUp)
    }

    func testNamingCeremonyIsTheLargeOneTimeGrant() {
        var m = memory()
        let award = BondRules.award(&m, .namingCeremony, now: base, calendar: utc)
        XCTAssertEqual(award.xpGained, 25)
        XCTAssertEqual(award.newLevel, 2, "25 XP crosses the level-2 threshold (10), not level 3 (30)")
    }

    // MARK: - G8: additive schema v3 — legacy payloads decode with defaults

    func testLegacyMemoryPayloadDecodesWithDefaults() throws {
        // A v15-era payload: none of the v16 keys exist.
        let legacy = """
        {"firstLaunch":1793620800,"lastSeen":1793620800,"sessions":12,"streakDays":4,
         "sproutDays":9.0,"rehearsalLevel":1,"trinketDay":20784,"usualHourEMA":9.5}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CompanionMemory.self, from: legacy)
        XCTAssertEqual(decoded.sessions, 12)
        XCTAssertEqual(decoded.bondXP, 0)
        XCTAssertTrue(decoded.lifeLog.isEmpty)
        XCTAssertEqual(decoded.lastPresenceDay, -1)
        XCTAssertEqual(decoded.lastGreetingDay, -1)
        XCTAssertEqual(decoded.bondLevel, 1)
    }

    func testMemoryRoundTripCarriesV3Keys() throws {
        var m = memory()
        m.bondXP = 42
        m.appendLifeLog(LifeLogEntry(kindHash: 1234, dayIndex: 20_800))
        let data = try JSONEncoder().encode(m)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("bondXP"))
        XCTAssertTrue(json.contains("lifeLog"))
        let decoded = try JSONDecoder().decode(CompanionMemory.self, from: data)
        XCTAssertEqual(decoded, m)
    }

    func testLifeLogRingBufferCapsAt20() {
        var m = memory()
        for i in 0..<25 {
            m.appendLifeLog(LifeLogEntry(kindHash: i, dayIndex: 20_800 + i))
        }
        XCTAssertEqual(m.lifeLog.count, 20)
        XCTAssertEqual(m.lifeLog.first?.kindHash, 5, "oldest entries drop first")
        XCTAssertEqual(m.lifeLog.last?.kindHash, 24)
    }

    func testRecordVisitAwardsDailyPresenceOncePerDay() {
        let suite = "bondrules-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = CompanionMemoryStore(defaults: defaults)
        let s1 = store.recordVisit(now: base, calendar: utc)
        XCTAssertEqual(s1.bondLevel, 1)
        XCTAssertEqual(store.load()?.bondXP, 5, "first visit of the day grants presence")
        let s2 = store.recordVisit(now: base.addingTimeInterval(120), calendar: utc)
        XCTAssertEqual(store.load()?.bondXP, 5, "same-day reopen grants nothing more")
        XCTAssertEqual(s2.dayCount, 1)
        _ = store.recordVisit(now: base.addingTimeInterval(86_400), calendar: utc)
        XCTAssertEqual(store.load()?.bondXP, 10, "next day grants presence again")
        XCTAssertEqual(store.load()?.bondLevel, 2)
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Director: bond biases the idle schedule (deterministic)

    private func director(_ archetype: Archetype, seed: UInt64 = 20261106) throws -> SpriteDirector {
        SpriteDirector(profile: try PersonalityProfile.load(archetype), seed: seed)
    }

    func testHigherBondQuirksMoreAndGlancesAwayLess() throws {
        for archetype in Archetype.allCases {
            func run(level: Int) throws -> (quirks: Int, glances: Int) {
                let d = try director(archetype)
                d.bondLevel = level
                var quirks = 0, glances = 0
                var prev = ""
                for _ in 0..<6000 {
                    d.advance(toTick: d.tick + 1)
                    let f = d.currentFrame
                    if f == "quirk" && prev != "quirk" { quirks += 1 }
                    if (f == "glanceL" || f == "glanceR") && prev != f { glances += 1 }
                    prev = f
                }
                return (quirks, glances)
            }
            let low = try run(level: 1)
            let high = try run(level: 5)
            XCTAssertGreaterThan(high.quirks, low.quirks,
                                 "\(archetype.rawValue): confidant quirks more (signature in rotation)")
            XCTAssertLessThan(high.glances, low.glances,
                              "\(archetype.rawValue): confidant glances away less (looks at you)")
        }
    }

    func testBondLevelIsClampedAndDeterministicPerSeed() throws {
        let a = try director(.ember)
        a.bondLevel = 99
        XCTAssertEqual(a.bondLevel, 5)
        a.bondLevel = -3
        XCTAssertEqual(a.bondLevel, 1)
        let b = try director(.ember)
        b.bondLevel = 3
        let c = try director(.ember)
        c.bondLevel = 3
        var sa: [String] = [], sb: [String] = []
        for _ in 0..<600 {
            a.advance(toTick: a.tick + 1); sa.append(a.currentFrame)
            b.advance(toTick: b.tick + 1); sb.append(b.currentFrame)
        }
        // a is at level 1 (clamped from -3), b/c at 3 — same seed, same level => identical
        let d2 = try director(.ember); d2.bondLevel = 3
        var sc: [String] = []
        for _ in 0..<600 { d2.advance(toTick: d2.tick + 1); sc.append(d2.currentFrame) }
        XCTAssertEqual(sb, sc, "same seed + same bond level = same sequence")
    }

    func testRitualAcksPlayAndAreRecorded() throws {
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            d.handleRitual(.slowBlink)
            XCTAssertEqual(d.lastRitual, .slowBlink)
            var seq: [String] = []
            for _ in 0..<12 { d.advance(toTick: d.tick + 1); seq.append(d.currentFrame) }
            XCTAssertTrue(seq.contains("blink"), "\(archetype.rawValue): slow-blink ritual answers with a watchable blink")
            d.handleRitual(.namingCeremony)
            XCTAssertEqual(d.lastRitual, .namingCeremony)
            XCTAssertEqual(d.ritualCount, 2)
        }
    }

    func testFarewellBloomLongerAtLevel4() throws {
        func bloom(level: Int) throws -> Int {
            let d = try director(.willow)
            d.bondLevel = level
            d.handleEvent(.sleep)
            var sleepyRun = 0, maxRun = 0
            for _ in 0..<40 {
                d.advance(toTick: d.tick + 1)
                if d.currentFrame == "sleepy" { sleepyRun += 1; maxRun = max(maxRun, sleepyRun) }
                else { sleepyRun = 0 }
            }
            return maxRun
        }
        XCTAssertEqual(try bloom(level: 2), 12)
        XCTAssertEqual(try bloom(level: 4), 18, "level 4+ earns the signature goodbye beat")
    }

    // MARK: - Confidant memento cell is empty in every base grid

    func testConfidantMementoCellIsFreeInAllBaseGrids() {
        for archetype in Archetype.allCases {
            let sprite = AuthoredSprites.sprite(for: archetype)
            // v40: image-backed pets draw the memento over the ground tile
            // (row 16 is tile), so the free-cell rule binds authored grids.
            if sprite.isImageBacked {
                let m = SpriteStageMetadata.meta(for: archetype)
                XCTAssertTrue(m.shadowRow <= 16 && 16 < m.shadowRow + 3,
                              "\(archetype.rawValue): memento cell sits on the tile")
                continue
            }
            let grid = sprite.symbols(frameID: "idle")
            XCTAssertEqual(grid[16][9], ".", "\(archetype.rawValue): memento cell (9,16) must be empty in the idle base")
        }
    }

    func testConfidantMementoAppearsInOverlay() {
        for archetype in Archetype.allCases {
            let sprite = AuthoredSprites.sprite(for: archetype)
            let t = InteriorityTuning(sproutGrowth: 1, streakDays: 0, trinketPresent: false, confidantMemento: true)
            let diffs = sprite.interiorityDiffs(t)
            XCTAssertTrue(diffs.contains { $0.x == 9 && $0.y == 16 && $0.symbol == "A" },
                          "\(archetype.rawValue): confidant memento drawn")
            let off = sprite.interiorityDiffs(.default)
            XCTAssertFalse(off.contains { $0.x == 9 && $0.y == 16 },
                           "\(archetype.rawValue): no memento below confidant")
        }
    }

    // MARK: - Golden pins: bond-level-3 idle sequences (record mode below)

    func testBondLevel3SequenceHashes() throws {
        // v16 golden pins (first pin 2026-11-03). Update deliberately —
        // and say why. RECORD MODE below reports the values to pin.
        let expected: [Archetype: UInt64] = [
            // Pinned 2026-11-07 (v17 re-pin): 600-tick idle sequence at
            // bondLevel 3 (seed 20261106). Re-pinned 2026-11-07 (v28): the
            // breathe hold widened to 4/24 ticks, blinks hold the profile's
            // blinkTicks with a refractory, looks are 2-tick darts, and quirk
            // wind-ups follow the anticipation dial — the sequence grammar
            // changed deliberately, so all five hashes move.
            .ember: 814_125_260_989_122_358,
            .willow: 2_916_388_268_837_690_245,
            .compass: 3_425_083_962_399_002_162,
            .prism: 9_864_322_153_773_428_036,
            .nimbus: 499_010_127_866_336_243,
            .lumen: 7_893_875_153_974_737_327,
        ]
        var recorded: [String] = []
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            d.bondLevel = 3
            var seq: [String] = []
            for _ in 0..<600 { d.advance(toTick: d.tick + 1); seq.append(d.currentFrame) }
            let value = fnv(seq.joined(separator: ","))
            recorded.append("\(archetype.rawValue) = \(value)")
            let pin = expected[archetype] ?? 0
            if pin != 0 {
                XCTAssertEqual(value, pin, "\(archetype.rawValue) bond-level-3 sequence changed")
            }
        }
        PinRecorder.requirePinned(expected, recorded: recorded.joined(separator: ", "), label: "bond sequence hashes")
    }
}
