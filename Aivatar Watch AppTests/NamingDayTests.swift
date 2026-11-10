import XCTest
@testable import Aivatar_Watch_App

/// Aivatar 2.0 E3 + E4 — the naming perk throttle, the naming-day persistence
/// rule, the anniversary beat (selector rung ordering, Feb 29 -> Mar 1,
/// once-per-day gate), and the postcard stamp's determinism pins.
final class NamingPerkTests: XCTestCase {

    func testPerkThrottleWindow() {
        var t = PerkThrottle()
        XCTAssertTrue(t.allow(tick: 0), "first perk allowed")
        XCTAssertFalse(t.allow(tick: 19), "inside the 20-tick window")
        XCTAssertTrue(t.allow(tick: 20), "window boundary re-allows")
        XCTAssertFalse(t.allow(tick: 21))
        XCTAssertTrue(t.allow(tick: 40))
    }

    func testNamingDayPersistedShape() throws {
        // The commit path writes namingDay; the pure rule is that a set
        // namingDay drives the anniversary match and nil never does.
        let now = Date(timeIntervalSince1970: 1_793_620_800)  // 2026-11-03 12:00 UTC
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertFalse(WakeBeatSelector.isAnniversary(namingDay: now.addingTimeInterval(-86_400), now: now, calendar: cal))
        XCTAssertTrue(WakeBeatSelector.isAnniversary(namingDay: now.addingTimeInterval(-365 * 86_400), now: now, calendar: cal))
    }
}

final class NamingDayTests: XCTestCase {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }
    private let now = Date(timeIntervalSince1970: 1_793_620_800)  // 2026-11-03 12:00 UTC (2026 not a leap year)

    private func memory(namingDay: Date?) -> CompanionMemory {
        var m = CompanionMemory(firstLaunch: now.addingTimeInterval(-400 * 86_400), lastSeen: now)
        m.namingDay = namingDay
        return m
    }

    func testFeb29HonoredOnMar1InNonLeapYear() {
        // Naming on 2024-02-29 (leap); 2026-03-01 is not a leap year -> honored.
        let naming = Date(timeIntervalSince1970: 1_709_164_800)  // 2024-02-29 00:00 UTC
        let mar1_2026 = Date(timeIntervalSince1970: 1_772_236_800)  // 2026-03-01 00:00 UTC
        XCTAssertTrue(WakeBeatSelector.isAnniversary(namingDay: naming, now: mar1_2026, calendar: utc))
        // ...but not on 2028-03-01 (2028 IS a leap year).
        let mar1_2028 = Date(timeIntervalSince1970: 1_835_308_800)  // 2028-03-01 00:00 UTC
        XCTAssertFalse(WakeBeatSelector.isAnniversary(namingDay: naming, now: mar1_2028, calendar: utc))
        // And the real anniversary still matches in a leap year.
        let feb29_2028 = Date(timeIntervalSince1970: 1_835_251_200)  // 2028-02-29 00:00 UTC
        XCTAssertTrue(WakeBeatSelector.isAnniversary(namingDay: naming, now: feb29_2028, calendar: utc))
    }

    func testAnniversaryRungSitsBetweenLifeEventAndWeather() {
        // A pending life event wins over the anniversary.
        var m = memory(namingDay: now.addingTimeInterval(-365 * 86_400))
        m.lifeLog = [LifeLogEntry(kindHash: LifeKind.hash(of: .workoutDone),
                                  dayIndex: CompanionMemoryStore.dayIndex(of: now, calendar: utc),
                                  at: now.addingTimeInterval(-3_600))]
        let beat = WakeBeatSelector.beat(memory: m, archetype: .ember, now: now, calendar: utc)
        XCTAssertEqual(beat, .lifeEvent(kind: .workoutDone))
        // No life event -> the anniversary fires.
        m.lifeLog = []
        let beat2 = WakeBeatSelector.beat(memory: m, archetype: .ember, now: now, calendar: utc)
        XCTAssertEqual(beat2, .namingAnniversary(years: 1))
        // No naming day -> no anniversary rung.
        let m2 = memory(namingDay: nil)
        if case .namingAnniversary = WakeBeatSelector.beat(memory: m2, archetype: .ember, now: now, calendar: utc) {
            XCTFail("nil namingDay must never produce the anniversary beat")
        }
    }

    func testAnniversaryOncePerDay() {
        var m = memory(namingDay: now.addingTimeInterval(-365 * 86_400))
        let first = WakeBeatSelector.beat(memory: m, archetype: .willow, now: now, calendar: utc)
        XCTAssertEqual(first, .namingAnniversary(years: 1))
        WakeBeatSelector.markShown(&m, now: now, calendar: utc)
        XCTAssertNil(WakeBeatSelector.beat(memory: m, archetype: .willow, now: now, calendar: utc),
                     "second visit same day: short wake only (G4)")
    }

    func testAnniversaryCaptionAndActs() {
        XCTAssertEqual(WakeBeatSelector.text(for: .namingAnniversary(years: 1), name: "Ember"),
                       String(format: String(localized: "beat.namingday.title"), "Ember"))
        let cap2 = WakeBeatSelector.text(for: .namingAnniversary(years: 3), name: "Ember")
        XCTAssertNotNil(cap2)
        XCTAssertLessThanOrEqual(cap2!.split(separator: " ").count, 8, "house voice")
        XCTAssertFalse(WakeBeatSelector.acts(for: .namingAnniversary(years: 1), archetype: .willow).isEmpty)
        XCTAssertEqual(WakeBeatSelector.acts(for: .namingAnniversary(years: 1), archetype: .willow), [.slowBlink])
    }

    func testPostcardStampChangesHashesDeterministically() {
        let base = PostcardInputs(archetypeRaw: "ember", seed: 20261010, name: "Ember")
        let stamped = PostcardInputs(archetypeRaw: "ember", seed: 20261010, name: "Ember", anniversary: true)
        let h1 = PostcardComposer.frameHashes(base)
        let h2 = PostcardComposer.frameHashes(stamped)
        XCTAssertEqual(h1.count, PostcardComposer.frameCount)
        XCTAssertNotEqual(h1, h2, "the stamp must change the card's pinned hashes")
        // Deterministic: same inputs -> same hashes.
        XCTAssertEqual(h2, PostcardComposer.frameHashes(stamped))
        // The stamp is exactly the 3x3 accent block at the top-right corner.
        XCTAssertEqual(PostcardStamp.cells().count, 9)
        XCTAssertTrue(PostcardStamp.cells().allSatisfy { $0.symbol == "A" && $0.x >= 17 && $0.y <= 2 })
    }
}
