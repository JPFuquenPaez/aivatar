import XCTest
@testable import Aivatar_Watch_App

/// v17 F2 "Ambient Life Sense" suite: the pure bridge cores (calendar
/// window + daily cap, workout/sleep banding, hash-only payloads), the
/// director's reaction grammar (one per wake, 10-min per-kind cooldown,
/// L2/rest behavior, determinism), and the privacy contract — no event
/// content ever crosses into a payload or the lifeLog.
final class LifeSenseTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_793_620_800)  // 2026-11-03 12:00 UTC
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func director(_ archetype: Archetype, seed: UInt64 = 20261107) throws -> SpriteDirector {
        SpriteDirector(profile: try PersonalityProfile.load(archetype), seed: seed)
    }

    // MARK: - Hashing & privacy

    func testHashIsStable() {
        XCTAssertEqual(LifeSenseMapping.hash("standup"), LifeSenseMapping.hash("standup"))
        XCTAssertNotEqual(LifeSenseMapping.hash("standup"), LifeSenseMapping.hash("1:1"))
        XCTAssertNotEqual(LifeSenseMapping.hash("standup"), LifeSenseMapping.hash("Standup"))
    }

    func testLifeEventPayloadsCarryNoContent() {
        // The payload types are Int hashes/bands by construction — assert the
        // calendar event equals another with the same hash regardless of title.
        let a = LifeEvent.calendarSoon(titleHash: LifeSenseMapping.hash("dentist"))
        let b = LifeEvent.calendarSoon(titleHash: LifeSenseMapping.hash("dentist"))
        let c = LifeEvent.calendarSoon(titleHash: LifeSenseMapping.hash("lunch"))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        if case .calendarSoon(let h) = a { XCTAssertEqual(h, LifeSenseMapping.hash("dentist")) }
    }

    // MARK: - Calendar pure core

    func testCalendarWindowAndOrdering() {
        let items = [
            LifeSenseMapping.CalendarItem(title: "late", start: base.addingTimeInterval(2 * 3_600)),   // outside window
            LifeSenseMapping.CalendarItem(title: "soon2", start: base.addingTimeInterval(9 * 60)),
            LifeSenseMapping.CalendarItem(title: "soon1", start: base.addingTimeInterval(4 * 60)),
            LifeSenseMapping.CalendarItem(title: "past", start: base.addingTimeInterval(-60)),         // already started
        ]
        let events = LifeSenseMapping.calendarEvents(items, now: base, notifiedToday: 0)
        XCTAssertEqual(events.count, 2, "only events starting within 10 min, not yet started")
        XCTAssertEqual(events[0], .calendarSoon(titleHash: LifeSenseMapping.hash("soon1")), "soonest first")
        XCTAssertEqual(events[1], .calendarSoon(titleHash: LifeSenseMapping.hash("soon2")))
    }

    func testCalendarDailyCapRespected() {
        let items = (0..<6).map {
            LifeSenseMapping.CalendarItem(title: "e\($0)", start: base.addingTimeInterval(Double($0 + 1) * 60))
        }
        XCTAssertEqual(LifeSenseMapping.calendarEvents(items, now: base, notifiedToday: 0).count, 3)
        XCTAssertEqual(LifeSenseMapping.calendarEvents(items, now: base, notifiedToday: 2).count, 1)
        XCTAssertEqual(LifeSenseMapping.calendarEvents(items, now: base, notifiedToday: 3).count, 0, "cap spent -> nothing")
        XCTAssertEqual(LifeSenseMapping.calendarEvents(items, now: base, notifiedToday: 9).count, 0)
    }

    func testNotifiedTodayCountsOnlyTodaysKind() {
        let day = CompanionMemoryStore.dayIndex(of: base, calendar: utc)
        let log = [
            LifeLogEntry(kindHash: LifeSenseMapping.kindHash(of: .calendarSoon(titleHash: 1)), dayIndex: day),
            LifeLogEntry(kindHash: LifeSenseMapping.kindHash(of: .calendarSoon(titleHash: 2)), dayIndex: day),
            LifeLogEntry(kindHash: LifeSenseMapping.kindHash(of: .calendarSoon(titleHash: 3)), dayIndex: day - 1),  // yesterday
            LifeLogEntry(kindHash: LifeSenseMapping.kindHash(of: .workoutDone(kindBand: 1, durationBand: 2)), dayIndex: day),
        ]
        XCTAssertEqual(LifeSenseMapping.notifiedToday(log, kind: .calendarSoon(titleHash: 0), dayIndex: day), 2)
        XCTAssertEqual(LifeSenseMapping.notifiedToday(log, kind: .workoutDone(kindBand: 0, durationBand: 0), dayIndex: day), 1)
    }

    // MARK: - Health pure core

    func testWorkoutBanding() {
        let run = LifeSenseMapping.workoutDoneEvent(.init(activityRaw: 37, durationSec: 1_800))
        guard case .workoutDone(let kindBand, let durationBand) = run else {
            return XCTFail("expected workoutDone")
        }
        XCTAssertEqual(kindBand, 37 & 0xF, "kind band, not the raw type")
        XCTAssertEqual(durationBand, 3, "30 min = band 3 (10-min buckets)")
        let long = LifeSenseMapping.workoutDoneEvent(.init(activityRaw: 1, durationSec: 9_000))
        guard case .workoutDone(_, let band) = long else { return XCTFail() }
        XCTAssertEqual(band, 5, "bands cap at 5")
        let short = LifeSenseMapping.workoutDoneEvent(.init(activityRaw: 1, durationSec: 120))
        guard case .workoutDone(_, let band) = short else { return XCTFail() }
        XCTAssertEqual(band, 0)
    }

    func testSleepEvent() {
        XCTAssertEqual(LifeSenseMapping.sleepEvent(sleptWithWatch: true), [.sleptWithWatch])
        XCTAssertEqual(LifeSenseMapping.sleepEvent(sleptWithWatch: false), [])
    }

    func testNullLifeSenseSourceIsDormant() {
        XCTAssertEqual(NullLifeSenseSource().poll(now: base), [], "no consent -> nothing, ever")
    }

    // MARK: - Reaction mapping parity

    func testEveryF2KindHasAnAnswerForEveryArchetype() {
        let kinds: [LifeEvent] = [
            .calendarSoon(titleHash: 1),
            .workoutDone(kindBand: 2, durationBand: 3),
            .sleptWithWatch,
        ]
        for archetype in Archetype.allCases {
            for event in kinds {
                XCTAssertNotNil(SpriteDirector.reactionAct(for: event, archetype: archetype),
                                "\(archetype.rawValue) answers \(SpriteDirector.kind(of: event))")
            }
        }
        // F3/F6 kinds are parked until their phases.
        for archetype in Archetype.allCases {
            XCTAssertNil(SpriteDirector.reactionAct(for: .weatherClass(classHash: 1), archetype: archetype))
            XCTAssertNil(SpriteDirector.reactionAct(for: .workoutLive(paceBand: 1), archetype: archetype))
        }
    }

    func testCalendarReactionIsPerArchetype() {
        XCTAssertEqual(SpriteDirector.reactionAct(for: .calendarSoon(titleHash: 1), archetype: .nimbus), .perk)
        XCTAssertEqual(SpriteDirector.reactionAct(for: .calendarSoon(titleHash: 1), archetype: .willow), .slowBlink)
        XCTAssertEqual(SpriteDirector.reactionAct(for: .calendarSoon(titleHash: 1), archetype: .compass), .quirk)
        XCTAssertEqual(SpriteDirector.reactionAct(for: .sleptWithWatch, archetype: .ember), .slowBlink)
    }

    // MARK: - Director behavior

    func testLifeEventPlaysOncePerWakeAndWakeResets() throws {
        let d = try director(.ember)
        d.handleLifeEvent(.calendarSoon(titleHash: 1))
        XCTAssertEqual(d.lifeEventCount, 1)
        d.advance(toTick: d.tick + 5)
        d.handleLifeEvent(.workoutDone(kindBand: 1, durationBand: 2))
        XCTAssertEqual(d.lifeEventCount, 1, "max one life reaction per wake")
        d.handleEvent(.wake)
        d.handleLifeEvent(.workoutDone(kindBand: 1, durationBand: 2))
        XCTAssertEqual(d.lifeEventCount, 2, "the next wake may react again")
    }

    func testLifeEventCooldownIsPerKind() throws {
        let d = try director(.willow)
        d.handleEvent(.wake)
        d.handleLifeEvent(.calendarSoon(titleHash: 1))
        d.handleEvent(.wake)  // new wake, but same kind within 10 min
        d.handleLifeEvent(.calendarSoon(titleHash: 2))
        XCTAssertEqual(d.lifeEventCount, 1, "same kind inside 10 min is swallowed")
        d.handleEvent(.wake)
        d.advance(toTick: d.tick + SpriteDirector.lifeEventCooldownTicks + 1)
        d.handleLifeEvent(.calendarSoon(titleHash: 3))
        XCTAssertEqual(d.lifeEventCount, 2, "after the cooldown the kind may fire again")
        d.handleEvent(.wake)
        d.handleLifeEvent(.sleptWithWatch)
        XCTAssertEqual(d.lifeEventCount, 3, "a different kind is not blocked by the calendar cooldown")
    }

    func testLifeEventIgnoredWhileRestingAndDegradedUnderL2() throws {
        let d = try director(.compass)
        d.setResting(true)
        d.handleLifeEvent(.workoutDone(kindBand: 1, durationBand: 1))
        XCTAssertEqual(d.lifeEventCount, 0, "no reactions in the Always On rest state")
        d.setResting(false)
        d.accessibilityMode = .reduceMotionL2
        d.handleLifeEvent(.calendarSoon(titleHash: 1))
        XCTAssertEqual(d.lifeEventCount, 1, "L2 still counts the event (it happened)")
        var seq: [String] = []
        for _ in 0..<4 { d.advance(toTick: d.tick + 1); seq.append(d.currentFrame) }
        XCTAssertTrue(seq.contains("blink"), "L2 reaction is face-readable only")
        XCTAssertFalse(seq.contains("quirk") || seq.contains("happy"), "L2 never plays body acts for life events")
    }

    func testLifeEventIsDeterministicPerSeed() throws {
        func run() throws -> [String] {
            let d = try director(.prism)
            var seq: [String] = []
            d.handleLifeEvent(.calendarSoon(titleHash: 42))
            for _ in 0..<40 { d.advance(toTick: d.tick + 1); seq.append(d.currentFrame) }
            return seq
        }
        XCTAssertEqual(try run(), try run())
    }
}
