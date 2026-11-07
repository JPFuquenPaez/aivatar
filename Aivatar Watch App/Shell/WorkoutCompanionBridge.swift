import Foundation
import HealthKit

/// WorkoutCompanionBridge (v21, Ambient Life F6): Aivatar hosts its OWN
/// HKWorkoutSession (an app cannot ride inside the system Workout app's live
/// metrics — the honest platform constraint). Live metrics are POLLED at a
/// 10 s cadence from plain statistics queries — never a background stream —
/// and translated into banded LifeEvents (the engine stays numeric-free).
///
/// Force-quit recovery: the in-progress marker is persisted; on next launch
/// a partial workout is finished (or discarded when too short to be real).
/// All decision logic is pure and unit-tested below.
nonisolated final class WorkoutCompanionBridge: @unchecked Sendable {
    private let healthStore: HKHealthStore?
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var session: HKWorkoutSession?
    private var builder: HKWorkoutBuilder?
    private var startedAt: Date?
    private var lastActivityRaw = Int(HKWorkoutActivityType.running.rawValue)

    /// Sync lock helper (NSLock is unavailable directly in async contexts).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
    private var lastDistanceMeters: Double = 0
    private var lastAnnouncedSplitKm = 0
    private var lastLiveEmit: Date?

    static let liveEmitMinSec: TimeInterval = 10
    static let splitCooldownSec: TimeInterval = 45
    private var lastSplitEmit: Date?

    private static let progressKey = "workout.inProgress"

    init(defaults: UserDefaults = .standard,
         healthStore: HKHealthStore? = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil) {
        self.defaults = defaults
        self.healthStore = healthStore
    }

    // MARK: - Pure cores (unit-tested)

    /// Pace band 0...5 from m/s (walk < 2.5, run 3-5, sprint 6+).
    static func paceBand(metersPerSec: Double) -> Int {
        switch metersPerSec {
        case ..<1.5: return 0
        case ..<2.5: return 1
        case ..<3.5: return 2
        case ..<4.5: return 3
        case ..<6.0: return 4
        default: return 5
        }
    }

    /// The next split (whole km) crossed by this distance, if any.
    static func nextSplitKm(after lastAnnouncedKm: Int, distanceMeters: Double) -> Int? {
        let km = Int(distanceMeters / 1_000)
        return km > lastAnnouncedKm ? km : nil
    }

    /// The in-progress marker persisted across force-quits.
    struct InProgress: Codable, Equatable, Sendable {
        var activityRaw: Int
        var startedAt: Date
        var lastDistanceMeters: Double
        var lastSync: Date
    }

    nonisolated enum Recovery: Equatable, Sendable {
        case none
        /// Too short to be a real workout — discard silently.
        case discard
        /// Finish a partial workout with these totals.
        case finishPartial(durationSec: TimeInterval, distanceMeters: Double)
    }

    /// The force-quit recovery decision (pure). A marker younger than 60 s
    /// was never a workout; otherwise finish the partial.
    static func recovery(saved: InProgress?, now: Date) -> Recovery {
        guard let saved else { return .none }
        let duration = now.timeIntervalSince(saved.startedAt)
        guard duration >= 60 else { return .discard }
        return .finishPartial(durationSec: duration, distanceMeters: saved.lastDistanceMeters)
    }

    // MARK: - Session lifecycle

    /// Starts Aivatar's own workout session. HealthKit authorization is
    /// requested IN CONTEXT here (share workout, read distance + HR) — the
    /// first time the user taps "Run with …".
    func start(activityRaw: Int, now: Date = Date()) async throws {
        guard let store = healthStore else { throw WorkoutError.unavailable }
        try await requestAuthorization(store: store)
        let activity = HKWorkoutActivityType(rawValue: UInt(activityRaw))
            ?? HKWorkoutActivityType(rawValue: HKWorkoutActivityType.running.rawValue)!
        let config = HKWorkoutConfiguration()
        config.activityType = activity
        config.locationType = .outdoor
        let session = try HKWorkoutSession(healthStore: store, configuration: config)
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
        session.prepare()
        session.startActivity(with: now)  // sync void on watchOS
        try await builder.beginCollection(at: now)
        withLock {
            self.session = session
            self.builder = builder
            self.startedAt = now
            self.lastActivityRaw = activityRaw
            self.lastDistanceMeters = 0
            self.lastAnnouncedSplitKm = 0
            self.lastLiveEmit = nil
            self.lastSplitEmit = nil
        }
        persist(InProgress(activityRaw: activityRaw, startedAt: now,
                            lastDistanceMeters: 0, lastSync: now))
    }

    /// Ends the session and saves the workout to Health (a normal workout —
    /// Fitness reads it like any other). Returns the workoutDone event.
    func stop(now: Date = Date()) async throws -> LifeEvent {
        let (builder, startedAt, activityRaw) = snapshot()
        guard let builder, let startedAt else { throw WorkoutError.notRunning }
        let end = now
        try await builder.endCollection(at: end)
        _ = try? await finishWorkout(builder)
        withLock {
            self.session = nil
            self.builder = nil
            self.startedAt = nil
        }
        clearPersisted()
        return .workoutDone(
            kindBand: activityRaw & 0xF,
            durationBand: min(5, Int(end.timeIntervalSince(startedAt) / 600)))
    }

    /// On launch: recover a force-quit session (pure decision -> action).
    func recoverIfNeeded(now: Date = Date()) async -> [LifeEvent] {
        guard let saved = loadPersisted() else { return [] }
        switch Self.recovery(saved: saved, now: now) {
        case .none, .discard:
            clearPersisted()
            return []
        case .finishPartial(let duration, let distance):
            // The old session is dead after a force-quit; record the partial
            // as a finished workout so Health keeps it, and tell the pet.
            clearPersisted()
            await finishPartial(startedAt: saved.startedAt, end: now, distanceMeters: distance)
            return [.workoutDone(kindBand: saved.activityRaw & 0xF,
                                 durationBand: min(5, Int(duration / 600)))]
        }
    }

    // MARK: - Live metrics poll (10 s cadence, called from the stage timer)

    /// Returns banded live events: at most one pace band per 10 s, and at
    /// most one split per 45 s (the director also rate-caps cheers).
    func pollMetrics(now: Date = Date()) -> [LifeEvent] {
        let (builder, startedAt, _) = snapshot()
        guard let builder, let startedAt, let store = healthStore else { return [] }
        let (lastDist, lastKm, lastLive, lastSplit) = withLock {
            (lastDistanceMeters, lastAnnouncedSplitKm, lastLiveEmit, lastSplitEmit)
        }

        let distance = (try? sumQuantity(
            store: store, type: HKQuantityType(.distanceWalkingRunning),
            from: startedAt, to: now)) ?? lastDist
        let pace = Self.paceBand(metersPerSec: max(0, distance - lastDist)
            / max(1, now.timeIntervalSince(lastLive ?? startedAt)))

        var events: [LifeEvent] = []
        if lastLive.map({ now.timeIntervalSince($0) >= Self.liveEmitMinSec }) ?? true {
            events.append(.workoutLive(paceBand: pace))
            withLock { lastLiveEmit = now; lastDistanceMeters = distance }
        }
        if let km = Self.nextSplitKm(after: lastKm, distanceMeters: distance),
           lastSplit.map({ now.timeIntervalSince($0) >= Self.splitCooldownSec }) ?? true {
            events.append(.split(distanceKm: km))
            withLock { lastAnnouncedSplitKm = km; lastSplitEmit = now }
        }
        _ = builder
        return events
    }

    // MARK: - Internals

    private func requestAuthorization(store: HKHealthStore) async throws {
        try await store.requestAuthorization(
            toShare: [HKObjectType.workoutType()],
            read: [HKObjectType.workoutType(),
                   HKQuantityType(.distanceWalkingRunning),
                   HKQuantityType(.heartRate)])
    }

    private func sumQuantity(store: HKHealthStore, type: HKQuantityType,
                             from: Date, to: Date) throws -> Double {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        var total = 0.0
        let semaphore = DispatchSemaphore(value: 0)
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                      options: .cumulativeSum, completionHandler: { _, stats, _ in
            defer { semaphore.signal() }
            total = stats?.sumQuantity()?.doubleValue(for: .meter()) ?? 0
        })
        store.execute(query)
        _ = semaphore.wait(timeout: .now() + 5)
        return total
    }

    private func finishPartial(startedAt: Date, end: Date, distanceMeters: Double) async {
        guard let store = healthStore else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
        try? await builder.beginCollection(at: startedAt)
        // Re-attach the partial distance as a sample so the totals are real.
        if distanceMeters > 0 {
            let distance = HKQuantity(unit: .meter(), doubleValue: distanceMeters)
            let sample = HKQuantitySample(type: HKQuantityType(.distanceWalkingRunning),
                                          quantity: distance, start: startedAt, end: end)
            try? await builder.addSamples([sample])
        }
        try? await builder.endCollection(at: end)
        _ = try? await finishWorkout(builder)
    }

    /// finishWorkout has no async variant on watchOS — wrap the callback.
    private func finishWorkout(_ builder: HKWorkoutBuilder) async throws -> HKWorkout? {
        try await withCheckedThrowingContinuation { cont in
            builder.finishWorkout { workout, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: workout) }
            }
        }
    }

    private func snapshot() -> (HKWorkoutBuilder?, Date?, Int) {
        withLock { (builder, startedAt, lastActivityRaw) }
    }

    private func persist(_ value: InProgress) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.progressKey)
        }
    }

    private func loadPersisted() -> InProgress? {
        guard let data = defaults.data(forKey: Self.progressKey) else { return nil }
        return try? JSONDecoder().decode(InProgress.self, from: data)
    }

    private func clearPersisted() { defaults.removeObject(forKey: Self.progressKey) }

    nonisolated enum WorkoutError: Error { case unavailable, notRunning }
}
