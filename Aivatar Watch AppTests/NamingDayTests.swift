import XCTest
@testable import Aivatar_Watch_App

/** Aivatar 2.0 E4 — the naming-day persistence rule, the anniversary beat
 (selector rung ordering, Feb 29 -> Mar 1, once-per-day gate), and the
 postcard stamp's determinism pins. (E3's live naming perk retired with the
 portrait hero in AMS v2 v43; the celebration lives on the commit path.) */
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
        let mar1_2026 = Date(timeIntervalSince1970: 1_772_323_200)  // 2026-03-01 00:00 UTC
        XCTAssertTrue(WakeBeatSelector.isAnniversary(namingDay: naming, now: mar1_2026, calendar: utc))
        // ...but not on 2028-03-01 (2028 IS a leap year).
        let mar1_2028 = Date(timeIntervalSince1970: 1_835_481_600)  // 2028-03-01 00:00 UTC
        XCTAssertFalse(WakeBeatSelector.isAnniversary(namingDay: naming, now: mar1_2028, calendar: utc))
        // And the real anniversary still matches in a leap year.
        let feb29_2028 = Date(timeIntervalSince1970: 1_835_395_200)  // 2028-02-29 00:00 UTC
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
        XCTAssertEqual(WakeBeatCaption.text(for: .namingAnniversary(years: 1), name: "Ember"),
                       String(format: String(localized: "beat.namingday.title"), "Ember"))
        let cap2 = WakeBeatCaption.text(for: .namingAnniversary(years: 3), name: "Ember")
        XCTAssertNotNil(cap2)
        XCTAssertLessThanOrEqual(cap2!.split(separator: " ").count, 8, "house voice")
        XCTAssertFalse(WakeBeatSelector.acts(for: .namingAnniversary(years: 1), archetype: .willow).isEmpty)
        XCTAssertEqual(WakeBeatSelector.acts(for: .namingAnniversary(years: 1), archetype: .willow), [.slowBlink])
    }

    func testPostcardAnniversaryIsPrintChromeOnly() throws {
        // v3: the anniversary is a static corner stamp on the card front —
        // three accent dots (pinned in PostcardCardTests). It never alters
        // the animated moment, so the pinned frame hashes stay identical.
        let base = PostcardInputs(archetypeRaw: "ember", seed: 20261010, name: "Ember")
        let stamped = PostcardInputs(archetypeRaw: "ember", seed: 20261010, name: "Ember", anniversary: true)
        XCTAssertEqual(PostcardComposer.frameHashes(base).count, PostcardComposer.frameCount)
        XCTAssertEqual(PostcardComposer.frameHashes(base), PostcardComposer.frameHashes(stamped),
                       "the stamp must not change the card's pinned hashes")
        // Legacy payloads (no anniversary key) decode with anniversary nil.
        let legacy = #"{"archetypeRaw":"ember","seed":5,"name":"Ember","bondLevel":3,"dayCount":2,"streakDays":0}"#
        let decoded = try JSONDecoder().decode(PostcardInputs.self, from: legacy.data(using: .utf8)!)
        XCTAssertNil(decoded.anniversary)
    }
}
