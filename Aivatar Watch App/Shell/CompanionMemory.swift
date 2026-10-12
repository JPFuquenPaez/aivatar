import Foundation

/// CompanionMemory (A5d — interiority, §1: what the character does when
/// nobody is watching). The persistent, per-companion life record that
/// unobserved behavior leaves behind: app age, streaks, the sprout's
/// growth, the rehearsal's progress, the day's found trinket, and the
/// learned rhythm of your returns.
///
/// Determinism contract: the engine NEVER reads the wall clock — memory
/// is loaded at context build and handed in as an input (like the seed).
/// All growth logic here is a pure function of (previous state, now).
nonisolated struct CompanionMemory: Codable, Equatable, Sendable {
    /// First launch — app age (Ember's rehearsal pool grows with it).
    var firstLaunch: Date
    /// Last time the app was opened.
    var lastSeen: Date
    /// Total opens.
    var sessions: Int = 0
    /// Consecutive days with a visit (Compass's audit artifact).
    var streakDays: Int = 0
    /// Attended days accumulated (Willow's sprout grows toward maturity).
    var sproutDays: Double = 0
    /// Rehearsal practice level 0...5 (grows with sessions).
    var rehearsalLevel: Int = 0
    /// Calendar day index of the last found trinket (Prism).
    var trinketDay: Int = -1
    /// Nimbus's barometer: rolling mean of the hour-of-day you return.
    var usualHourEMA: Double?

    init(firstLaunch: Date = Date(), lastSeen: Date = Date()) {
        self.firstLaunch = firstLaunch
        self.lastSeen = lastSeen
    }
}

/// What a visit tells the companion — computed once per app open and
/// consumed by the stage (presentation) and the painter (traces).
nonisolated struct VisitSummary: Sendable {
    /// Whole calendar days since the last visit.
    var absenceDays: Int
    /// Compass: the streak the audit artifact shows.
    var streakDays: Int
    /// Willow: sprout maturity 0.2 ... 1.0+ (painter tuning input).
    var sproutGrowth: Float
    /// Ember: rehearsal level 0...5.
    var rehearsalLevel: Int
    /// Prism: does it have a fresh trinket to present?
    var trinketPresent: Bool
    /// Nimbus: is "now" within an hour of the learned usual return time?
    var nearUsualHour: Bool
    /// Interiority tuning for the painter (persistent traces).
    var tuning: InteriorityTuning {
        InteriorityTuning(sproutGrowth: sproutGrowth, streakDays: streakDays, trinketPresent: trinketPresent)
    }
}

/// Loads and records CompanionMemory in UserDefaults. Test-isolated via
/// a suite name; production uses the standard app defaults.
nonisolated final class CompanionMemoryStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let key = "companionMemory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CompanionMemory? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(CompanionMemory.self, from: data)
    }

    func save(_ memory: CompanionMemory) {
        if let data = try? JSONEncoder().encode(memory) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// Calendar-day distance between dates (0 = same day, 1 = yesterday).
    static func dayDistance(from: Date, to: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    /// Records this visit and computes what the companion has been doing
    /// while you were away. Pure function of (memory, now) — deterministic
    /// under test with injected dates.
    @discardableResult
    func recordVisit(now: Date = Date(), calendar: Calendar = .current) -> VisitSummary {
        var memory = load() ?? CompanionMemory(firstLaunch: now, lastSeen: now)
        let absence = Self.dayDistance(from: memory.lastSeen, to: now, calendar: calendar)

        // Streak (Compass): same day keeps it, yesterday extends it, a gap
        // resets it — and the reset is an invitation, never an accusation
        // (the artifact simply shows today as day 1).
        if absence <= 0 {
            // same-day re-open: streak unchanged
        } else if absence == 1 {
            memory.streakDays += 1
        } else {
            memory.streakDays = 1
        }
        if memory.streakDays == 0 { memory.streakDays = 1 }

        // Sprout (Willow): it kept watering while you were away — the
        // sprout grows with every attended day, absence included, capped
        // at ~3 weeks to maturity.
        memory.sproutDays += Double(max(0, absence))
        memory.sessions += 1

        // Rehearsal (Ember): the practiced dance improves with practice
        // (sessions), capped at 5.
        memory.rehearsalLevel = min(5, memory.sessions / 8)

        // Trinket (Prism): a fresh find per day of absence — the same day
        // twice is never the same event to Prism.
        let dayIndex = calendar.startOfDay(for: now).timeIntervalSince1970 / 86_400
        let trinketPresent = absence >= 1 && Int(dayIndex) != memory.trinketDay
        if trinketPresent {
            memory.trinketDay = Int(dayIndex)
        }

        // Barometer (Nimbus): EMA of the return hour — it learns the
        // rhythm of your routine without ever being told.
        let hour = Double(calendar.component(.hour, from: now))
            + Double(calendar.component(.minute, from: now)) / 60
        if let usual = memory.usualHourEMA {
            memory.usualHourEMA = usual + (hour - usual) * 0.3
        } else {
            memory.usualHourEMA = hour
        }
        let nearUsualHour = abs(hour - (memory.usualHourEMA ?? hour)) <= 1.0

        memory.lastSeen = now
        save(memory)

        let growth = Float(0.2 + 0.8 * min(1, memory.sproutDays / 21))
        return VisitSummary(
            absenceDays: max(0, absence),
            streakDays: memory.streakDays,
            sproutGrowth: growth,
            rehearsalLevel: memory.rehearsalLevel,
            trinketPresent: trinketPresent,
            nearUsualHour: nearUsualHour
        )
    }
}
