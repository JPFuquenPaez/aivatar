import XCTest
@testable import Aivatar_Watch_App

/// v18 F4 "watch-face presence" suite: the complication state model —
/// presence derivation (event > awake > asleep, strict windows), the
/// one-line copy table (<= 8 words, words-not-pixels accessibility), the
/// timeline schedule (expiry anchors + hard 12-entry cap, adversarial),
/// snapshot schema v2 lenient decode, icon state variants, and the shared
/// kind-hash parity between app lifeLog and widget copy table.
final class WidgetPresenceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_793_620_800)  // 2026-11-03 12:00 UTC
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    // MARK: - Snapshot schema v2 (additive, lenient)

    func testLegacyV12SnapshotDecodesAsAsleep() throws {
        let legacy = """
        {"archetypeRaw":"willow","name":"Willow","streakDays":7}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(CompanionWidgetSnapshot.self, from: legacy)
        XCTAssertEqual(snap.archetypeRaw, "willow")
        XCTAssertEqual(snap.streakDays, 7)
        XCTAssertEqual(snap.presence, .asleep, "v12 snapshots are asleep by default")
        XCTAssertEqual(snap.dayCount, 1)
        XCTAssertEqual(snap.line, "")
        XCTAssertNil(snap.lastSeen)
        XCTAssertNil(snap.lastEventAt)
    }

    func testSnapshotV2RoundTrip() throws {
        let snap = CompanionWidgetSnapshot(
            archetypeRaw: "ember", name: "Ember", streakDays: 23,
            presence: .event, line: "celebrated your workout", dayCount: 23,
            animalName: "fox", lastSeen: now, lastEventAt: now.addingTimeInterval(-600),
            lastEventKindRaw: "workoutDone")
        let data = try JSONEncoder().encode(snap)
        XCTAssertEqual(try JSONDecoder().decode(CompanionWidgetSnapshot.self, from: data), snap)
    }

    func testLifeLogEntryDecodesWithoutTimestamp() throws {
        // v16/v17 entries have no "at" — they must still decode.
        let legacy = """
        {"kindHash":123456789,"dayIndex":20800}
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(LifeLogEntry.self, from: legacy)
        XCTAssertEqual(entry.kindHash, 123456789)
        XCTAssertNil(entry.at)
    }

    // MARK: - Presence derivation

    func testPresencePriorityEventOverAwakeOverAsleep() {
        let seen = now.addingTimeInterval(-600)
        let event = now.addingTimeInterval(-300)
        XCTAssertEqual(CompanionStateDerivation.presence(now: now, lastSeen: seen, lastEventAt: event), .event)
        XCTAssertEqual(CompanionStateDerivation.presence(now: now, lastSeen: seen, lastEventAt: nil), .awake)
        XCTAssertEqual(CompanionStateDerivation.presence(now: now, lastSeen: nil, lastEventAt: nil), .asleep)
    }

    func testPresenceWindowsAreStrict() {
        let seen = now.addingTimeInterval(-CompanionStateDerivation.awakeWindowSec)
        XCTAssertEqual(CompanionStateDerivation.presence(now: now, lastSeen: seen, lastEventAt: nil), .asleep,
                       "exactly at the window edge the state has reverted")
        let seen2 = now.addingTimeInterval(-CompanionStateDerivation.awakeWindowSec + 1)
        XCTAssertEqual(CompanionStateDerivation.presence(now: now, lastSeen: seen2, lastEventAt: nil), .awake)
        let ev = now.addingTimeInterval(-CompanionStateDerivation.eventWindowSec)
        XCTAssertEqual(CompanionStateDerivation.presence(now: now, lastSeen: nil, lastEventAt: ev), .asleep)
        // Future timestamps never count (clock skew safety).
        XCTAssertEqual(CompanionStateDerivation.presence(now: now, lastSeen: now.addingTimeInterval(60), lastEventAt: nil), .asleep)
    }

    // MARK: - Copy table

    func testLineCopyForEveryStateAndKind() {
        XCTAssertEqual(CompanionStateDerivation.line(for: .asleep, lastEventKind: nil), "napping")
        XCTAssertEqual(CompanionStateDerivation.line(for: .awake, lastEventKind: nil), "awake")
        XCTAssertEqual(CompanionStateDerivation.line(for: .event, lastEventKind: .calendarSoon), "noticed your day")
        XCTAssertEqual(CompanionStateDerivation.line(for: .event, lastEventKind: .workoutDone), "celebrated your workout")
        XCTAssertEqual(CompanionStateDerivation.line(for: .event, lastEventKind: .sleptWithWatch), "slept beside you")
        XCTAssertEqual(CompanionStateDerivation.line(for: .event, lastEventKind: nil), "noticed something")
        for presence: CompanionPresence in [.asleep, .awake, .event] {
            for kind in LifeKind.allCases + [nil] {
                let line = CompanionStateDerivation.line(for: presence, lastEventKind: kind)
                XCTAssertFalse(line.isEmpty)
                XCTAssertLessThanOrEqual(line.split(separator: " ").count, 8, "house voice: <= 8 words")
                XCTAssertFalse(line.contains(kind?.rawValue ?? "x"), "no raw kind leaks into copy")
            }
        }
    }

    func testInlineAndRectangularLines() {
        XCTAssertEqual(
            CompanionStateDerivation.inlineLine(name: "Ember", presence: .asleep, lastEventKind: nil),
            "Ember · napping")
        XCTAssertEqual(
            CompanionStateDerivation.rectangularLine(dayCount: 23, presence: .event, lastEventKind: .workoutDone),
            "day 23 · celebrated your workout")
    }

    // MARK: - Timeline schedule (cap + expiry anchors)

    func testTimelineIncludesExpiryAnchorsAndIsCapped() {
        // Adversarial: built at 23:59:30 with both windows open.
        let late = now.addingTimeInterval(86_400 - 30)
        let dates = CompanionStateDerivation.timelineDates(
            now: late, lastSeen: late, lastEventAt: late, cap: 12, calendar: utc)
        XCTAssertLessThanOrEqual(dates.count, 12, "G9: hard cap under adversarial inputs")
        XCTAssertEqual(dates.first, late)
        XCTAssertTrue(dates.allSatisfy { $0 >= late })
        let sorted = dates.sorted()
        XCTAssertEqual(dates, sorted, "entries are chronological")
        XCTAssertTrue(dates.contains(late.addingTimeInterval(CompanionStateDerivation.awakeWindowSec)),
                      "the awake expiry is an anchor — never stale past the window")
        XCTAssertTrue(dates.contains(late.addingTimeInterval(CompanionStateDerivation.eventWindowSec)),
                      "the event expiry is an anchor")
    }

    func testTimelineCapHoldsWithNoWindows() {
        let dates = CompanionStateDerivation.timelineDates(now: now, cap: 12, calendar: utc)
        XCTAssertEqual(dates.count, 12)
        XCTAssertEqual(dates.first, now)
    }

    func testPresenceScheduleRevertsOnItsOwn() {
        // The face's schedule: awake now, asleep at the expiry anchor.
        let seen = now
        XCTAssertEqual(CompanionStateDerivation.presence(now: now, lastSeen: seen, lastEventAt: nil), .awake)
        XCTAssertEqual(
            CompanionStateDerivation.presence(now: seen.addingTimeInterval(CompanionStateDerivation.awakeWindowSec),
                                              lastSeen: seen, lastEventAt: nil),
            .asleep)
        let ev = now
        XCTAssertEqual(CompanionStateDerivation.presence(now: now, lastSeen: nil, lastEventAt: ev), .event)
        XCTAssertEqual(
            CompanionStateDerivation.presence(now: ev.addingTimeInterval(CompanionStateDerivation.eventWindowSec),
                                              lastSeen: nil, lastEventAt: ev),
            .asleep)
    }

    // MARK: - Kind-hash parity (app lifeLog <-> widget copy table)

    func testKindHashParityWithLifeSenseMapping() {
        XCTAssertEqual(LifeKind.hash(of: .calendarSoon),
                       LifeSenseMapping.kindHash(of: .calendarSoon(titleHash: 0)))
        XCTAssertEqual(LifeKind.hash(of: .workoutDone),
                       LifeSenseMapping.kindHash(of: .workoutDone(kindBand: 0, durationBand: 0)))
        XCTAssertEqual(LifeKind.hash(of: .sleptWithWatch),
                       LifeSenseMapping.kindHash(of: .sleptWithWatch))
        XCTAssertEqual(LifeKind.kind(forHash: LifeKind.hash(of: .workoutDone)), .workoutDone)
        XCTAssertNil(LifeKind.kind(forHash: 42))
    }

    // MARK: - Icon state variants

    func testIconStateVariantsRenderDistinctly() throws {
        for archetype in Archetype.allCases {
            let awake = CompanionIcon.snapshotBytes(for: archetype, state: .awake)
            let asleep = CompanionIcon.snapshotBytes(for: archetype, state: .asleep)
            let event = CompanionIcon.snapshotBytes(for: archetype, state: .event)
            XCTAssertEqual(awake.count, asleep.count)
            XCTAssertNotEqual(awake, asleep, "\(archetype.rawValue): asleep icon is the dim variant")
            // The event variant highlights accent cells — only visible when
            // the idle grid carries an accent cell (compass/prism do).
            let hasAccent = AuthoredSprites.sprite(for: archetype)
                .symbols(frameID: "idle").joined().contains("A")
            if hasAccent {
                XCTAssertNotEqual(awake, event, "\(archetype.rawValue): event icon highlights")
            } else {
                XCTAssertEqual(awake, event, "\(archetype.rawValue): no accent cells in idle")
            }
            // Asleep dims every non-transparent pixel (rest LOD factors).
            for i in stride(from: 0, to: awake.count, by: 4) where awake[i + 3] == 255 {
                XCTAssertLessThanOrEqual(asleep[i], awake[i])
                XCTAssertLessThanOrEqual(asleep[i + 1], awake[i + 1])
                XCTAssertLessThanOrEqual(asleep[i + 2], awake[i + 2])
            }
            XCTAssertNotNil(CompanionIcon.pngData(for: archetype, state: .asleep))
            XCTAssertNotNil(CompanionIcon.pngData(for: archetype, state: .awake))
            XCTAssertNotNil(CompanionIcon.pngData(for: archetype, state: .event))
        }
    }

    func testIconURLsArePerState() {
        let c = URL(fileURLWithPath: "/tmp/container")
        let asleep = CompanionWidgetState.iconURL(forArchetypeRaw: "ember", presence: .asleep, container: c)
        let awake = CompanionWidgetState.iconURL(forArchetypeRaw: "ember", presence: .awake, container: c)
        let plain = CompanionWidgetState.iconURL(forArchetypeRaw: "ember", container: c)
        XCTAssertNotEqual(asleep, awake)
        XCTAssertTrue(asleep?.path.hasSuffix("ember-asleep.png") == true)
        XCTAssertTrue(plain?.path.hasSuffix("ember.png") == true)
        XCTAssertEqual(CompanionWidgetState.iconURL(forArchetypeRaw: "ember", presence: nil, container: c), plain)
    }
}
