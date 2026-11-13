import Foundation

/// The five personality archetypes (§5). One shared skeleton; each archetype
/// contributes a PersonalityProfile + ArchetypeVisualSet.

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

// MARK: - Schema v2 (A5a: unified cloud-species, additive)

/// Species tint + token stack (schema-frozen at assetVersion 2.0.0).
/// v9/v10 reality (Tools/PIXEL_DESIGN.md v3): each archetype is one flat
/// animal icon — `bodyLight` is the ONE body hue, `face` the ink, and
/// accentA/accentB are the transient tell accents (sparks / flicker swap).
/// `bodyMid`, `shadow` and `glow` are legacy v3-v8 fields: kept in the
/// frozen schema, unused by the flat painter.
nonisolated struct SpeciesTokens: Codable, Sendable, Equatable {
    /// The ONE flat body hue of the animal icon.
    var bodyLight: String
    /// Legacy v3-v8 mid body mass — frozen, unused by the v9 flat painter.
    var bodyMid: String
    /// Legacy v3-v8 deep shade — frozen, unused by the v9 flat painter.
    var shadow: String
    /// Ink: eyes/mouth/brows + beak/nose anchors.
    var face: String
    /// Transient accent A: spark particles (Ember) + flicker tell source.
    var accentA: String
    /// Transient accent B: the flicker tell's swap target (Prism).
    var accentB: String?
    /// Legacy v3-v8 interior glow — frozen, unused by the v9 flat painter.
    var glow: String?
}

/// Motion grammar (v3 §0 grammar layer; consumed by the engine from A5b on).
nonisolated struct MotionGrammar: Codable, Sendable, Equatable {
    /// 0...1 — residual motion allowed to remain after a gesture settles
    /// (Willow never fully settles: 0; Compass settles exactly: 1).
    var settleComplete: Float
    /// Continuous idle positional wander scale (Nimbus drift).
    var drift: Float
    /// Wind-up strength before a gesture, 0...1 (Ember high, Willow none,
    /// Prism varied, Compass minimal).
    var anticipation: Float
}

/// Gaze policy (v3 §0 grammar; consumed from A5b on — fixation holds,
/// sweeps, detect-then-settle).
nonisolated enum GazePolicy: String, Codable, Sendable {
    case lock            // Ember: locks onto you and shines
    case soft            // Willow: looks near you, long mutual gazes
    case metricSweep     // Compass: lighthouse sweep at metronomic intervals
    case wander           // Prism: inspects corners/hands, double-takes
    case detectThenSettle // Nimbus: fast dart, then the longest settle
    case linger           // Lumen: slow drift toward the light, long holds
}

/// Blink grammar (v3: rate lives in gazeProfile; shape lives here).
nonisolated struct BlinkGrammar: Codable, Sendable, Equatable {
    /// Envelope-length scale (Willow's blinks are watchable; Ember's are
    /// almost missed).
    var durationScale: Float
    /// Rate variance (Nimbus bursts and long stills; Compass near-zero but
    /// never exactly zero — zero-variance blinks read "dead").
    var variance: Float
}

/// The archetype's involuntary micro-behavior (v3 §0 tell; testable at
/// 205x251 pt in the A4 study).
nonisolated enum PersonalityTell: String, Codable, Sendable {
    case spark   // Ember: glowing ash sparks trail big moves
    case leaf    // Willow: catches a falling leaf and puts it back
    case tick    // Compass: one metronome bob of approval
    case flicker // Prism: chromatic shift across accents on delight
    case pulse   // Nimbus: slow luminous wave after any event
    case dust    // Lumen: a single dust mote drifts past (within mote budget)
}

/// The unobserved idle quirk loop (v3 §0 interiority / quirk; data-driven
/// variants like weather mapping arrive behind Phase B/C ports).
nonisolated enum QuirkLoop: String, Codable, Sendable {
    case preen            // Ember: pats its own head before the wrist rises
    case phototropism     // Willow: tilts toward the brightest region
    case alignmentFidget  // Compass: nudges something crooked to symmetry
    case mirrorMoment     // Prism: studies its reflection, adjusts a patch
    case weatherMap       // Nimbus: drift syncs with live weather (port-fed)
    case stargazing       // Lumen: lingers on the brightest cell of the room
}

/// PersonalityProfile (§5): one JSON per archetype, frozen at end of A1
/// (schema v1). Breaking changes require migration notes (§10).
///
/// Schema v2 (A5a) is strictly additive: every new field is optional and the
/// engine defaults when absent, so v1 profiles still load. v1 fields are
/// byte-for-byte unchanged.
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

    // Schema v2 (A5a, unified cloud-species): all optional, additive.
    /// v3 species tint + token stack; nil = v1 palette fallback.
    var speciesTokens: SpeciesTokens?
    /// v3 motion grammar (settle_complete / drift / anticipation).
    var motionGrammar: MotionGrammar?
    /// v3 gaze policy.
    var gazePolicy: GazePolicy?
    /// v3 blink grammar (rate stays in gazeProfile).
    var blink: BlinkGrammar?
    /// v3 involuntary tell.
    var tell: PersonalityTell?
    /// v3 unobserved quirk loop.
    var quirkLoop: QuirkLoop?
    /// v3 voice copy style (future chat surface; metadata only).
    var voiceStyle: String?
    /// Schema v3 (v18 F3 weather-aware personality, additive): per-condition
    /// dials. Absent block = neutral behavior (all 1.0/0) — v2 profiles
    /// still load and behave exactly as before (G8).
    var weatherDials: WeatherDials?

    /// The weather dial for a condition; nil dials (v2 profiles) = neutral.
    func dial(for condition: ConditionClass) -> WeatherDial {
        weatherDials?.dial(for: condition) ?? WeatherDial()
    }

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

/// One condition class's dials (schema v3, F3). All fields default to
/// neutral, so partial blocks are safe.
nonisolated struct WeatherDial: Codable, Sendable, Equatable {
    /// Multiplies the idle quirk rate (tempo) — e.g. sunny Ember is bouncier.
    var tempoScale: Float = 1
    /// Multiplies the glance/wander rate (amplitude) — e.g. wind jitters.
    var amplitudeScale: Float = 1
    /// Biases ambient accent density (mote spawn rate), -1...1.
    var accentBias: Float = 0
    /// Render-time palette hue rotation in degrees (Prism's temperature
    /// swings); 0 = untouched. Kept inside the LUT budget.
    var hueShiftDeg: Float = 0
}

/// Per-condition dial table, keyed by ConditionClass rawValue.
nonisolated struct WeatherDials: Codable, Sendable, Equatable {
    var classes: [String: WeatherDial] = [:]

    /// The dial for a condition; unknown/missing classes are neutral.
    func dial(for condition: ConditionClass) -> WeatherDial {
        classes[condition.rawValue] ?? WeatherDial()
    }
}

nonisolated enum ProfileError: Error, Sendable {
    case missingProfile(String)
    case invalidJSON(String, any Error)
}

// MARK: - Gesture-coupled members (watch target: GestureClip lives in Engine)

extension Archetype {
    /// A5c farewell beat (U9 — peak-end rule): the wrist-drop goodbye is
    /// ONE soft micro-gesture, never a guilt gesture. Small clips only —
    /// no anticipation wind-up, no squash: the session ends warm.
    nonisolated var farewellGesture: GestureClip {
        switch self {
        case .ember: return .wave      // one last wave for the audience
        case .willow: return .nod      // a slow nod, gardener-style
        case .compass: return .nod     // a level acknowledgment
        case .prism: return .wave      // a loose, friendly flip-wave
        case .nimbus: return .nod       // a quiet settle-nod
        case .lumen: return .slowBlink  // a soft night-blink goodbye
        }
    }

    /// The archetype's signature quirk clip (§5 quirks), performed on
    /// long-press (§9 tap/crown/haptic dialogue). Ember's quirk is big, so
    /// its spark-trail emits (§8 accent particles). In Reduce Motion L2 a
    /// body-only quirk (Willow's weight shift) degrades to a face-readable
    /// in-character reaction at the engine level.
    nonisolated var quirkGesture: GestureClip {
        switch self {
        case .ember: return .spin          // "spark-trail on big gestures"
        case .willow: return .shiftWeight  // "leaf sway on weight shift"
        case .compass: return .lookAround  // "metronomic saccade rhythm"
        case .prism: return .doubleTake    // "double-take gaze"
        case .nimbus: return .shiver       // "reactive micro-startles"
        case .lumen: return .sparkle       // "luminous wing shimmer" (spark-class)
        }
    }
}
