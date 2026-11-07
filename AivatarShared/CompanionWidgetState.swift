import Foundation

/// The companion snapshot shared between the watch app and the WidgetKit
/// complication (v12 presence pass). This folder (AivatarShared/) is the
/// ONE set of sources compiled into BOTH the watch app and the widget
/// extension targets, so the schema has exactly one definition. Pure
/// Foundation — no app-module imports.

/// The companion's presence state on the watch face (F4): three states
/// only, never animated in the complication — the STATE CHANGE ACROSS THE
/// DAY is the animation. Asleep is the honest default; awake follows a
/// visit (30 min); event follows a life event (1 h).
nonisolated enum CompanionPresence: String, Codable, Sendable, Equatable {
    case asleep, awake, event
}

/// What the widget renders: the current companion, its (user-owned) name,
/// the streak artifact, and (v18 F4) the presence state + one-line copy.
nonisolated struct CompanionWidgetSnapshot: Codable, Sendable, Equatable {
    /// Archetype rawValue ("ember" ... "nimbus") — keys the icon file.
    var archetypeRaw: String
    /// The companion's name (user-owned via the naming ceremony, else the
    /// archetype codename).
    var name: String
    /// Consecutive attended days (Compass's streak artifact).
    var streakDays: Int

    // MARK: - Schema v2 (v18 F4 — additive, lenient decode like memory v3)

    /// Presence state ("asleep" default — v12 snapshots decode as asleep).
    var presence: CompanionPresence = .asleep
    /// One-line state copy for inline/rectangular ("napping", "awake",
    /// "celebrated your workout") — derived, never stored raw events.
    var line: String = ""
    /// App age in days ("day 23").
    var dayCount: Int = 1
    /// Lowercase animal name for the rectangular line ("fox").
    var animalName: String = ""
    /// Last visit time — drives the awake window in the widget timeline.
    var lastSeen: Date?
    /// Last life-event time — drives the event window.
    var lastEventAt: Date?
    /// Last life-event kind raw value (copy table key; hash-stable).
    var lastEventKindRaw: String?

    init(
        archetypeRaw: String, name: String, streakDays: Int,
        presence: CompanionPresence = .asleep, line: String = "", dayCount: Int = 1,
        animalName: String = "", lastSeen: Date? = nil, lastEventAt: Date? = nil,
        lastEventKindRaw: String? = nil
    ) {
        self.archetypeRaw = archetypeRaw
        self.name = name
        self.streakDays = streakDays
        self.presence = presence
        self.line = line
        self.dayCount = dayCount
        self.animalName = animalName
        self.lastSeen = lastSeen
        self.lastEventAt = lastEventAt
        self.lastEventKindRaw = lastEventKindRaw
    }

    static func `default`(
        archetypeRaw: String = "ember", name: String = "Ember", streakDays: Int = 1
    ) -> CompanionWidgetSnapshot {
        CompanionWidgetSnapshot(archetypeRaw: archetypeRaw, name: name, streakDays: streakDays)
    }

    /// Lenient decode (G8 + v25 fault isolation): v12 snapshots (no v2 keys)
    /// load defaulted, and a corrupt/unknown value (e.g. a future presence
    /// raw value) falls back to the default instead of failing the snapshot.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        archetypeRaw = (try? c.decode(String.self, forKey: .archetypeRaw)) ?? "ember"
        name = (try? c.decode(String.self, forKey: .name)) ?? "Ember"
        streakDays = (try? c.decodeIfPresent(Int.self, forKey: .streakDays)) ?? 1
        presence = (try? c.decodeIfPresent(CompanionPresence.self, forKey: .presence)) ?? .asleep
        line = (try? c.decodeIfPresent(String.self, forKey: .line)) ?? ""
        dayCount = (try? c.decodeIfPresent(Int.self, forKey: .dayCount)) ?? 1
        animalName = (try? c.decodeIfPresent(String.self, forKey: .animalName)) ?? ""
        lastSeen = try? c.decodeIfPresent(Date.self, forKey: .lastSeen)
        lastEventAt = try? c.decodeIfPresent(Date.self, forKey: .lastEventAt)
        lastEventKindRaw = try? c.decodeIfPresent(String.self, forKey: .lastEventKindRaw)
    }
}

/// CompanionStateDerivation (F4): the PURE state/copy/timeline rules, shared
/// by app (publish) and widget (render) — deterministic under injected
/// dates, so the whole schedule is unit-testable without WidgetKit.
nonisolated enum CompanionStateDerivation {
    /// A visit keeps the companion "awake" on the face for 30 min.
    static let awakeWindowSec: TimeInterval = 30 * 60
    /// A life event keeps it in "event" for 1 h.
    static let eventWindowSec: TimeInterval = 60 * 60
    /// G9 power cap: at most this many timeline entries per reload.
    static let timelineCap = 12

    /// State from raw inputs. Priority: event > awake > asleep. Windows are
    /// strict (<) so the expiry anchor lands exactly on the revert.
    static func presence(now: Date, lastSeen: Date?, lastEventAt: Date?) -> CompanionPresence {
        if let e = lastEventAt, now.timeIntervalSince(e) >= 0, now.timeIntervalSince(e) < eventWindowSec {
            return .event
        }
        if let s = lastSeen, now.timeIntervalSince(s) >= 0, now.timeIntervalSince(s) < awakeWindowSec {
            return .awake
        }
        return .asleep
    }

    /// The one-line copy for a state (+ the event kind when in event).
    /// House voice: <= 8 words, playful never needy (G3/G4). v25: localized
    /// (en/fr) via the widget bundle's strings (mirrored in the app bundle).
    static func line(for presence: CompanionPresence, lastEventKind: LifeKind?) -> String {
        switch presence {
        case .asleep: return String(localized: "presence.napping")
        case .awake: return String(localized: "presence.awake")
        case .event:
            switch lastEventKind {
            case .calendarSoon: return String(localized: "presence.noticed_day")
            case .workoutDone: return String(localized: "presence.celebrated_workout")
            case .sleptWithWatch: return String(localized: "presence.slept_beside")
            case .weatherClass: return String(localized: "presence.checked_sky")
            case .workoutLive: return String(localized: "presence.ran_with")
            case .split: return String(localized: "presence.lap_done")
            case nil: return String(localized: "presence.noticed_something")
            }
        }
    }

    /// Inline family line: "Ember · napping".
    static func inlineLine(name: String, presence: CompanionPresence, lastEventKind: LifeKind?) -> String {
        String(format: String(localized: "inline.line"), name, line(for: presence, lastEventKind: lastEventKind))
    }

    /// Rectangular family second line: "day 23 · napping".
    static func rectangularLine(dayCount: Int, presence: CompanionPresence, lastEventKind: LifeKind?) -> String {
        String(format: String(localized: "rect.line"), dayCount, line(for: presence, lastEventKind: lastEventKind))
    }

    /// Timeline entry dates: now + the awake/event EXPIRY anchors + hourly
    /// anchors, sorted, deduped, hard-capped (G9). Including the expiry
    /// times is what keeps the face from showing a stale awake/event state
    /// (F4 acceptance: never stale by more than the 30 min window).
    /// Per-entry presence is computed from the snapshot's timestamps, so the
    /// face reverts to asleep on its own — the app never polls.
    static func timelineDates(now: Date, lastSeen: Date? = nil, lastEventAt: Date? = nil,
                              cap: Int = timelineCap, calendar: Calendar = .current) -> [Date] {
        var set: [Date] = [now]
        if let s = lastSeen { set.append(s.addingTimeInterval(awakeWindowSec)) }
        if let e = lastEventAt { set.append(e.addingTimeInterval(eventWindowSec)) }
        var next = calendar.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3_600)
        while set.count < max(1, cap) {
            set.append(next)
            next = calendar.date(byAdding: .hour, value: 1, to: next) ?? next.addingTimeInterval(3_600)
        }
        let sorted = set.filter { $0 >= now }.sorted()
        var seen: Set<Date> = []
        var out: [Date] = []
        for d in sorted where seen.insert(d).inserted {
            out.append(d)
            if out.count >= max(1, cap) { break }
        }
        return out
    }
}

nonisolated enum CompanionWidgetState {
    /// Shared app-group id — declared in BOTH targets' entitlements.
    static let appGroupID = "group.aivatarapp.Aivatar"
    static let snapshotKey = "companionWidgetSnapshot"
    /// Icons live in the shared container: the app renders them once per
    /// archetype from the real pixel rasterizer (Render/CompanionIcon).
    /// v29: versioned directory — bump when the icon rendering rule changes
    /// (the event-flash rule changed in v29) so stale PNGs never linger;
    /// app and widget share this constant, so both re-seed atomically.
    static let iconsDirectoryName = "Icons-v2"

    static func sharedContainer() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static func iconURL(
        forArchetypeRaw raw: String,
        container: URL? = nil
    ) -> URL? {
        (container ?? sharedContainer())?
            .appendingPathComponent(iconsDirectoryName)
            .appendingPathComponent("\(raw).png")
    }

    /// v18 F4: per-state icon (asleep = rest-dim variant, awake = normal,
    /// event = accent-highlighted). Falls back to the v12 plain icon name
    /// when state is nil (older app versions seeded only "\(raw).png").
    static func iconURL(
        forArchetypeRaw raw: String,
        presence: CompanionPresence?,
        container: URL? = nil
    ) -> URL? {
        guard let presence else { return iconURL(forArchetypeRaw: raw, container: container) }
        return (container ?? sharedContainer())?
            .appendingPathComponent(iconsDirectoryName)
            .appendingPathComponent("\(raw)-\(presence.rawValue).png")
    }

    /// Reads the snapshot; nil = the app has not published yet (first
    /// install, widget added before first launch) — the widget falls back
    /// to the default snapshot.
    static func readSnapshot(
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)
    ) -> CompanionWidgetSnapshot? {
        guard let defaults, let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(CompanionWidgetSnapshot.self, from: data)
    }

    /// Writes the snapshot. Pure (defaults injectable) for test isolation.
    static func write(
        _ snapshot: CompanionWidgetSnapshot,
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)
    ) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }
}
