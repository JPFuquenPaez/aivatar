import Foundation

/// WakeBeat (v19, Ambient Life F5): the morning "life beat" — the first
/// visit of a day is greeted by someone who was there. The selector is a
/// PURE function of (memory, archetype, now) — deterministic under injected
/// dates, one beat per day (nil = the short wake only).
///
/// Priority (spec F5): life event > weather line > memory beat > warm.
nonisolated enum WakeBeat: Equatable, Sendable {
    /// A real-life event within the lookback (workout, calendar, sleep).
    case lifeEvent(kind: LifeKind)
    /// Aivatar 2.0 E4: today is the naming-day anniversary (years since).
    case namingAnniversary(years: Int)
    /// Today's weather class (ambience, never a forecast).
    case weather(ConditionClass)
    /// The companion's own unobserved trace (per archetype).
    case memory(MemoryBeat)
    /// Plain warm greeting (no caption).
    case warm
}

/// The per-archetype memory beat (the interiority trace made audible).
nonisolated enum MemoryBeat: String, Sendable, CaseIterable {
    case rehearsal   // Ember practiced its dance
    case sprout      // Willow kept watering
    case weekGrid    // Compass finished the audit
    case trinket     // Prism found something
    case barometer   // Nimbus saw you coming
}

nonisolated enum WakeBeatSelector {
    /// Life events count if they happened within this lookback (today or
    /// late yesterday — the morning beat may reference last evening).
    static let lifeEventLookbackSec: TimeInterval = 18 * 3_600

    /// E4: pure anniversary match — today matches the naming day's month/day.
    /// A Feb 29 naming is honored on Mar 1 in non-leap years.
    static func isAnniversary(namingDay: Date, now: Date, calendar: Calendar = .current) -> Bool {
        let named = calendar.dateComponents([.month, .day, .year], from: namingDay)
        let today = calendar.dateComponents([.month, .day, .year], from: now)
        if named.month == today.month, named.day == today.day { return true }
        if named.month == 2, named.day == 29,
           today.month == 3, today.day == 1,
           let year = today.year, !(year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) {
            return true  // non-leap year: Feb 29 -> Mar 1
        }
        return false
    }

    /// Whole years between the naming day and now (>= 1 on an anniversary).
    static func anniversaryYears(namingDay: Date, now: Date, calendar: Calendar = .current) -> Int {
        max(1, calendar.dateComponents([.year], from: namingDay, to: now).year ?? 1)
    }

    /// The beat for this visit, or nil when today's beat was already shown
    /// (later visits get the short wake — no replay nagging, G4).
    static func beat(memory: CompanionMemory, archetype: Archetype,
                     now: Date, calendar: Calendar = .current) -> WakeBeat? {
        let dayIndex = CompanionMemoryStore.dayIndex(of: now, calendar: calendar)
        if memory.lastBeatDay == dayIndex { return nil }

        // 1. Life events (weather has its own tier below).
        let lifeKind = LifeKind.hash(of: .weatherClass)
        if let entry = memory.lifeLog
            .filter({ $0.kindHash != lifeKind && $0.at.map { now.timeIntervalSince($0) <= lifeEventLookbackSec } ?? false })
            .max(by: { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }),
           let kind = LifeKind.kind(forHash: entry.kindHash) {
            return .lifeEvent(kind: kind)
        }

        // 2. E4: the naming-day anniversary (a pending life event still wins).
        if let namingDay = memory.namingDay,
           isAnniversary(namingDay: namingDay, now: now, calendar: calendar) {
            return .namingAnniversary(years: anniversaryYears(namingDay: namingDay, now: now, calendar: calendar))
        }

        // 3. Today's weather (a known class only).
        if let entry = memory.lifeLog.filter({
            $0.kindHash == lifeKind && $0.dayIndex == dayIndex
        }).last,
           let classHash = entry.classHash,
           let klass = ConditionClass.fromHash(classHash), klass != .unknown {
            return .weather(klass)
        }

        // 4. The archetype's own memory trace.
        let memoryBeat: MemoryBeat?
        switch archetype {
        case .ember: memoryBeat = memory.rehearsalLevel >= 1 ? .rehearsal : nil
        case .willow: memoryBeat = memory.sproutDays >= 3 ? .sprout : nil
        case .compass: memoryBeat = memory.streakDays > 0 ? .weekGrid : nil
        case .prism: memoryBeat = memory.trinketDay == dayIndex || memory.trinketDay == dayIndex - 1 ? .trinket : nil
        case .nimbus:
            let hour = Double(calendar.component(.hour, from: now))
                + Double(calendar.component(.minute, from: now)) / 60
            memoryBeat = memory.usualHourEMA.map { abs(hour - $0) <= 1.0 } ?? false ? .barometer : nil
        }
        if let memoryBeat { return .memory(memoryBeat) }

        // 4. Plain warm greeting.
        return .warm
    }

    /// Marks today's beat as shown (call when the beat plays).
    static func markShown(_ memory: inout CompanionMemory, now: Date, calendar: Calendar = .current) {
        memory.lastBeatDay = CompanionMemoryStore.dayIndex(of: now, calendar: calendar)
    }

    /// The beat's sprite acts (the existing vocabulary — F5 adds no clips).
    static func acts(for beat: WakeBeat, archetype: Archetype) -> [SpriteDirector.SpriteAct] {
        switch beat {
        case .warm:
            return [.happy]
        case .namingAnniversary:
            // The archetype's one "big" signature act (<= 33 ticks total).
            switch archetype {
            case .ember: return [.quirk]        // the fox's spin-class show
            case .willow: return [.slowBlink]   // slow blink + croak
            case .compass: return [.quirk]      // the metronome double
            case .prism: return [.quirk]        // the coil release
            case .nimbus: return [.perk]        // the puff
            }
        case .lifeEvent(let kind):
            let event: LifeEvent = {
                switch kind {
                case .calendarSoon: return .calendarSoon(titleHash: 0)
                case .workoutDone: return .workoutDone(kindBand: 0, durationBand: 0)
                case .sleptWithWatch: return .sleptWithWatch
                case .weatherClass: return .weatherClass(classHash: 0)
                case .workoutLive: return .workoutLive(paceBand: 0)
                case .split: return .split(distanceKm: 0)
                }
            }()
            return [SpriteDirector.reactionAct(for: event, archetype: archetype) ?? .happy]
        case .weather(let klass):
            return [SpriteDirector.weatherAct(for: klass, archetype: archetype) ?? .happy]
        case .memory(let memoryBeat):
            switch memoryBeat {
            case .rehearsal: return [.quirk]       // the practiced dance
            case .sprout: return [.slowBlink]      // the tending blink
            case .weekGrid: return [.quirk]        // the approval tick
            case .trinket: return [.look]          // presents the find
            case .barometer: return [.perk]        // saw you coming
            }
        }
    }
}

/// The beat's one-line caption — Dynamic Type text in the shell, NEVER
/// painter pixels (typography stays crisp). House voice: <= 8 words,
/// playful never needy; nil for the plain warm greeting.
nonisolated enum WakeBeatCaption {
    /// v25: all caption copy goes through String(localized:) with a %@
    /// placeholder, so word order is translator-controlled (en/fr at launch).
    static func text(for beat: WakeBeat, name: String) -> String? {
        switch beat {
        case .warm:
            return nil
        case .namingAnniversary(let years):
            // "One year of Ember" / "Ember celebrated naming Ember" (2+ years).
            if years <= 1 {
                return String(format: String(localized: "beat.namingday.title"), name)
            }
            return String(format: String(localized: "beat.namingday.caption"), name, name)
        case .lifeEvent(let kind):
            switch kind {
            case .calendarSoon: return String(format: String(localized: "beat.noticed_day"), name)
            case .workoutDone: return String(format: String(localized: "beat.celebrated_run"), name)
            case .sleptWithWatch: return String(format: String(localized: "beat.slept_beside"), name)
            case .workoutLive: return String(format: String(localized: "beat.ran_with"), name)
            case .split: return String(format: String(localized: "beat.finished_lap"), name)
            case .weatherClass: return nil  // weather has its own beat tier
            }
        case .weather(let klass):
            switch klass {
            case .sunny: return String(format: String(localized: "beat.glows_sun"), name)
            case .gray: return String(format: String(localized: "beat.cozy"), name)
            case .rain: return String(format: String(localized: "beat.loves_rain"), name)
            case .wind: return String(format: String(localized: "beat.rides_wind"), name)
            case .cold: return String(format: String(localized: "beat.keeps_warm"), name)
            case .hot: return String(format: String(localized: "beat.seeks_shade"), name)
            case .unknown: return nil
            }
        case .memory(let memoryBeat):
            switch memoryBeat {
            case .rehearsal: return String(format: String(localized: "beat.rehearsed"), name)
            case .sprout: return String(format: String(localized: "beat.watered"), name)
            case .weekGrid: return String(format: String(localized: "beat.finished_audit"), name)
            case .trinket: return String(format: String(localized: "beat.found_trinket"), name)
            case .barometer: return String(format: String(localized: "beat.saw_coming"), name)
            }
        }
    }
}
