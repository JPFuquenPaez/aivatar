import Foundation
import EventKit
import HealthKit

/// LifeSenseMapping (v17, Ambient Life F2): the PURE cores of the life-sense
/// bridges — every classification rule is a static function of plain values,
/// unit-tested without TCC. The bridges below are thin adapters over EventKit
/// / HealthKit; the engine and director only ever see LifeEvents.
///
/// Privacy by construction (G5): payloads carry hashes and bands, never
/// titles, names, or raw numbers. FNV-1a is stable across runs/platforms.
nonisolated enum LifeSenseMapping {
    /// Stable FNV-1a 64-bit hash of a string, as Int (payloads are content-free).
    /// Delegates to the SHARED LifeKind so the widget's copy table keys off
    /// the same hash (v18).
    static func hash(_ string: String) -> Int { LifeKind.hash(string) }

    /// The event kind's log hash (ring-buffer key in CompanionMemory.lifeLog).
    static func kindHash(of event: LifeEvent) -> Int {
        switch event {
        case .calendarSoon: return LifeKind.hash(of: .calendarSoon)
        case .workoutDone: return LifeKind.hash(of: .workoutDone)
        case .sleptWithWatch: return LifeKind.hash(of: .sleptWithWatch)
        case .weatherClass: return LifeKind.hash(of: .weatherClass)
        case .workoutLive: return LifeKind.hash(of: .workoutLive)
        case .split: return LifeKind.hash(of: .split)
        }
    }

    // MARK: - Calendar (pure core)

    /// A minimal calendar item — the EventKit adapter maps EKEvent into this
    /// (title + start only; nothing else crosses the bridge).
    nonisolated struct CalendarItem: Sendable, Equatable {
        var title: String
        var start: Date
    }

    /// "An event starts within the next 10 minutes" -> one LifeEvent per
    /// event, soonest first, capped at the remaining daily allowance
    /// (F2 acceptance: <= 3 calendar reactions/day, enforced here).
    static let calendarSoonWindowSec: TimeInterval = 10 * 60
    static let calendarDailyCap = 3

    static func calendarEvents(_ items: [CalendarItem], now: Date,
                               window: TimeInterval = calendarSoonWindowSec,
                               dailyCap: Int = calendarDailyCap,
                               notifiedToday: Int) -> [LifeEvent] {
        let remaining = max(0, dailyCap - notifiedToday)
        return items
            .filter { $0.start > now && $0.start <= now + window }
            .sorted { $0.start < $1.start }
            .prefix(remaining)
            .map { .calendarSoon(titleHash: hash($0.title)) }
    }

    // MARK: - Health (pure core)

    /// A minimal workout record — the HealthKit adapter maps HKSample into
    /// this (activity raw value + duration only).
    nonisolated struct WorkoutItem: Sendable, Equatable {
        var activityRaw: Int
        var durationSec: TimeInterval
    }

    /// Workout -> banded LifeEvent. Bands, never numbers (G7 determinism:
    /// the engine stays numeric-free). Duration band: 10-min buckets, 0...5.
    static func workoutDoneEvent(_ workout: WorkoutItem) -> LifeEvent {
        .workoutDone(kindBand: workout.activityRaw & 0xF,
                     durationBand: min(5, Int(workout.durationSec / 600)))
    }

    /// Worn through a sleep period -> one soft "slept beside you" event.
    static func sleepEvent(sleptWithWatch: Bool) -> [LifeEvent] {
        sleptWithWatch ? [.sleptWithWatch] : []
    }

    // MARK: - Shared

    /// How many events of a kind were already logged today (the daily cap's
    /// memory side — the bridge reads the ring buffer, never event content).
    static func notifiedToday(_ log: [LifeLogEntry], kind: LifeEvent, dayIndex: Int) -> Int {
        let h = kindHash(of: kind)
        return log.filter { $0.kindHash == h && $0.dayIndex == dayIndex }.count
    }
}

/// CalendarSenseBridge (F2): reads the watch's mirrored calendars (EventKit
/// on watchOS reads the iPhone-mirrored events) ON DEMAND — poll is called on
/// visit/wake only, never in a background loop (G9). Without consent or
/// authorization it returns nothing and the feature is fully dormant.
nonisolated final class CalendarSenseBridge: LifeSenseSource, @unchecked Sendable {
    private let store = EKEventStore()
    private let memoryStore: CompanionMemoryStore
    private let lock = NSLock()
    private var accessRequested = false
    private var authorized = false

    init(memoryStore: CompanionMemoryStore = CompanionMemoryStore()) {
        self.memoryStore = memoryStore
    }

    /// In-context authorization ask — called once, when the user enables the
    /// toggle (not at launch: a prompt with nothing behind it is worse than
    /// none, watchOS HIG). Idempotent.
    nonisolated func requestAccessIfNeeded() {
        lock.lock()
        if accessRequested { lock.unlock(); return }
        accessRequested = true
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { authorized = true; lock.unlock(); return }
        lock.unlock()
        guard status == .notDetermined else { return }
        store.requestFullAccessToEvents { [weak self] granted, _ in
            guard let self else { return }
            self.lock.lock()
            self.authorized = granted
            self.lock.unlock()
        }
    }

    /// On-demand poll. Returns [] when unauthorized or when today's cap is
    /// spent (the cap counts lifeLog entries, not raw events).
    nonisolated func poll(now: Date) -> [LifeEvent] {
        lock.lock()
        let ok = authorized
        lock.unlock()
        guard ok else { return [] }
        let predicate = store.predicateForEvents(
            withStart: now, end: now + LifeSenseMapping.calendarSoonWindowSec, calendars: nil)
        let items = store.events(matching: predicate).map {
            LifeSenseMapping.CalendarItem(title: $0.title ?? "", start: $0.startDate)
        }
        let dayIndex = CompanionMemoryStore.dayIndex(of: now)
        let log = memoryStore.load()?.lifeLog ?? []
        let notified = LifeSenseMapping.notifiedToday(log, kind: .calendarSoon(titleHash: 0), dayIndex: dayIndex)
        return LifeSenseMapping.calendarEvents(items, now: now, notifiedToday: notified)
    }
}

/// HealthSenseBridge (F2): anchored object query for SAVED WORKOUTS (any app's
/// — HealthKit shares workout objects read-authorized) plus a sleep-analysis
/// read at wake. Polled on demand only; no background delivery, no continuous
/// queries (G9; F6's live HR is a separate, session-scoped path).
nonisolated final class HealthSenseBridge: LifeSenseSource, @unchecked Sendable {
    private let store: HKHealthStore?
    private let memoryStore: CompanionMemoryStore
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var accessRequested = false
    private var authorized = false

    private static let anchorKey = "healthSense.workoutAnchor"
    private static let sleepDayKey = "healthSense.lastSleepDay"

    init(memoryStore: CompanionMemoryStore = CompanionMemoryStore(),
         defaults: UserDefaults = .standard,
         healthStore: HKHealthStore? = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil) {
        self.memoryStore = memoryStore
        self.defaults = defaults
        self.store = healthStore
    }

    /// The read set is named exactly in the consent copy: saved workouts and
    /// sleep analysis, read-only, on this watch.
    private static var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType(), HKCategoryType(.sleepAnalysis)]
    }

    nonisolated func requestAccessIfNeeded() {
        guard let store else { return }
        lock.lock()
        if accessRequested { lock.unlock(); return }
        accessRequested = true
        lock.unlock()
        store.requestAuthorization(toShare: [], read: Self.readTypes) { [weak self] granted, _ in
            guard let self else { return }
            self.lock.lock()
            self.authorized = granted
            self.lock.unlock()
        }
    }

    nonisolated func poll(now: Date) -> [LifeEvent] {
        guard let store else { return [] }
        lock.lock()
        let ok = authorized
        lock.unlock()
        guard ok else { return [] }

        var events: [LifeEvent] = []
        events += pollWorkouts(store: store, now: now)
        events += pollSleep(store: store, now: now)
        return events
    }

    /// Anchored query: only NEW saved workouts since the last poll produce an
    /// event (a re-open must not re-celebrate yesterday's run — G4-adjacent:
    /// reactions, never nags).
    private func pollWorkouts(store: HKHealthStore, now: Date) -> [LifeEvent] {
        let queryAnchor = defaults.data(forKey: Self.anchorKey)
            .flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let box = ResultBox<[LifeEvent]>([])
        let semaphore = DispatchSemaphore(value: 0)
        let query = HKAnchoredObjectQuery(
            type: HKObjectType.workoutType(),
            predicate: HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-7 * 86_400), end: now, options: []),
            anchor: queryAnchor,
            limit: HKObjectQueryNoLimit
        ) { _, samples, _, newAnchor, error in
            defer { semaphore.signal() }
            guard error == nil else { return }
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) {
                self.defaults.set(data, forKey: Self.anchorKey)
            }
            box.value = (samples as? [HKWorkout] ?? []).map {
                LifeSenseMapping.workoutDoneEvent(.init(
                    activityRaw: Int($0.workoutActivityType.rawValue),
                    durationSec: $0.duration))
            }
        }
        store.execute(query)
        _ = semaphore.wait(timeout: .now() + 5)
        return box.value
    }

    /// Sleep analysis for the last night, once per calendar day.
    private func pollSleep(store: HKHealthStore, now: Date) -> [LifeEvent] {
        let dayIndex = CompanionMemoryStore.dayIndex(of: now)
        if defaults.integer(forKey: Self.sleepDayKey) == dayIndex { return [] }
        let start = now.addingTimeInterval(-12 * 3_600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let box = ResultBox<Bool>(false)
        let semaphore = DispatchSemaphore(value: 0)
        let query = HKSampleQuery(
            sampleType: HKCategoryType(.sleepAnalysis),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ) { _, samples, _ in
            defer { semaphore.signal() }
            box.value = (samples as? [HKCategorySample])?.contains {
                $0.value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                    || $0.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                    || $0.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                    || $0.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
            } ?? false
        }
        store.execute(query)
        _ = semaphore.wait(timeout: .now() + 5)
        guard box.value else { return [] }
        defaults.set(dayIndex, forKey: Self.sleepDayKey)
        return LifeSenseMapping.sleepEvent(sleptWithWatch: true)
    }

    /// Sendable box for query callbacks (Swift 6 closure captures).
    private final class ResultBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
        init(_ value: T) { _value = value }
    }
}
