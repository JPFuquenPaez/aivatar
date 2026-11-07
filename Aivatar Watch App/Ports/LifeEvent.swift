import Foundation

/// LifeEvent (Ambient Life spec §0 shared plumbing, F2/F3/F5): what the
/// user's real day told the companion. Bridges (calendar, health, weather,
/// Aivatar's own notifications) translate system signals into these values
/// on the existing event path — the engine/director never calls EventKit,
/// HealthKit, or WeatherKit, exactly like NotificationAvatarBridge.
///
/// Privacy by construction (G5): payloads carry only affect tags and hashes
/// — no event titles, no numbers — so determinism is preserved (a hash is
/// a pure input, like the seed).
nonisolated enum LifeEvent: Sendable, Equatable {
    /// A calendar event starts soon (payload: title hash only).
    case calendarSoon(titleHash: Int)
    /// A workout was saved (kind band + duration band, never raw numbers).
    case workoutDone(kindBand: Int, durationBand: Int)
    /// The watch was worn through a sleep period.
    case sleptWithWatch
    /// Today's resolved weather class hash (F3; classification on-device).
    case weatherClass(classHash: Int)
    /// A live workout metric band (F6; bands, throttled by the bridge).
    case workoutLive(paceBand: Int)
}

/// One hashed entry in CompanionMemory.lifeLog — the ring buffer of the
/// last life events, used by greeting beats and postcards (F5/F8).
/// Day-stable and content-free: kind hash + calendar day index + timestamp.
nonisolated struct LifeLogEntry: Codable, Equatable, Sendable {
    /// Hash of the event kind (LifeKind.hash — shared with the widget).
    var kindHash: Int
    /// Calendar day index (startOfDay / 86_400) the event happened on.
    var dayIndex: Int
    /// When it happened (v18 F4: drives the complication's event window).
    /// nil in v16/v17 entries — decoded leniently.
    var at: Date?

    init(kindHash: Int, dayIndex: Int, at: Date? = nil) {
        self.kindHash = kindHash
        self.dayIndex = dayIndex
        self.at = at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kindHash = try c.decode(Int.self, forKey: .kindHash)
        dayIndex = try c.decode(Int.self, forKey: .dayIndex)
        at = try c.decodeIfPresent(Date.self, forKey: .at)
    }
}

/// LifeSenseSource (§0): a bridge that polls a system signal on demand —
/// on visit/wake only, never in a background loop (G9: zero rest-state
/// cost). The engine never sees this protocol; the shell polls and emits
/// LifeEvents on the AvatarEvent path.
nonisolated protocol LifeSenseSource: Sendable {
    /// Events observed since the last poll. Pure translation; no content.
    func poll(now: Date) -> [LifeEvent]
}

/// Null stub: with no consent granted the feature is fully dormant and
/// the app is indistinguishable from one without life sense (F2 acceptance).
nonisolated struct NullLifeSenseSource: LifeSenseSource {
    nonisolated init() {}
    nonisolated func poll(now: Date) -> [LifeEvent] { [] }
}
