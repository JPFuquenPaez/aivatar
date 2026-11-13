import XCTest
@testable import Aivatar_Watch_App

/// v19 F5 "morning life beats" suite: the pure beat selector (priority,
/// once-per-day gate, lookback), the caption table (<= 8 words), the act
/// mapping, and the director's playSequence (order, duration budget, skip,
/// L2 flattening, determinism).
final class WakeBeatTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_793_620_800)  // 2026-11-03 12:00 UTC
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }
    private var dayIndex: Int { CompanionMemoryStore.dayIndex(of: now, calendar: utc) }

    private func memory() -> CompanionMemory {
        CompanionMemory(firstLaunch: now.addingTimeInterval(-30 * 86_400), lastSeen: now)
    }

    private func director(_ archetype: Archetype, seed: UInt64 = 20261109) throws -> SpriteDirector {
        SpriteDirector(profile: try PersonalityProfile.load(archetype), seed: seed)
    }

    // MARK: - Selector priority

    func testPriorityLifeEventOverWeatherOverMemoryOverWarm() {
        var m = memory()
        // Nothing yet: warm.
        XCTAssertEqual(WakeBeatSelector.beat(memory: m, archetype: .compass, now: now, calendar: utc), .warm)
        // A memory trace appears.
        m.streakDays = 5
        XCTAssertEqual(WakeBeatSelector.beat(memory: m, archetype: .compass, now: now, calendar: utc),
                       .memory(.weekGrid))
        // Weather outranks memory.
        m.lifeLog = [LifeLogEntry(kindHash: LifeKind.hash(of: .weatherClass), dayIndex: dayIndex,
                                  at: now.addingTimeInterval(-3600), classHash: ConditionClass.gray.hash)]
        XCTAssertEqual(WakeBeatSelector.beat(memory: m, archetype: .compass, now: now, calendar: utc), .weather(.gray))
        // A life event outranks weather.
        m.lifeLog.append(LifeLogEntry(kindHash: LifeKind.hash(of: .workoutDone), dayIndex: dayIndex,
                                      at: now.addingTimeInterval(-600)))
        XCTAssertEqual(WakeBeatSelector.beat(memory: m, archetype: .compass, now: now, calendar: utc),
                       .lifeEvent(kind: .workoutDone))
    }

    func testOncePerDayGate() {
        var m = memory()
        m.streakDays = 3
        XCTAssertNotNil(WakeBeatSelector.beat(memory: m, archetype: .compass, now: now, calendar: utc))
        WakeBeatSelector.markShown(&m, now: now, calendar: utc)
        XCTAssertEqual(m.lastBeatDay, dayIndex)
        XCTAssertNil(WakeBeatSelector.beat(memory: m, archetype: .compass, now: now, calendar: utc),
                     "same-day reopen gets the short wake only — no replay nagging")
        XCTAssertNotNil(WakeBeatSelector.beat(memory: m, archetype: .compass,
                                              now: now.addingTimeInterval(86_400), calendar: utc))
    }

    func testLifeEventLookbackIs18h() {
        var m = memory()
        m.lifeLog = [LifeLogEntry(kindHash: LifeKind.hash(of: .sleptWithWatch), dayIndex: dayIndex - 1,
                                  at: now.addingTimeInterval(-17 * 3_600))]
        XCTAssertEqual(WakeBeatSelector.beat(memory: m, archetype: .ember, now: now, calendar: utc),
                       .lifeEvent(kind: .sleptWithWatch), "last evening's sleep still greets")
        m.lifeLog[0].at = now.addingTimeInterval(-19 * 3_600)
        XCTAssertEqual(WakeBeatSelector.beat(memory: m, archetype: .ember, now: now, calendar: utc), .warm,
                       "older than 18 h is no longer a beat")
    }

    func testWeatherBeatNeedsTodaysKnownClass() {
        var m = memory()
        m.lifeLog = [LifeLogEntry(kindHash: LifeKind.hash(of: .weatherClass), dayIndex: dayIndex - 1,
                                  at: now.addingTimeInterval(-86_400), classHash: ConditionClass.rain.hash)]
        XCTAssertNotEqual(WakeBeatSelector.beat(memory: m, archetype: .ember, now: now, calendar: utc), .weather(.rain),
                          "yesterday's weather is not today's beat")
        m.lifeLog = [LifeLogEntry(kindHash: LifeKind.hash(of: .weatherClass), dayIndex: dayIndex,
                                  at: now, classHash: ConditionClass.unknown.hash)]
        XCTAssertNotEqual(WakeBeatSelector.beat(memory: m, archetype: .ember, now: now, calendar: utc), .weather(.unknown),
                          "unknown weather stays neutral")
    }

    func testPerArchetypeMemoryBeats() {
        var m = memory()
        m.rehearsalLevel = 2
        XCTAssertEqual(WakeBeatSelector.beat(memory: m, archetype: .ember, now: now, calendar: utc), .memory(.rehearsal))
        m = memory(); m.sproutDays = 5
        XCTAssertEqual(WakeBeatSelector.beat(memory: m, archetype: .willow, now: now, calendar: utc), .memory(.sprout))
        m = memory(); m.streakDays = 4
        XCTAssertEqual(WakeBeatSelector.beat(memory: m, archetype: .compass, now: now, calendar: utc), .memory(.weekGrid))
        m = memory(); m.trinketDay = dayIndex
        XCTAssertEqual(WakeBeatSelector.beat(memory: m, archetype: .prism, now: now, calendar: utc), .memory(.trinket))
        m = memory(); m.usualHourEMA = 12.0  // now is 12:00 UTC
        XCTAssertEqual(WakeBeatSelector.beat(memory: m, archetype: .nimbus, now: now, calendar: utc), .memory(.barometer))
    }

    // MARK: - Captions

    func testCaptionsAreShortAndNeverRaw() throws {
        XCTAssertNil(WakeBeatCaption.text(for: .warm, name: "Ember"))
        let beats: [WakeBeat] = [
            .lifeEvent(kind: .calendarSoon), .lifeEvent(kind: .workoutDone),
            .weather(.sunny), .weather(.gray), .weather(.rain), .weather(.wind),
            .weather(.cold), .weather(.hot),
            .memory(.rehearsal), .memory(.sprout), .memory(.weekGrid),
            .memory(.trinket), .memory(.barometer),
        ]
        for beat in beats {
            let text = try XCTUnwrap(WakeBeatCaption.text(for: beat, name: "Ember"))
            XCTAssertLessThanOrEqual(text.split(separator: " ").count, 8, "\(beat): <= 8 words")
            XCTAssertTrue(text.hasPrefix("Ember"), "the companion speaks in first person-ish house voice")
            XCTAssertFalse(text.contains("workoutDone") || text.contains("calendarSoon"), "no raw kinds")
        }
        XCTAssertNil(WakeBeatCaption.text(for: .weather(.unknown), name: "Ember"))
        XCTAssertNil(WakeBeatCaption.text(for: .lifeEvent(kind: .weatherClass), name: "Ember"))
    }

    // MARK: - Acts & director sequence

    func testActsNonEmptyForEveryBeat() {
        for archetype in Archetype.allCases {
            for beat in [WakeBeat.warm, .lifeEvent(kind: .workoutDone), .weather(.rain),
                         .memory(.rehearsal), .memory(.sprout), .memory(.weekGrid),
                         .memory(.trinket), .memory(.barometer)] {
                XCTAssertFalse(WakeBeatSelector.acts(for: beat, archetype: archetype).isEmpty,
                               "\(archetype.rawValue) \(beat)")
            }
        }
    }

    func testPlaySequencePlaysActsInOrderWithinBudget() throws {
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            let acts = WakeBeatSelector.acts(for: .memory(.rehearsal), archetype: archetype)
            d.playSequence(acts)
            // Duration budget: the whole queued beat is <= 5 s (G1).
            XCTAssertLessThanOrEqual(Double(d.pendingActTicks) * SpriteDirector.tickDuration, 5.0,
                                     "\(archetype.rawValue): beat <= 5 s")
            // The first act leads the sequence (a quirk winds up with perk
            // when the profile's anticipation is nonzero — v28; willow's zero
            // anticipation leads with the quirk itself). Read the queued head
            // BEFORE advancing: event-queued frames are drained by the next
            // step, same as the live renderer.
            let profile = try PersonalityProfile.load(archetype)
            let windup = SpriteDirector.perkWindupTicks(anticipation: profile.motionGrammar?.anticipation ?? 0)
            let expectedFirst = acts.first.map { a -> String in
                switch a {
                case .quirk: return windup > 0 ? "perk" : "quirk"
                case .happy: return "happy"
                case .slowBlink: return "idle"
                case .look: return "glanceR"
                case .perk: return "perk"
                case .flick: return "perk"   // the 1-tick idle micro-flick renders the perk frame
                case .blink, .farewell: return "idle"
                }
            }
            XCTAssertEqual(d.currentFrame, expectedFirst, "\(archetype.rawValue): the beat's act leads")
            // v28: the wind-up holds up to 2 ticks — advance until the frame
            // actually turns over (bounded).
            var advanced = false
            for _ in 0..<4 {
                d.advance(toTick: d.tick + 1)
                if d.currentFrame != expectedFirst { advanced = true; break }
            }
            XCTAssertTrue(advanced, "\(archetype.rawValue): the sequence advances")
        }
    }

    func testBeatIsSkippableByOneTap() throws {
        let d = try director(.ember)
        d.playSequence([.quirk, .happy])
        d.advance(toTick: d.tick + 2)
        d.handleEvent(.tap)  // any input cuts to the stage
        XCTAssertEqual(d.currentFrame, "happy", "a tap replaces the beat queue immediately (<= 150 ms)")
    }

    func testBeatDegradesUnderL2() throws {
        let d = try director(.willow)
        d.accessibilityMode = .reduceMotionL2
        d.playSequence([.quirk, .slowBlink])
        var seq: [String] = []
        for _ in 0..<30 { d.advance(toTick: d.tick + 1); seq.append(d.currentFrame) }
        XCTAssertTrue(seq.allSatisfy { $0 == "idle" || $0 == "blink" },
                      "L2: the beat flattens to face-only frames (caption still shows in the shell)")
    }

    func testSequenceDeterministicPerSeed() throws {
        func run() throws -> [String] {
            let d = try director(.prism)
            d.playSequence(WakeBeatSelector.acts(for: .memory(.trinket), archetype: .prism))
            var s: [String] = []
            for _ in 0..<40 { d.advance(toTick: d.tick + 1); s.append(d.currentFrame) }
            return s
        }
        XCTAssertEqual(try run(), try run())
    }

    // MARK: - Memory decode

    func testLegacyMemoryDecodesWithoutBeatDay() throws {
        let legacy = """
        {"firstLaunch":1793620800,"lastSeen":1793620800,"sessions":2,"streakDays":1,
         "sproutDays":0,"rehearsalLevel":0,"trinketDay":-1,"usualHourEMA":null,
         "bondXP":0,"lifeLog":[],"lastPresenceDay":-1,"lastGreetingDay":-1}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(CompanionMemory.self, from: legacy)
        XCTAssertEqual(m.lastBeatDay, -1)
    }
}
