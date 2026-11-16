import Foundation
import CoreGraphics

/// ToySpec (v3 "Companion Cast", doc §5.2/§5.3): one soft-toy vector animal.
/// The MEASURABLE cuteness grammar is pinned here as data:
/// - baby schema: head diameter ≈ 55% of the figure height, eye diameter
///   ≈ 30% of the head width (the caretaking trigger, not taste);
/// - three body colors + one family accent (shape language canon);
/// - one exaggerated identity shape per animal (the silhouette test).
/// The proportion contract is enforced by CompanionToyTests; the anti-rules
/// (no sharp corners — every part's corners radius >= 10% of its smaller
/// dimension; no teeth, no claws, no gray-on-gray) live in PuppetDrawing.
nonisolated struct ToySpec: Sendable, Equatable {
    let archetype: Archetype

    // MARK: palette (3 body tones + ink + accent; doc §5.3)

    /// The main body fill (the hue the family reads as).
    let bodyHex: String
    /// The light belly/face patch (focal glow — lightest values live on the
    /// face and belly).
    let bellyHex: String
    /// Two-tone depth where shapes overlap (never a full ramp).
    let shadeHex: String
    /// Ink: eye pupils (darkened in code), mouth, ear inner tone anchor.
    let inkHex: String
    /// The family accent (cheeks, accessory, identity details).
    let accentHex: String
    /// The UI chrome accent (family hue for discs, rings, buttons).
    let uiAccentHex: String

    // MARK: identity shape dials (author space: 1000x1000, feet y≈880)

    /// Head circle diameter (~520 = the baby-schema contract).
    let headDiameter: CGFloat
    /// Eye diameter as a fraction of the head diameter (>= 0.30 pinned).
    let eyeRatio: CGFloat
    /// Ear height (0 = no external ears — Nimbus; Lumen wears antennae).
    let earHeight: CGFloat
    /// Ear base width.
    let earWidth: CGFloat
    /// Ear outward splay (radians).
    let earSplay: CGFloat
    /// Identity tail: none / brush / curl / nub / slim / fan.
    let tailKind: TailKind
    /// Wings: none / oneSwept (Nimbus) / mothPair (Lumen).
    let wingKind: WingKind
    /// Body bean dimensions (the corgi loaf is wider and flatter).
    let bodyWidth: CGFloat
    let bodyHeight: CGFloat
    /// Nimbus's tiny head crest (the bird's silhouette tell besides the wing).
    let crest: Bool
    /// Willow's cheek ruff discs.
    let ruff: Bool
    /// Compass's marmalade saddle.
    let saddle: Bool
    /// Prism's wrinkle shade rows.
    let wrinkleRows: Bool
    /// Ember's cream muzzle patch.
    let muzzle: Bool
    /// Nimbus's accent beak bump.
    let beak: Bool
    /// Lumen's antennae.
    let antennae: Bool

    nonisolated enum TailKind: Sendable, Equatable {
        case none, brush, curl, nub, slim, fan
    }

    nonisolated enum WingKind: Sendable, Equatable {
        case none, oneSwept, mothPair
    }

    /// The dark glossy pupil tone: family ink pushed 60% toward black (the
    /// face grammar's "dark round pupil" — a structural color, not a body
    /// tone, so it is derived and pinned, not authored twice).
    nonisolated var pupilHex: String { ColorHex.mix(inkHex, "141010", t: 0.6) }

    nonisolated var hasTail: Bool { tailKind != .none }
    nonisolated var hasWings: Bool { wingKind != .none }
}

/// The v3 cast registry: five pets + lumen, one spec each. Colors are the
/// doc's exact §5.3 plan; lumen keeps its v43 lavender family (the app's
/// night identity) re-expressed as a soft toy.
nonisolated enum CompanionToys {
    static func spec(for archetype: Archetype) -> ToySpec {
        switch archetype {
        case .ember:
            return ToySpec(
                archetype: .ember,
                bodyHex: "FF7A45", bellyHex: "FFE8D1", shadeHex: "E8601F",
                inkHex: "4A2C1E", accentHex: "76C893", uiAccentHex: "FF7A45",
                headDiameter: 520, eyeRatio: 0.30,
                earHeight: 255, earWidth: 138, earSplay: 0.44,
                tailKind: .brush, wingKind: .none,
                bodyWidth: 560, bodyHeight: 300, crest: false,
                ruff: false, saddle: false, wrinkleRows: false,
                muzzle: true, beak: false, antennae: false)
        case .willow:
            return ToySpec(
                archetype: .willow,
                bodyHex: "FFF3DC", bellyHex: "FFFDF2", shadeHex: "F0B060",
                inkHex: "5C3A28", accentHex: "FFB7C5", uiAccentHex: "F0B060",
                headDiameter: 540, eyeRatio: 0.30,
                earHeight: 165, earWidth: 112, earSplay: 0.32,
                tailKind: .curl, wingKind: .none,
                bodyWidth: 560, bodyHeight: 300, crest: false,
                ruff: true, saddle: false, wrinkleRows: false,
                muzzle: false, beak: false, antennae: false)
        case .compass:
            return ToySpec(
                archetype: .compass,
                bodyHex: "FFFDF7", bellyHex: "FFFDF7", shadeHex: "FFA02E",
                inkHex: "8A8578", accentHex: "4FC1C0", uiAccentHex: "FFA02E",
                headDiameter: 500, eyeRatio: 0.31,
                earHeight: 195, earWidth: 235, earSplay: 0.62,
                tailKind: .nub, wingKind: .none,
                bodyWidth: 660, bodyHeight: 238, crest: false,
                ruff: false, saddle: true, wrinkleRows: false,
                muzzle: false, beak: false, antennae: false)
        case .prism:
            return ToySpec(
                archetype: .prism,
                bodyHex: "FFC9A8", bellyHex: "FFE8DC", shadeHex: "D89B85",
                inkHex: "3E2A33", accentHex: "8FE3C8", uiAccentHex: "D89B85",
                headDiameter: 520, eyeRatio: 0.30,
                earHeight: 350, earWidth: 240, earSplay: 0.55,
                tailKind: .slim, wingKind: .none,
                bodyWidth: 560, bodyHeight: 300, crest: false,
                ruff: false, saddle: false, wrinkleRows: true,
                muzzle: false, beak: false, antennae: false)
        case .nimbus:
            return ToySpec(
                archetype: .nimbus,
                bodyHex: "F2F2F0", bellyHex: "FCFCFB", shadeHex: "9AA3AE",
                inkHex: "2E3138", accentHex: "FFD166", uiAccentHex: "9AA3AE",
                headDiameter: 480, eyeRatio: 0.32,
                earHeight: 0, earWidth: 0, earSplay: 0,
                tailKind: .fan, wingKind: .oneSwept,
                bodyWidth: 520, bodyHeight: 280, crest: true,
                ruff: false, saddle: false, wrinkleRows: false,
                muzzle: false, beak: true, antennae: false)
        case .lumen:
            return ToySpec(
                archetype: .lumen,
                bodyHex: "A78BFA", bellyHex: "F5F4EF", shadeHex: "6D5BD0",
                inkHex: "171226", accentHex: "FFE9A8", uiAccentHex: "A78BFA",
                headDiameter: 470, eyeRatio: 0.31,
                earHeight: 0, earWidth: 0, earSplay: 0,
                tailKind: .none, wingKind: .mothPair,
                bodyWidth: 500, bodyHeight: 270, crest: false,
                ruff: false, saddle: false, wrinkleRows: false,
                muzzle: false, beak: false, antennae: true)
        }
    }

    // MARK: - Keep mechanics (doc §5.7)

    /// Visible growth: the companion gains up to 5% size across bond
    /// levels 1...5 (0.0125 per level) — your fox is not my fox.
    nonisolated static func growthScale(bondLevel: Int) -> CGFloat {
        let level = min(max(bondLevel, 1), 5)
        return CGFloat(1.0 + 0.0125 * Double(level - 1))
    }

    /// The accessory ladder (doc's five, re-hung on the 5-level bond system
    /// so each crossing is a visible reward): 2 bandana, 3 collar, 4 charm,
    /// 5 bell. The latest unlocked is worn.
    nonisolated static func accessory(bondLevel: Int) -> PuppetAccessory? {
        switch min(max(bondLevel, 1), 5) {
        case 2: return .bandana
        case 3: return .collar
        case 4: return .charm
        case 5: return .bell
        default: return nil
        }
    }

    /// Unlocks at/above the given level (the ceremony hint copy).
    nonisolated static func accessoryName(_ accessory: PuppetAccessory) -> String {
        switch accessory {
        case .bandana: return String(localized: "toy.bandana")
        case .collar: return String(localized: "toy.collar")
        case .charm: return String(localized: "toy.charm")
        case .bell: return String(localized: "toy.bell")
        }
    }
}

/// The accessory a companion can wear (accent-colored, drawn by the puppet).
nonisolated enum PuppetAccessory: String, Sendable, Equatable, CaseIterable {
    case bandana, collar, charm, bell
}
