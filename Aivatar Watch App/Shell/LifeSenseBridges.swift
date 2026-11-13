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

    /// Sync lock helper (NSLock is unavailable directly in async contexts).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// In-context authorization ask — called once, when the user enables the
    /// toggle (not at launch: a prompt with nothing behind it is worse than
    /// none, watchOS HIG). Idempotent.
    nonisolated func requestAccessIfNeeded() {
        let (shouldAsk, status) = withLock {
            if accessRequested { return (false, EKEventStore.authorizationStatus(for: .event)) }
            accessRequested = true
            let s = EKEventStore.authorizationStatus(for: .event)
            if s == .fullAccess { authorized = true }
            return (true, s)
        }
        if status == .fullAccess { return }
        guard status == .notDetermined, shouldAsk else { return }
        store.requestFullAccessToEvents { [weak self] granted, _ in
            guard let self else { return }
            self.lock.lock()
            self.authorized = granted
            self.lock.unlock()
        }
    }

    /// On-demand poll. Returns [] when unauthorized or when today's cap is
    /// spent (the cap counts lifeLog entries, not raw events).
    nonisolated func poll(now: Date) async -> [LifeEvent] {
        guard withLock({ authorized }) else { return [] }
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

    /// Sync lock helper (NSLock is unavailable directly in async contexts).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// The read set is named exactly in the consent copy: saved workouts and
    /// sleep analysis, read-only, on this watch.
    private static var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType(), HKCategoryType(.sleepAnalysis)]
    }

    nonisolated func requestAccessIfNeeded() {
        guard let store else { return }
        if withLock({ accessRequested }) { return }
        withLock { accessRequested = true }
        store.requestAuthorization(toShare: [], read: Self.readTypes) { [weak self] granted, _ in
            self?.withLock { self?.authorized = granted }
        }
    }

    nonisolated func poll(now: Date) async -> [LifeEvent] {
        guard let store else { return [] }
        guard withLock({ authorized }) else { return [] }

        var events: [LifeEvent] = []
        events += await pollWorkouts(store: store, now: now)
        events += await pollSleep(store: store, now: now)
        return events
    }

    /// Anchored query: only NEW saved workouts since the last poll produce an
    /// event (a re-open must not re-celebrate yesterday's run — G4-adjacent:
    /// reactions, never nags). Async (v23): the query resolves via a
    /// continuation, never a main-thread semaphore.
    private func pollWorkouts(store: HKHealthStore, now: Date) async -> [LifeEvent] {
        let queryAnchor = defaults.data(forKey: Self.anchorKey)
            .flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let once = OnceBox<[LifeEvent]>([])
        let query = HKAnchoredObjectQuery(
            type: HKObjectType.workoutType(),
            predicate: HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-7 * 86_400), end: now, options: []),
            anchor: queryAnchor,
            limit: HKObjectQueryNoLimit
        ) { _, samples, _, newAnchor, error in
            guard error == nil else { return }
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) {
                self.defaults.set(data, forKey: Self.anchorKey)
            }
            let result = (samples as? [HKWorkout] ?? []).map {
                LifeSenseMapping.workoutDoneEvent(.init(
                    activityRaw: Int($0.workoutActivityType.rawValue),
                    durationSec: $0.duration))
            }
            once.set(result)  // initial + any update callbacks; resume once
        }
        store.execute(query)
        return await withCheckedContinuation { cont in
            once.onSet = { cont.resume(returning: $0) }
            // Safety timeout in case no callback ever arrives.
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                once.setIfUnset([])
            }
        }
    }

    /// Sleep analysis for the last night, once per calendar day.
    private func pollSleep(store: HKHealthStore, now: Date) async -> [LifeEvent] {
        let dayIndex = CompanionMemoryStore.dayIndex(of: now)
        if defaults.integer(forKey: Self.sleepDayKey) == dayIndex { return [] }
        let start = now.addingTimeInterval(-12 * 3_600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let once = OnceBox<Bool>(false)
        let query = HKSampleQuery(
            sampleType: HKCategoryType(.sleepAnalysis),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ) { _, samples, _ in
            once.set((samples as? [HKCategorySample])?.contains {
                $0.value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                    || $0.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                    || $0.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                    || $0.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
            } ?? false)
        }
        store.execute(query)
        let slept = await withCheckedContinuation { cont in
            once.onSet = { cont.resume(returning: $0) }
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                once.setIfUnset(false)
            }
        }
        guard slept else { return [] }
        defaults.set(dayIndex, forKey: Self.sleepDayKey)
        return LifeSenseMapping.sleepEvent(sleptWithWatch: true)
    }

    /// Resume-once box for query callbacks (v23: replaces semaphore waits).
    private final class OnceBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        private var _set = false
        var onSet: (@Sendable (T) -> Void)?
        init(_ value: T) { _value = value }
        func set(_ value: T) {
            lock.lock()
            _value = value
            let fire = !_set
            _set = true
            let h = onSet
            lock.unlock()
            if fire { h?(value) }
        }
        func setIfUnset(_ value: T) {
            lock.lock()
            let wasSet = _set
            if !wasSet { _value = value; _set = true }
            let h = onSet
            lock.unlock()
            if !wasSet { h?(value) }
        }
    }

}
