import Foundation

/// ConditionClass (v18 F3): the on-device weather classification — a small
/// closed set, so the engine/director only ever see a class + a day-stable
/// hash (determinism: goldens inject classes, never live weather). "unknown"
/// is the neutral fallback: indistinguishable from today's app (G8).
/// (Moved to AivatarShared in v36 so the shared profile/dial tables compile
/// on every target.)
nonisolated enum ConditionClass: String, Sendable, CaseIterable, Codable {
    case sunny, gray, rain, wind, cold, hot, unknown

    /// Stable content-free hash (payload key — shared FNV with LifeKind).
    var hash: Int { LifeKind.hash(rawValue) }

    static func fromHash(_ value: Int) -> ConditionClass? {
        allCases.first { $0.hash == value }
    }
}
