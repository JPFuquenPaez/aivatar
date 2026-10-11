import Foundation

/// The gesture clip list (§10 A1 deliverable: shared clip vocabulary; v5b
/// adds one UNIQUE QUIRK CLIP per archetype — the involuntary signature
/// behavior no other archetype performs). Every clip is available to every
/// archetype; the profile's `gesturePoolWeights` sets how likely it is
/// (weight 0 allowed) — CI parity tests enforce this (§10).
nonisolated enum GestureClip: String, Sendable, CaseIterable, Codable {
    case wave
    case bounce
    case stretch
    case spin
    case nod
    case tilt
    case lookAround
    case shiftWeight
    case shiver
    case doubleTake
    case sparkle
    case puff
    // v5b quirk clips — one per archetype, weighted ONLY for its owner.
    case preen       // Ember: head-pat warm-up before the show
    case swayCatch   // Willow: slow sway, catches a falling leaf
    case tick        // Compass: one exact metronome bob
    case mirror      // Prism: freezes, studies itself, flips a color
    case driftFloat  // Nimbus: two-frequency floating wander

    /// Clips the engine treats as "big" (anticipation frames >= 120 ms,
    /// squash & stretch, §7).
    var isBig: Bool {
        switch self {
        case .bounce, .spin, .stretch, .puff, .sparkle, .preen:
            return true
        default:
            return false
        }
    }

    /// Clips whose action phase ends on a full 2*pi turn — visually the
    /// neutral pose. The end-of-clip crossfade holds weight 1 for these so
    /// the 2*pi -> 0 wrap on clip end is seamless (§11 no pose snapping);
    /// fading the weight would unwind the full turn backwards on screen.
    var endsWrapped: Bool {
        switch self {
        case .spin:
            return true
        default:
            return false
        }
    }

    /// Clips that write at least one expression channel. Reduce Motion L2
    /// keeps the body static, so tap reactions must be able to read on the
    /// face alone; the reaction pool is filtered to these clips in L2 (§8).
    var writesExpression: Bool {
        switch self {
        case .wave, .stretch, .spin, .lookAround, .shiver, .doubleTake, .sparkle, .puff,
             .preen, .swayCatch, .tick, .mirror, .driftFloat:
            return true
        case .bounce, .nod, .tilt, .shiftWeight:
            return false
        }
    }
}

/// Per-archetype shape language (§4.2, §5): derived from the frozen
/// visualTokens (dominant shape + accent + silhouette weights) — no schema
/// change. The painter re-authors part geometry over the shared skeleton
/// per family so silhouettes separate (§11 silhouette readability).
nonisolated enum ShapeLanguage: Sendable, Equatable {
    /// Circle-dominant, triangle flame accents (Ember).
    case roundSparks
    /// Circle-dominant, drooping leaf accents (Willow).
    case droopingLeaf
    /// Square-dominant, clean lines (Compass).
    case angularClean
    /// Circle + triangle crystal mix (Prism).
    case crystalMix
    /// Soft blob / cloud forms (Nimbus).
    case softCloud
}

/// ArchetypeVisualSet (§3): palette + shape tokens resolved per archetype plus
/// LOD variants (§6): `active` (full color) and `rest` (dimmed sleep pose).
///
/// v3 (A5a): the five archetypes are one cloud species — the silhouette is
/// deliberately constant; identity is tint -> one trait token -> eye/motion
/// grammar -> tell. The v1 shape-language families remain for the alternate
/// direction in the project's render history; the species path is chosen by
/// `isSpecies` below. A future artist atlas replaces the primitive
/// rasterizer without touching the engine or the renderer contract.
nonisolated struct ArchetypeVisualSet: Sendable, Equatable {
    let archetype: Archetype

    /// Palette roles: primary (torso/limbs), secondary (accents), deep (shade).
    let primaryHex: String
    let secondaryHex: String
    let deepHex: String

    /// Dominant/accent shape language (drives silhouette authoring, §4).
    let dominantShape: String
    let accentShape: String

    /// Resolved geometry family for the painter (§5 shape tokens).
    let shapeLanguage: ShapeLanguage

    /// Ember quirk: spark-trail accent particles on big gestures (§8).
    let emitsSparkTrail: Bool

    /// Face accent color (eyes/mouth), the "where the eye should land" pixels.
    let faceAccentHex: String

    // v3 species tokens (A5a). Nil profile fields fall back to the v1
    // palette so a v1 profile still renders (schema v2 is additive).
    /// The v3 species is live for this visual set.
    let isSpecies: Bool
    let species: SpeciesTokens?
    /// The archetype's involuntary tell (v3 §0; drive logic lands in A5b).
    let tell: PersonalityTell?
    /// The unobserved quirk loop id (v3 §0).
    let quirkLoop: QuirkLoop?

    /// The species has no limbs (U5: never drift humanoid). Whole-body
    /// squash-and-stretch replaces articulated arm gestures; the rig's arm
    /// bones stay in the skeleton (schema-frozen) but paint nothing.
    var isLimbless: Bool { isSpecies }

    init(profile: PersonalityProfile) {
        archetype = Archetype(rawValue: profile.id) ?? .ember
        let palette = profile.visualTokens.palette
        primaryHex = palette.count > 0 ? palette[0] : "#888888"
        secondaryHex = palette.count > 1 ? palette[1] : "#444444"
        deepHex = palette.count > 2 ? palette[2] : "#111111"
        dominantShape = profile.visualTokens.dominantShape
        accentShape = profile.visualTokens.accentShape
        faceAccentHex = secondaryHex
        emitsSparkTrail = profile.quirks.contains("spark-trail on big gestures")
        species = profile.speciesTokens
        tell = profile.tell
        quirkLoop = profile.quirkLoop
        // A profile with species tokens selects the v3 species path; a v1
        // profile (no tokens) keeps its v1 shape language for the alternate
        // direction.
        isSpecies = profile.speciesTokens != nil

        let weights = profile.visualTokens.silhouetteWeights
        switch (dominantShape, accentShape) {
        case ("circle", "triangle") where weights.roundness >= 0.7:
            shapeLanguage = .roundSparks
        case ("circle", "triangle"):
            shapeLanguage = .crystalMix
        case ("circle", "leaf"):
            shapeLanguage = .droopingLeaf
        case ("square", _):
            shapeLanguage = .angularClean
        case ("blob", _):
            shapeLanguage = .softCloud
        default:
            shapeLanguage = .roundSparks
        }
    }

    /// Rest/always-on palette (§6 LOD `rest`): same geometry, dimmed toward
    /// pure black to protect OLED power and HIG luminance guidance.
    static let restPrimaryHex = "#2A2A2A"
    static let restSecondaryHex = "#3C3C3C"
    static let restDeepHex = "#111111"
}
