import Foundation
import HealthKit

/// MindfulnessBridge (Aivatar 2.0, E8): the app's FIRST HealthKit write. On a
/// logged breath session (>= 30 s, <= 3/day), one HKCategorySample of type
/// .mindfulSession is saved — the standard, on-device, opt-in Health record.
///
/// Mirrors the existing bridge pattern: resume-once continuations, no
/// main-thread semaphores, silent degradation when Health is unavailable.
/// Consent: the write authorization is requested IN CONTEXT at the first
/// session start (never at launch); denial sets memory.mindfulWriteDenied and
/// the feature goes fully dormant (G8) — the session still runs, nothing is
/// logged, no re-prompt.
nonisolated final class MindfulnessBridge: @unchecked Sendable {
    private let store: HKHealthStore?
    private let lock = NSLock()
    private var writeRequested = false

    nonisolated enum MindfulnessError: Error { case unavailable }

    init(healthStore: HKHealthStore? = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil) {
        self.store = healthStore
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// In-context write ask (idempotent). Returns whether the mindful-session
    /// write is authorized.
    nonisolated func requestWriteAccessIfNeeded() async -> Bool {
        guard let store else { return false }
        if withLock({ writeRequested }) { return true }  // asked once; outcome recorded by the caller
        withLock { writeRequested = true }
        return await withCheckedContinuation { cont in
            store.requestAuthorization(
                toShare: [HKObjectType.categoryType(forIdentifier: .mindfulSession)!],
                read: []) { granted, _ in
                cont.resume(returning: granted)
            }
        }
    }

    /// Saves exactly one mindful-session sample for the interval.
    func saveSession(start: Date, end: Date) async throws {
        guard let store else { throw MindfulnessError.unavailable }
        let type = HKObjectType.categoryType(forIdentifier: .mindfulSession)!
        let sample = HKCategorySample(type: type, value: HKCategoryValue.notApplicable.rawValue,
                                      start: start, end: end)
        try await withCheckedThrowingContinuation { cont in
            store.save(sample) { _, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: ()) }
            }
        }
    }
}
