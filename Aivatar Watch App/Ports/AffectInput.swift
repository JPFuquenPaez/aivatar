import Foundation

/// Phase C plug-in port (§13). The engine knows nothing about HealthKit or
/// Core ML; it only consumes optional `AffectState` values and blends them
/// over the archetype baseline (never replacing it).
struct AffectState: Sendable {
    var valence: Float        // -1 ... +1
    var arousal: Float        //  0 ... +1
    var confidence: Float     //  0 ... +1 (low -> engine holds neutral)
    var timestamp: Date
}

nonisolated protocol AffectInput: Sendable {
    var affect: AffectState? { get }
}

/// No-op Phase C stub: no affect source exists yet. Phase C implements this
/// protocol (HealthKit sensing + on-device Core ML classification happen
/// entirely outside the engine) and the engine requires zero changes.
nonisolated struct NullAffectInput: AffectInput {
    var affect: AffectState? { nil }
}
