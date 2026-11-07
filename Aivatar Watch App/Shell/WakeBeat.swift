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

        // 2. Today's weather (a known class only).
        if let entry = memory.lifeLog.filter({
            $0.kindHash == lifeKind && $0.dayIndex == dayIndex
        }).last,
           let classHash = entry.classHash,
           let klass = ConditionClass.fromHash(classHash), klass != .unknown {
            return .weather(klass)
        }

        // 3. The archetype's own memory trace.
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
    static func text(for beat: WakeBeat, name: String) -> String? {
        switch beat {
        case .warm:
            return nil
        case .lifeEvent(let kind):
            switch kind {
            case .calendarSoon: return "\(name) noticed your day"
            case .workoutDone: return "\(name) celebrated your run"
            case .sleptWithWatch: return "\(name) slept beside you"
            case .workoutLive: return "\(name) ran with you"
            case .split: return "\(name) finished a lap"
            case .weatherClass: return nil  // weather has its own beat tier
            }
        case .weather(let klass):
            switch klass {
            case .sunny: return "\(name) glows in the sun"
            case .gray: return "\(name) is cozy today"
            case .rain: return "\(name) loves the rain"
            case .wind: return "\(name) rides the wind"
            case .cold: return "\(name) keeps warm today"
            case .hot: return "\(name) seeks the shade"
            case .unknown: return nil
            }
        case .memory(let memoryBeat):
            switch memoryBeat {
            case .rehearsal: return "\(name) rehearsed a dance"
            case .sprout: return "\(name) watered the sprout"
            case .weekGrid: return "\(name) finished the audit"
            case .trinket: return "\(name) found a trinket"
            case .barometer: return "\(name) saw you coming"
            }
        }
    }
}
