import Foundation

/// BondRitual (Ambient Life spec F1 — ritual bonding, not feeding): the
/// micro-rituals that grow bond. Each is one gesture, ≤ 5 s, and every one
/// of them is an existing interaction made meaningful — no new UI, no meters.
nonisolated enum BondRitual: String, Sendable, CaseIterable {
    /// The long-press slow blink — the signature core mechanic (trust exchange).
    case slowBlink
    /// The day's first greeting (first touch after a wake/day change).
    case firstGreetingOfDay
    /// The wrist-drop farewell, acknowledged when seen in full (once per session).
    case farewellAcknowledged
    /// The naming ceremony — one-time, large grant (gated shell-side).
    case namingCeremony
    /// Simply opening the app once a day — visiting is enough.
    case dailyPresence
}

/// The result of awarding a ritual — pure, testable, announcable.
nonisolated struct BondAward: Sendable, Equatable {
    var xpGained: Int
    var newXP: Int
    var previousLevel: Int
    var newLevel: Int
    /// True exactly when this award crossed a level threshold (the moment
    /// VoiceOver announces and the bond haptic plays).
    var leveledUp: Bool { newLevel > previousLevel }
}

/// BondRules (F1): the pure progression brain. A pure function of
/// (memory, ritual, now) — same shape as `recordVisit`, deterministic under
/// injected dates. G4 (no guilt) is structural here: bond is MONOTONIC,
/// there is no decay path at all — absence never reduces anything.
nonisolated enum BondRules {
    /// "Confidant" — the ceiling. Levels are felt, not read (no numbers UI).
    static let maxLevel = 5
    /// XP needed to reach each level: index 0 -> level 1 (day 1, 0 XP).
    static let levelThresholds: [Int] = [0, 10, 30, 60, 100]

    /// Ritual -> XP. Deliberately small numbers: bond grows over days of
    /// rituals, not minutes of grinding.
    static func xp(for ritual: BondRitual) -> Int {
        switch ritual {
        case .slowBlink: return 4
        case .firstGreetingOfDay: return 3
        case .farewellAcknowledged: return 2
        case .namingCeremony: return 25
        case .dailyPresence: return 5
        }
    }

    /// Derived bond level from XP (1...maxLevel, monotonic by construction).
    static func level(forXP xp: Int) -> Int {
        let raw = levelThresholds.filter { xp >= $0 }.count
        return min(max(raw, 1), maxLevel)
    }

    /// Awards a ritual to the memory. Once-per-day rituals are gated by
    /// day index (deterministic under injected `now`); the once-per-session
    /// and one-time rituals are gated shell-side (session flag /
    /// namingCompleted), so the rule itself always awards them.
    @discardableResult
    static func award(_ memory: inout CompanionMemory, _ ritual: BondRitual,
                      now: Date = Date(), calendar: Calendar = .current) -> BondAward {
        let dayIndex = CompanionMemoryStore.dayIndex(of: now, calendar: calendar)
        var gained = xp(for: ritual)
        switch ritual {
        case .dailyPresence:
            if memory.lastPresenceDay == dayIndex { gained = 0 }
            memory.lastPresenceDay = dayIndex
        case .firstGreetingOfDay:
            if memory.lastGreetingDay == dayIndex { gained = 0 }
            memory.lastGreetingDay = dayIndex
        case .slowBlink, .farewellAcknowledged, .namingCeremony:
            break
        }
        let previousLevel = level(forXP: memory.bondXP)
        memory.bondXP += gained
        let newLevel = level(forXP: memory.bondXP)
        return BondAward(xpGained: gained, newXP: memory.bondXP,
                         previousLevel: previousLevel, newLevel: newLevel)
    }

    // MARK: - What bond unlocks (consumed by SpriteDirector / the stage)

    /// The quirk loop's rate multiplier — level 1: the quirk loop is
    /// visible; level 2+: the owner-exclusive signature joins the rotation
    /// (in the sprite vocabulary the quirk frame IS the signature, so the
    /// unlock reads as its frequency rising).
    static func quirkRateMultiplier(_ level: Int) -> Float {
        min(1.0 + 0.5 * Float(level - 1), 3.0)
    }

    /// Gaze bias toward the user (level 3+ per spec): a bonded companion
    /// glances away less — it looks at you more.
    static func glanceAwayMultiplier(_ level: Int) -> Float {
        max(1.0 - 0.15 * Float(level - 1), 0.25)
    }

    /// Level 4+: the farewell gesture gains a signature beat — the goodbye
    /// bloom holds longer before the sleepy frame.
    static func farewellBloomTicks(_ level: Int) -> Int {
        level >= 4 ? 18 : 12
    }

    /// v31: bond level 3+ earns an occasional idle slow-blink directed at the
    /// user (per minute, on the 150 ms clock) — a positive "looks at you"
    /// beat to complement the reduced glance-away. Zero below level 3.
    static func lookAtYouPerMin(_ level: Int) -> Float {
        level >= 3 ? 0.1 : 0
    }

    /// Level 5 ("confidant"): the companion keeps a small pixel memento of
    /// the naming day (interiority trace on the sprite grid).
    static func isConfidant(_ level: Int) -> Bool { level >= maxLevel }
}
