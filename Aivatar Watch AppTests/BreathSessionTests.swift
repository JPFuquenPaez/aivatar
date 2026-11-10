import XCTest
@testable import Aivatar_Watch_App

/// Aivatar 2.0 E8 — "Sit together": the pure breath-session plan, the
/// logging boundary, the daily cap, the director's session grammar
/// (suppression of every idle system, tap/crown/wrist-drop ending), and the
/// marker-haptic schedule. All deterministic, tick-injected.
final class BreathSessionTests: XCTestCase {

    // MARK: - Pure plan

    func testPlanMathFiveCyclesSixtySeconds() {
        let plan = BreathSessionController.plan()
        XCTAssertEqual(plan.count, 5)
        XCTAssertTrue(plan.allSatisfy { $0.inhaleTicks == 27 && $0.exhaleTicks == 53 })
        XCTAssertEqual(BreathSessionController.totalTicks, 400)
        XCTAssertEqual(BreathSessionController.totalDurationSec, 60.0, accuracy: 0.001)
        XCTAssertEqual(BreathSessionController.startMarkerTick, 0)
        XCTAssertEqual(BreathSessionController.endMarkerTick, 396)
    }

    func testFrameAlternation() {
        XCTAssertEqual(BreathSessionController.frame(atTick: 0), "breathe")
        XCTAssertEqual(BreathSessionController.frame(atTick: 26), "breathe")
        XCTAssertEqual(BreathSessionController.frame(atTick: 27), "idle")
        XCTAssertEqual(BreathSessionController.frame(atTick: 79), "idle")
        XCTAssertEqual(BreathSessionController.frame(atTick: 80), "breathe", "cycle wraps")
    }

    func testShouldLogBoundary() {
        XCTAssertFalse(BreathSessionController.shouldLog(elapsedTicks: 199))
        XCTAssertTrue(BreathSessionController.shouldLog(elapsedTicks: 200))
        XCTAssertTrue(BreathSessionController.shouldLog(elapsedTicks: 400))
    }

    func testDailyCapGate() {
        let now = Date(timeIntervalSince1970: 1_793_620_800)
        let day = CompanionMemoryStore.dayIndex(of: now)
        XCTAssertTrue(BreathSessionController.canLogToday(sitCountDay: nil, lastSitDay: nil, now: now))
        XCTAssertTrue(BreathSessionController.canLogToday(sitCountDay: 2, lastSitDay: day, now: now))
        XCTAssertFalse(BreathSessionController.canLogToday(sitCountDay: 3, lastSitDay: day, now: now))
        // A new day resets.
        XCTAssertTrue(BreathSessionController.canLogToday(sitCountDay: 3, lastSitDay: day - 1, now: now))
    }

    func testContentmentActPerArchetype() {
        XCTAssertEqual(BreathSessionController.contentmentAct(.willow), .slowBlink)
        XCTAssertEqual(BreathSessionController.contentmentAct(.ember), .happy)
        XCTAssertEqual(BreathSessionController.contentmentAct(.compass), .quirk)
        XCTAssertEqual(BreathSessionController.contentmentAct(.prism), .flick)
        XCTAssertEqual(BreathSessionController.contentmentAct(.nimbus), .perk)
    }

    // MARK: - Director session grammar

    /// Lock-guarded capture box for the @Sendable onSessionEnded callback.
    private final class EndBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = -1
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
        func set(_ v: Int) { lock.lock(); _value = v; lock.unlock() }
    }

    private func director(_ archetype: Archetype = .ember) throws -> SpriteDirector {
        let profile = try PersonalityProfile.load(archetype)
        return SpriteDirector(profile: profile, seed: 20261010)
    }

    func testSessionRunsExactly400TicksThenEnds() throws {
        let d = try director()
        let box = EndBox()
        d.onSessionEnded = { box.set($0) }
        d.setSessionMode(true)
        XCTAssertTrue(d.sessionMode)
        var sawBreathe = false, sawIdle = false
        for t in 1...400 {
            d.advance(toTick: t)
            if d.sessionMode {
                if d.currentFrame == "breathe" { sawBreathe = true }
                if d.currentFrame == "idle" { sawIdle = true }
            }
        }
        XCTAssertTrue(sawBreathe && sawIdle, "inhale/exhale alternation present")
        XCTAssertFalse(d.sessionMode, "session auto-ends at 400 ticks")
        XCTAssertEqual(box.value, 400)
        // Contentment act plays right after the end.
        XCTAssertNotEqual(d.currentFrame, "idle")
    }

    func testSessionSuppressesIdleSystems() throws {
        let d = try director(.nimbus)
        d.setSessionMode(true)
        var sawQuirk = false, sawGlance = false, sawFlick = false
        for t in 1...399 {
            d.advance(toTick: t)
            switch d.currentFrame {
            case "quirk": sawQuirk = true
            case "glanceL", "glanceR": sawGlance = true
            case "perk": sawFlick = true   // flick renders the 1-tick perk frame
            default: break
            }
            XCTAssertNil(d.moteCell, "no motes during a session")
        }
        XCTAssertFalse(sawQuirk || sawGlance || sawFlick, "breath is the only motion")
    }

    func testTapEndsSessionImmediatelyAndStillAnswers() throws {
        let d = try director()
        let box = EndBox()
        d.onSessionEnded = { box.set($0) }
        d.setSessionMode(true)
        for t in 1...50 { d.advance(toTick: t) }
        d.handleEvent(.tap)  // ends the session...
        XCTAssertFalse(d.sessionMode)
        XCTAssertEqual(box.value, 50, "tap ends the session at once (G1)")
        d.advance(toTick: 51)
        XCTAssertTrue(d.pendingActTicks > 0 || d.currentFrame != "idle", "...and the tap still answers")
    }

    func testShortSessionDoesNotLogButEnds() throws {
        let d = try director()
        let box = EndBox()
        d.onSessionEnded = { box.set($0) }
        d.setSessionMode(true)
        for t in 1...100 { d.advance(toTick: t) }
        d.handleEvent(.sleep)  // wrist drop
        XCTAssertEqual(box.value, 100)
        XCTAssertFalse(BreathSessionController.shouldLog(elapsedTicks: box.value))
    }

    func testBoopSuppressedDuringSession() throws {
        let d = try director()
        d.setSessionMode(true)
        for t in 1...10 { d.advance(toTick: t) }
        XCTAssertFalse(d.boopFace())
    }

    // MARK: - Memory v4 round-trip

    func testMemoryV4FieldsRoundTripAndLegacyDefaults() throws {
        var m = CompanionMemory(firstLaunch: Date(), lastSeen: Date())
        m.namingDay = Date(timeIntervalSince1970: 1_793_620_800)
        m.sitCountDay = 2
        m.lastSitDay = 20_000
        m.mindfulWriteDenied = true
        m.sixthRevealed = true
        m.crossedLevels = 0b11110
        let decoded = try JSONDecoder().decode(CompanionMemory.self, from: try JSONEncoder().encode(m))
        XCTAssertEqual(decoded.namingDay, m.namingDay)
        XCTAssertEqual(decoded.sitCountDay, 2)
        XCTAssertEqual(decoded.lastSitDay, 20_000)
        XCTAssertTrue(decoded.mindfulWriteDenied)
        XCTAssertTrue(decoded.sixthRevealed)
        XCTAssertEqual(decoded.crossedLevels, 0b11110)
        // Legacy payload (no v4 keys) decodes with defaults.
        let legacy = #"{"firstLaunch": 1793620800, "lastSeen": 1793620800, "bondXP": 5}"#.data(using: .utf8)!
        let old = try JSONDecoder().decode(CompanionMemory.self, from: legacy)
        XCTAssertNil(old.namingDay)
        XCTAssertNil(old.sitCountDay)
        XCTAssertFalse(old.mindfulWriteDenied)
        XCTAssertFalse(old.sixthRevealed)
        XCTAssertEqual(old.crossedLevels, 0)
    }
}
