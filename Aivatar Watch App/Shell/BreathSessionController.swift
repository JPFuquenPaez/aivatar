import Foundation

/// BreathSessionController (Aivatar 2.0, E8 "Sit together"): the PURE core of
/// the mindful minute — no framework imports, tick-injectable, zero RNG (G7
/// trivial). One cycle = inhale 27 ticks (the `breathe` frame held) + exhale
/// 53 ticks (idle settle); 5 cycles = 400 ticks = 60.0 s exactly at the
/// 150 ms director clock. Marker haptics at tick 0 (.click) and tick 396
/// (.success) — exactly 2 haptics per session, inside all global caps.
/// A session logs only if it ran >= 200 ticks (30 s).
nonisolated enum BreathSessionController {
    static let inhaleTicks = 27
    static let exhaleTicks = 53
    static let cycleTicks = 80
    static let cycleCount = 5
    /// 5 x 80 = 400 ticks = 60.0 s exactly.
    static let totalTicks = 400
    /// Minimum elapsed for the session to log: 200 ticks = 30 s.
    static let logMinTicks = 200
    /// Haptic marker ticks: session start and the final exhale.
    static let startMarkerTick = 0
    static let endMarkerTick = 396

    nonisolated struct BreathCycle: Sendable, Equatable {
        var inhaleTicks: Int
        var exhaleTicks: Int
    }

    /// The fixed 5-cycle plan (pure).
    static func plan() -> [BreathCycle] {
        Array(repeating: BreathCycle(inhaleTicks: inhaleTicks, exhaleTicks: exhaleTicks), count: cycleCount)
    }

    /// Total duration in seconds (60.0).
    static var totalDurationSec: Double { Double(totalTicks) * SpriteDirector.tickDuration }

    /// The stage frame for a session tick: inhale holds `breathe`, exhale
    /// settles on `idle`.
    static func frame(atTick t: Int) -> String {
        (t % cycleTicks) < inhaleTicks ? "breathe" : "idle"
    }

    /// Whether an elapsed session is long enough to log (>= 30 s).
    static func shouldLog(elapsedTicks: Int) -> Bool { elapsedTicks >= logMinTicks }

    /// The contentment act each archetype performs when the session ends
    /// (all existing sprite acts — no new frames).
    static func contentmentAct(_ archetype: Archetype) -> SpriteDirector.SpriteAct {
        switch archetype {
        case .willow: return .slowBlink   // the listening blink
        case .ember: return .happy         // happy squint
        case .compass: return .quirk       // the metronome settle
        case .prism: return .flick         // flicker-off
        case .nimbus: return .perk         // settle-fluff
        }
    }

    /// The per-session cap: at most 3 logged sessions per calendar day
    /// (content-free day-index counting from memory; never stated to the user).
    static func canLogToday(sitCountDay: Int?, lastSitDay: Int?, now: Date,
                            calendar: Calendar = .current, cap: Int = 3) -> Bool {
        let day = CompanionMemoryStore.dayIndex(of: now, calendar: calendar)
        if lastSitDay == day { return (sitCountDay ?? 0) < cap }
        return true
    }
}
