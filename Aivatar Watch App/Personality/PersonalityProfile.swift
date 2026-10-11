import Foundation

/// The five personality archetypes (§5). One shared skeleton; each archetype
/// contributes a PersonalityProfile + ArchetypeVisualSet.
nonisolated enum Archetype: String, Sendable, CaseIterable, Codable {
    case ember, willow, compass, prism, nimbus

    var displayName: String {
        switch self {
        case .ember: return "Ember"
        case .willow: return "Willow"
        case .compass: return "Compass"
        case .prism: return "Prism"
        case .nimbus: return "Nimbus"
        }
    }
}

/// Big Five trait vector, 0...1 per trait (§5).
nonisolated struct TraitVector: Codable, Sendable, Equatable {
    var extraversion: Float
    var agreeableness: Float
    var conscientiousness: Float
    var openness: Float
    var neuroticism: Float
}

/// Performance parameters (§5 "motionProfile"): rates, amplitudes, tempo.
nonisolated struct MotionProfile: Codable, Sendable, Equatable {
    var gestureRatePerMin: Float
    var amplitudeScale: Float
    var tempoScale: Float
    /// [min, max] seconds for idle-gesture transitions.
    var transitionDurationSec: [Float]
    /// Exaggeration dial (Disney overshoot), 0...1.
    var overshoot: Float

    var transitionDurationRange: ClosedRange<Float> {
        let lo = transitionDurationSec.first ?? 0.4
        let hi = transitionDurationSec.last ?? max(lo, 0.7)
        return min(lo, hi)...max(lo, hi)
    }
}

/// Gaze behavior (§5 "gazeProfile"): blink/saccade rates + head propensity.
nonisolated struct GazeProfile: Codable, Sendable, Equatable {
    var blinkRatePerMin: Float
    var saccadeRatePerMin: Float
    /// Probability a gaze shift also moves the head (head movement propensity).
    var headPropensity: Float
    var idleGazeTargets: [String]
}

/// Visual identity tokens (§5 "visualTokens"): shape language + palette.
nonisolated struct VisualTokens: Codable, Sendable, Equatable {
    /// "circle" | "square" | "blob" | "circle+triangle"
    var dominantShape: String
    var accentShape: String
    /// Palette hex strings, on black. Order: primary, secondary, deep.
    var palette: [String]
    var silhouetteWeights: SilhouetteWeights
}

nonisolated struct SilhouetteWeights: Codable, Sendable, Equatable {
    var roundness: Float
    var angularity: Float
}

/// PersonalityProfile (§5): one JSON per archetype, frozen at end of A1
/// (schema v1). Breaking changes require migration notes (§10).
nonisolated struct PersonalityProfile: Codable, Sendable, Equatable {
    var id: String
    var traitVector: TraitVector
    var motionProfile: MotionProfile
    var gazeProfile: GazeProfile
    var visualTokens: VisualTokens
    var gesturePoolWeights: [String: Float]
    var quirks: [String]
    /// Asset-set semantic version (§10); the engine pins to the bundle version.
    var assetVersion: String

    static func load(_ archetype: Archetype, bundle: Bundle = .main) throws -> PersonalityProfile {
        guard let url = bundle.url(forResource: "profile_\(archetype.rawValue)", withExtension: "json", subdirectory: "AvatarAssets")
            ?? bundle.url(forResource: "profile_\(archetype.rawValue)", withExtension: "json") else {
            throw ProfileError.missingProfile(archetype.rawValue)
        }
        do {
            return try JSONDecoder().decode(PersonalityProfile.self, from: Data(contentsOf: url))
        } catch {
            throw ProfileError.invalidJSON(archetype.rawValue, error)
        }
    }
}

nonisolated enum ProfileError: Error, Sendable {
    case missingProfile(String)
    case invalidJSON(String, any Error)
}
