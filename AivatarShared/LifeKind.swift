import Foundation

/// LifeKind (v18, shared): the life-event KINDS and their stable hashes, in
/// the ONE folder compiled into both the app and the widget — so the
/// complication's copy derivation (F4) and the app's lifeLog (v16/v17) key
/// off exactly the same hash. FNV-1a is stable across runs and platforms.
nonisolated enum LifeKind: String, Sendable, CaseIterable {
    case calendarSoon, workoutDone, sleptWithWatch, weatherClass, workoutLive, split

    /// Stable FNV-1a 64-bit hash as Int (payloads and log keys are content-free).
    static func hash(_ string: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return Int(bitPattern: UInt(h))
    }

    /// The log hash of this kind.
    static func hash(of kind: LifeKind) -> Int { hash(kind.rawValue) }

    /// Reverse lookup for log entries (the copy table keys off the kind).
    static func kind(forHash value: Int) -> LifeKind? {
        allCases.first { hash(of: $0) == value }
    }
}
