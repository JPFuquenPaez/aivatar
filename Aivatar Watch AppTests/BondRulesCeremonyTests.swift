import XCTest
@testable import Aivatar_Watch_App

/// Aivatar 2.0 E5 — quiet level-up ceremonies. Pure crossing math, the
/// once-ever bitmask (bits set at schedule time), ceremony-after-settle
/// ordering on the director, workout suppression, and the level-5 memento
/// deposit's stepped alpha.
final class BondRulesCeremonyTests: XCTestCase {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }
    private let base = Date(timeIntervalSince1970: 1_793_620_800)

    private func memory() -> CompanionMemory {
        CompanionMemory(firstLaunch: base, lastSeen: base)
    }

    func testNewlyCrossedComputedAgainstPreAwardLevel() {
        var m = memory()
        // 9 XP -> level 1; awarding namingCeremony (25) crosses 2 and 3 at once.
        m.bondXP = 9
        let award = BondRules.award(&m, .namingCeremony, now: base, calendar: utc)
        XCTAssertEqual(award.previousLevel, 1)
        XCTAssertEqual(award.newLevel, 3)
        XCTAssertEqual(award.newlyCrossedLevels, [2, 3])
    }

    func testNoCrossingNoCeremony() {
        var m = memory()
        let award = BondRules.award(&m, .dailyPresence, now: base, calendar: utc)  // 5 XP, level 1
        XCTAssertEqual(award.newlyCrossedLevels, [])
        XCTAssertFalse(award.leveledUp)
    }

    func testBitmaskOnceEverAcrossMultipleAwards() {
        // Award 200 XP across 3 ceremonies: bits 2,3,4,5 set once each; a
        // reload with the same memory must not re-schedule anything.
        var m = memory()
        var allCrossed: [Int] = []
        for _ in 0..<8 {
            let award = BondRules.award(&m, .namingCeremony, now: base, calendar: utc)
            for level in award.newlyCrossedLevels where (m.crossedLevels & (1 << level)) == 0 {
                m.crossedLevels |= (1 << level)
                allCrossed.append(level)
            }
        }
        XCTAssertEqual(allCrossed.sorted(), [2, 3, 4, 5])
        XCTAssertEqual(m.crossedLevels, 0b111100)
        // Reload simulation: a fresh award at max level crosses nothing new.
        let again = BondRules.award(&m, .slowBlink, now: base, calendar: utc)
        XCTAssertEqual(again.newlyCrossedLevels, [])
    }

    func testCrossedLevelsRoundTripsAndLegacyDecodesZero() throws {
        var m = memory()
        m.crossedLevels = 0b101010
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(CompanionMemory.self, from: data)
        XCTAssertEqual(decoded.crossedLevels, 0b101010)
        // Legacy payload without the v4 key decodes to 0 (G8).
        let legacy = """
        {"firstLaunch": 1793620800, "lastSeen": 1793620800, "sessions": 3, "bondXP": 12}
        """.data(using: .utf8)!
        let old = try JSONDecoder().decode(CompanionMemory.self, from: legacy)
        XCTAssertEqual(old.crossedLevels, 0)
    }

    private func director() throws -> SpriteDirector {
        let profile = try PersonalityProfile.load(.ember)
        return SpriteDirector(profile: profile, seed: 20261010)
    }

    func testCeremonyFiresAfterSettleNotBefore() throws {
        let d = try director()
        d.scheduleCeremony(.quirk, afterTicks: 20)
        var firstQuirkTick = -1
        for t in 1...60 {
            d.advance(toTick: t)
            if d.currentFrame == "quirk" && firstQuirkTick < 0 { firstQuirkTick = t }
        }
        XCTAssertGreaterThanOrEqual(firstQuirkTick, 21, "ceremony waits for the +20-tick settle")
        XCTAssertGreaterThan(firstQuirkTick, 0, "ceremony eventually plays")
    }

    func testCeremonySuppressedDuringWorkout() throws {
        let d = try director()
        d.setWorkoutMode(true)
        d.scheduleCeremony(.quirk, afterTicks: 5)
        var sawQuirk = false
        for t in 1...40 {
            d.advance(toTick: t)
            if d.currentFrame == "quirk" { sawQuirk = true }
        }
        XCTAssertFalse(sawQuirk, "no ceremony while the run is the motion")
    }

    func testMementoDepositStepsAlphaOverFourTicks() throws {
        let d = try director()
        XCTAssertNil(d.mementoDepositAlpha)
        d.depositMemento()
        var alphas: [Float] = []
        for t in 1...4 {
            d.advance(toTick: t)
            if let a = d.mementoDepositAlpha { alphas.append(a) }
        }
        XCTAssertEqual(alphas, [0.25, 0.5, 0.75, 1.0])
        d.advance(toTick: 5)
        XCTAssertNil(d.mementoDepositAlpha, "deposit completes and the cell persists via interiority")
        // The transient overlay carries exactly the stepped cell.
        d.depositMemento()
        d.advance(toTick: 6)
        let cells = d.transientOverlayCells
        XCTAssertTrue(cells.contains { $0.x == 9 && $0.y == 16 && $0.symbol == "A" && $0.alpha < 1 })
    }
}
