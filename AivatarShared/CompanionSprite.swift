import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// v13 — AUTHORED PIXEL SPRITES (the source of truth for the companion's
/// look, Tools/PIXEL_DESIGN.md v5).
///
/// The v5-v12 pipeline rasterized vector primitives into a pixel grid
/// ("vector art in a pixel costume" — the avatar never read as authored
/// pixel art). v13 inverts the pipeline: each animal is HAND-AUTHORED on a
/// 20x18 cell grid as string rows over a 5-symbol ramp, mirroring the
/// measured grammar of real authored pixel mascots (the Mistral cat):
///
/// - 5 token ramp per species: `K` ink, `D` shade, `B` body, `W` paper,
///   `A` accent (identity or event) — NO gradients, NO outline, NO dither.
/// - Silhouette first: one identity anchor per animal (fox ears + tail /
///   frog eye domes + smile / fish fin fan / chameleon casque + coil /
///   bird beak + one wing) separated from the body by negative space.
/// - The face is the avatar: uniform eye style — a 2x eye block with a
///   `W` catchlight in the upper-left corner next to `K` ink, 2 cells wide.
/// - 2-tone depth only: `D` where shapes overlap or at the underside,
///   `W` at the belly — never a full ramp.
///
/// Animation (see SpriteDirector) is DISCRETE POSES on a 150 ms clock, not
/// continuous transforms: every "frame" is the `idle` grid plus a hand-
/// authored PATCH of a few cells (blink = 4 cells, a quirk = 2-8 cells —
/// the same deltas-per-frame class as the reference sprite). The engine,
/// rig and vector rasterizer stay frozen (schema untouched) — this layer
/// replaces only the LIVE presentation.
nonisolated struct CompanionSprite: Sendable, Equatable {

    static let gridWidth = 20
    static let gridHeight = 18

    let archetype: Archetype

    /// One absolute cell change applied (in order) over the idle grid.
    /// Symbol "." clears the cell — patches are full authored micro-poses.
    /// `alpha` (Aivatar 2.0 transient overlays, e.g. the level-5 memento
    /// deposit's 4-tick stepped appearance): 1 = full; the renderer draws
    /// sub-1 cells individually instead of in the batched symbol path.
    nonisolated struct CellDiff: Sendable, Equatable {
        let x: Int
        let y: Int
        let symbol: Character
        var alpha: Float

        init(_ x: Int, _ y: Int, _ symbol: Character, alpha: Float = 1) {
            self.x = x
            self.y = y
            self.symbol = symbol
            self.alpha = alpha
        }
    }

    /// Frame vocabulary shared by every animal (the cat's grammar):
    /// `idle` (base), `breathe` (the 2-cell life floor), `idleA`/`idleB`
    /// (slow drift variants — never perfectly still), `blink`, `sleepy`
    /// (heavy lids — the always-on rest face), `happy` (closed eyes +
    /// smile), `glanceL` / `glanceR` (touch-gaze / mote-chase: the eye
    /// block slides one cell), `quirk` (the species' signature move),
    /// `perk` (the alert pose — also the 1-tick wind-up before a quirk),
    /// `yawn` (after a long unattended stretch).
    static let frameIDs = ["idle", "breathe", "idleA", "idleB", "blink", "sleepy",
                           "happy", "glanceL", "glanceR", "quirk", "perk", "yawn"]

    let base: [String]
    let patches: [String: [CellDiff]]
    /// Ramp token -> hex string. Exactly 5 tokens per species.
    let paletteHex: [Character: String]

    /// v40 HD pet pass: when set, renderers draw this asset image
    /// (aspect-fit into the 20x15 cell box above the ground tile) and
    /// animate it with PetMotion poses + puppet regions — the
    /// HD art has no cell-level poses. `base` remains as the deterministic
    /// auto-downsampled fallback (postcard, complication icon, tests).
    let imageAssetName: String?
    /// UI accent for image-backed sprites (selection ring, disc): the
    /// downsampled palette's body tone is muddy, so the vivid accent is
    /// authored separately.
    let accentHexOverride: String?

    init(archetype: Archetype, base: [String], patches: [String: [CellDiff]],
         paletteHex: [Character: String], imageAssetName: String? = nil,
         accentHexOverride: String? = nil,
         puppetHead: PuppetRegion? = nil, puppetTail: PuppetRegion? = nil) {
        self.archetype = archetype
        self.base = base
        self.patches = patches
        self.paletteHex = paletteHex
        self.imageAssetName = imageAssetName
        self.accentHexOverride = accentHexOverride
        self.puppetHead = puppetHead
        self.puppetTail = puppetTail
    }

    nonisolated var isImageBacked: Bool { imageAssetName != nil }
    nonisolated var uiAccentHex: String { accentHexOverride ?? paletteHex["B"] ?? "FF9E4A" }

    /// v42: a puppeteered region of the HD image (head / tail), normalized
    /// 0...1 in image space (y-down). The renderer redraws the region on top
    /// of the body with its own small rotation/bob (see PetMotion.Pose), so
    /// the animal reads as a creature, not a sticker. Nil for grid sprites.
    nonisolated struct PuppetRegion: Sendable, Equatable {
        var rect: CGRect      // normalized, y-down
        var anchor: CGPoint   // normalized pivot, y-down
    }

    let puppetHead: PuppetRegion?
    let puppetTail: PuppetRegion?

    // MARK: - Resolution

    /// Resolves a frame id to the 20x18 symbol grid (idle + patch), then
    /// applies the session's interiority overlay (memory-made-visible:
    /// sprout / week grid / trinket). Unknown ids fall back to the idle
    /// pose — an unknown gesture name can never draw a blank stage.
    func symbols(frameID: String, overlay: [CellDiff] = []) -> [[Character]] {
        var grid: [[Character]] = base.map { Array($0) }
        let diffs = (patches[frameID] ?? []) + overlay
        for diff in diffs {
            guard diff.x >= 0, diff.x < Self.gridWidth,
                  diff.y >= 0, diff.y < Self.gridHeight else { continue }
            grid[diff.y][diff.x] = diff.symbol
        }
        return grid
    }

    /// The persistent traces the companion kept while unobserved (A5d),
    /// re-expressed as authored cells on the sprite grid — memory is an
    /// input, so these compose with any frame deterministically.
    func interiorityDiffs(_ t: InteriorityTuning) -> [CellDiff] {
        var diffs: [CellDiff]
        switch archetype {
        case .willow:
            // The tended sprout on top of the head, between the domes.
            guard t.sproutGrowth >= 0.6 else { diffs = [] ; break }
            diffs = [CellDiff(10, 0, "A")]
            if t.sproutGrowth >= 1.0 { diffs.append(CellDiff(11, 0, "A")) }
        case .compass:
            // The audit week: up to 7 cells under the body, lit days in
            // accent, pending days in ink.
            guard t.streakDays > 0 else { diffs = [] ; break }
            diffs = (0..<7).map { CellDiff(5 + $0, 14, $0 < min(t.streakDays, 7) ? "A" : "K") }
        case .prism:
            // The found trinket, held beside the head.
            diffs = t.trinketPresent ? [CellDiff(12, 4, "A"), CellDiff(12, 5, "A")] : []
        default:
            diffs = []
        }
        // v16 F1: the confidant memento — one accent cell below the body
        // (cell 9,16 is empty in every base grid; pinned by test).
        if t.confidantMemento { diffs.append(CellDiff(9, 16, "A")) }
        return diffs
    }

    /// Rotates a palette hex's hue by `degrees` (HSV space, saturation and
    /// value preserved — the value-locked ramp keeps its luminance ordering,
    /// so the family read and the LUT budget survive). v18 F3: Prism's
    /// temperature swings ride this; 0/360 = identity. Pure and testable.
    static func hueRotated(_ hex: String, degrees: Double) -> String {
        let (r, g, b) = hexToRGB(hex)
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let vMax = max(rf, gf, bf), vMin = min(rf, gf, bf)
        let d = vMax - vMin
        var h = 0.0
        if d > 0 {
            if vMax == rf { h = (gf - bf) / d + (gf < bf ? 6 : 0) }
            else if vMax == gf { h = (bf - rf) / d + 2 }
            else { h = (rf - gf) / d + 4 }
            h *= 60
        }
        let s = vMax == 0 ? 0 : d / vMax
        var nh = (h + degrees).truncatingRemainder(dividingBy: 360)
        if nh < 0 { nh += 360 }
        // HSV: chroma C = V*S = d, and m = V - C = vMin.
        let c = d
        let x = c * (1 - abs(nh.truncatingRemainder(dividingBy: 120) / 60 - 1))
        let m = vMin
        var rgb: (Double, Double, Double)
        switch nh {
        case 0..<60: rgb = (c, x, 0)
        case 60..<120: rgb = (x, c, 0)
        case 120..<180: rgb = (0, c, x)
        case 180..<240: rgb = (0, x, c)
        case 240..<300: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        func to8(_ v: Double) -> UInt8 {
            UInt8(min(255, max(0, (v + m) * 255)).rounded())
        }
        return String(format: "%02X%02X%02X", to8(rgb.0), to8(rgb.1), to8(rgb.2))
    }

    /// Parses a 6-digit hex string (with or without '#') into 8-bit RGB.
    static func hexToRGB(_ hex: String) -> (r: UInt8, g: UInt8, b: UInt8) {
        var value: UInt64 = 0
        var digits: [UInt64] = []
        for c in hex where c.isHexDigit {
            if let d = UInt64(String(c), radix: 16) { digits.append(d) }
        }
        if digits.count >= 6 {
            value = (digits[digits.count - 6] << 20) | (digits[digits.count - 5] << 16)
                    | (digits[digits.count - 4] << 12) | (digits[digits.count - 3] << 8)
                    | (digits[digits.count - 2] << 4) | digits[digits.count - 1]
        }
        return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }
}

/// The five authored animals. Category anchors (PIXEL_DESIGN.md v5 §1):
/// Ember = fox (pointed ears + muzzle + white-tipped tail), Willow = frog
/// (dome eyes on top + the wide smile), Compass = fish (dorsal + tail
/// fan — side profile is the fish's silhouette), Nimbus = bird (beak +
/// ONE swept wing — asymmetry reads alive), Prism = chameleon (casque +
/// turret eye + the curled coil with a negative-space hole).
typealias CellDiff = CompanionSprite.CellDiff

nonisolated enum AuthoredSprites {

    static func sprite(for archetype: Archetype) -> CompanionSprite {
        switch archetype {
        case .ember: return ember
        case .willow: return willow
        case .compass: return compass
        case .prism: return prism
        case .nimbus: return nimbus
        case .lumen: return lumen
        }
    }

    // MARK: v40 HD PETS — the five companions are cut from the authored
    // HD pet sheet (avatars/, cut into avatars/cut/pet-*.png and shipped as
    // imagesets `pet-<name>` in both app catalogs). The 20x18 grids below
    // are deterministic auto-downsamples of the same art: they keep every
    // grid consumer working (postcard, complication icon, tests) as a
    // pixel-honest fallback; the live stage/picker/phone draw the HD image.

    static let petFoxGrid: [String] = [
    "WK......KWW.........",
    "BA.....ABBW.........",
    "BBDK..DAWBW.........",
    "WBADDDDWDBW.........",
    "DBWADDAWBW..........",
    ".WAAAAAWW...........",
    "..AAAKAAK...........",
    "..WWWWWW............",
    "...WBBAKKDDD........",
    "...BBWKKKDDDAA......",
    "...KKKAAAKDDAAA.KDD.",
    "....WWWAAKDADAAADDK.",
    "....BBWAKBAADDAAAKKK",
    ".....DDADDWAADDAAAKK",
    ".....BBADDDWADDDDDKK",
    ".....BBW.D..WB.DDDK.",
    ".....BWW.D..WA......",
    ".....WWW....WK......",
]
    static let petFoxPalette: [Character: String] = [
    "K": "4E3023",
    "D": "AB724E",
    "B": "C59D8A",
    "W": "F2E1C5",
    "A": "E9B575",
]

    static let petMockingbirdGrid: [String] = [
    ".WW.................",
    "KWKWD...............",
    "KKKKW...............",
    "KKKKKW.......AAAA...",
    "WKKKKKK.....AAWAAKK.",
    "WWKKKKK....KAAAABK..",
    ".WWKKKK....AAAWBB...",
    ".WWDKKKK.DDADABBB...",
    "..WWAKDDDDDDDDBBB...",
    "....WDDDKKKKKWBBB...",
    ".....DDDWKKKKWWWW...",
    ".....DDDKWWAWWWWW...",
    ".....KKKKAAWWWWA..D.",
    "....KKKKAAAAAA...DD.",
    "....KKKK.KKDKKK.DDKD",
    "..........KK.KKKDKKD",
    "..........KKDKKK....",
    "..........KKKKKKK...",
]
    static let petMockingbirdPalette: [Character: String] = [
    "K": "373B44",
    "D": "77757B",
    "B": "C3C1BF",
    "W": "E4E9ED",
    "A": "959CA8",
]

    static let petShibaGrid: [String] = [
    ".........KAK....AWA.",
    ".........AWAAAAAAAW.",
    ".........AAAAAAAAAA.",
    ".........AAAAKAAAAAA",
    ".........AAWWWWWKKWW",
    ".KWWWWWW.AWWWWWWBWWB",
    ".WAAAAAW.AAAWWWBBBA.",
    ".WAAAAAAKAKKKWWWBKA.",
    ".WAAADDKDAAAKKKKKWAB",
    ".KAAADKDDDDDAWWBBAAA",
    ".AAAAAKDDDDDDDWWWDB.",
    ".AAAAWKKDDDDDDDWKDD.",
    ".AAAWBBBBDDDDKBDDD..",
    ".AAWB.BBBDDDD.AAAD..",
    "AWWK..BBBKAAA.BBA...",
    "WWW...BBB.AAA.BWA...",
    "WW.....BB.WWA..WW...",
    "WW.........WW..WW...",
]
    static let petShibaPalette: [Character: String] = [
    "K": "483327",
    "D": "31546E",
    "B": "B49A81",
    "W": "F0E1C7",
    "A": "CA8746",
]

    static let petCorgiGrid: [String] = [
    ".......AAK......AAA.",
    ".......BBAA....AABB.",
    ".......BBBAAAWAAABB.",
    ".......ABBAAAWAAABA.",
    ".......KAAAAAAWAAAA.",
    ".....DDDDAAAAWWWAAA.",
    "..WW.DDDAWWWWWKWWWA.",
    ".WWA.DDKAAWWWWAKWWA.",
    ".AAAADDKAAAWWBBBWABB",
    ".AAADDDDAAKWWWWWWADB",
    "AAAADDDKAAWWDDDWWAWW",
    "AAAAADDAAAWWWWBBWADD",
    "AAAAAADAAAWWWWWWBK..",
    "AAAABAKAAAABBWWBB...",
    "KAWWBBBBAAABBBBA....",
    ".WWW.BBBWWWWBBWW....",
    ".WWW..BBWWWW.BWW....",
    ".........WWW..WW....",
]
    static let petCorgiPalette: [Character: String] = [
    "K": "392718",
    "D": "766E45",
    "B": "C9A48E",
    "W": "F1E5CC",
    "A": "DF924B",
]

    static let petSphynxGrid: [String] = [
    ".......DWD.......DDD",
    ".......WWDDD...DDDWW",
    ".......DWWDDBBBBDWWD",
    ".......KDDDBBBBBBDW.",
    "........DDBABBBAABD.",
    ".........KDBBBBBBD..",
    "..........WDDDDDD...",
    ".........WWWWWDWD...",
    ".......BBBWWWWWWW...",
    ".....BBBBBBBWWAWW...",
    "...BBBBBBBBBBBBBB...",
    "..BBBBBBBBBBBBBBB...",
    ".BBBBBBBBBBBDDDBK...",
    ".BBBBBBDBBBDDDDB....",
    "BBBBBBBDDBBDDDBD....",
    "BBBBBBBDDBBDDDB.....",
    "BBBBBBBBDDBDDDB.....",
    "BBBBBBDBDDBBDBB.....",
]
    static let petSphynxPalette: [Character: String] = [
    "K": "2F2624",
    "D": "614F53",
    "B": "87797E",
    "W": "BC966A",
    "A": "53B1A0",
]

    // MARK: The five companions (image-backed)

    static let ember = CompanionSprite(
        archetype: .ember,
        base: petFoxGrid,
        // v40/v42: the HD image animates via PetMotion (ambient + act
        // envelopes + head/tail puppet regions); the grid is the static fallback.
        patches: [:],
        paletteHex: petFoxPalette,
        imageAssetName: "pet-fox",
        accentHexOverride: "FFC800",
        puppetHead: CompanionSprite.PuppetRegion(rect: CGRect(x: 0.00, y: 0.00, width: 0.58, height: 0.62), anchor: CGPoint(x: 0.52, y: 0.58)),
        puppetTail: CompanionSprite.PuppetRegion(rect: CGRect(x: 0.55, y: 0.42, width: 0.45, height: 0.35), anchor: CGPoint(x: 0.60, y: 0.62))
    )

    static let willow = CompanionSprite(
        archetype: .willow,
        base: petShibaGrid,
        // v40/v42: the HD image animates via PetMotion (ambient + act
        // envelopes + head/tail puppet regions); the grid is the static fallback.
        patches: [:],
        paletteHex: petShibaPalette,
        imageAssetName: "pet-shiba",
        accentHexOverride: "6FA0FF",
        puppetHead: CompanionSprite.PuppetRegion(rect: CGRect(x: 0.22, y: 0.00, width: 0.62, height: 0.52), anchor: CGPoint(x: 0.52, y: 0.50)),
        puppetTail: CompanionSprite.PuppetRegion(rect: CGRect(x: 0.00, y: 0.32, width: 0.35, height: 0.30), anchor: CGPoint(x: 0.32, y: 0.55))
    )

    static let compass = CompanionSprite(
        archetype: .compass,
        base: petCorgiGrid,
        // v40/v42: the HD image animates via PetMotion (ambient + act
        // envelopes + head/tail puppet regions); the grid is the static fallback.
        patches: [:],
        paletteHex: petCorgiPalette,
        imageAssetName: "pet-corgi",
        accentHexOverride: "5FAE4A",
        puppetHead: CompanionSprite.PuppetRegion(rect: CGRect(x: 0.28, y: 0.00, width: 0.62, height: 0.55), anchor: CGPoint(x: 0.58, y: 0.52)),
        puppetTail: CompanionSprite.PuppetRegion(rect: CGRect(x: 0.00, y: 0.30, width: 0.28, height: 0.25), anchor: CGPoint(x: 0.26, y: 0.50))
    )

    static let prism = CompanionSprite(
        archetype: .prism,
        base: petSphynxGrid,
        // v40/v42: the HD image animates via PetMotion (ambient + act
        // envelopes + head/tail puppet regions); the grid is the static fallback.
        patches: [:],
        paletteHex: petSphynxPalette,
        imageAssetName: "pet-sphynx",
        accentHexOverride: "2ED3C6",
        puppetHead: CompanionSprite.PuppetRegion(rect: CGRect(x: 0.15, y: 0.00, width: 0.72, height: 0.45), anchor: CGPoint(x: 0.50, y: 0.42)),
        puppetTail: CompanionSprite.PuppetRegion(rect: CGRect(x: 0.62, y: 0.72, width: 0.38, height: 0.28), anchor: CGPoint(x: 0.68, y: 0.75))
    )

    static let nimbus = CompanionSprite(
        archetype: .nimbus,
        base: petMockingbirdGrid,
        // v40/v42: the HD image animates via PetMotion (ambient + act
        // envelopes + head/tail puppet regions); the grid is the static fallback.
        patches: [:],
        paletteHex: petMockingbirdPalette,
        imageAssetName: "pet-mockingbird",
        accentHexOverride: "FFE066",
        puppetHead: CompanionSprite.PuppetRegion(rect: CGRect(x: 0.52, y: 0.05, width: 0.48, height: 0.55), anchor: CGPoint(x: 0.60, y: 0.55)),
        puppetTail: CompanionSprite.PuppetRegion(rect: CGRect(x: 0.00, y: 0.00, width: 0.55, height: 0.65), anchor: CGPoint(x: 0.52, y: 0.60))
    )

    // MARK: LUMEN — moth (Aivatar 2.0, E10; night element, luminous)

    static let lumen = CompanionSprite(
        archetype: .lumen,
        base: [
            "......A.K..K.A......",
            ".......KBBB.K.......",
            ".......WKBBWK.......",
            ".......KKBBKK.......",
            "...BBB.BBBBB..BBB...",
            "..BBBBB.BBB..BBBBB..",
            ".BBBBBBB.BB.BBBBBBB.",
            ".BBBBBBB.BB.BBBBBBB.",
            "BBBBBBBB.BB.BBBBBBBB",
            ".BBBBBBB.BB.BBBBBBB.",
            ".BBBBBBB.BB.BBBBBBB.",
            "..DDDDD..BB..DDDDD..",
            "...BBB...DD...BBB...",
            ".........DD.........",
            "....................",
            "....................",
            "....................",
            "...................."
        ],
        patches: [
            "blink": [ CellDiff(7, 2, "B"), CellDiff(8, 2, "B"),
                      CellDiff(11, 2, "B"), CellDiff(12, 2, "B") ],  // catchlight row closes; ink lid line stays
            "sleepy": [ CellDiff(7, 2, "D"), CellDiff(8, 2, "D"), CellDiff(7, 3, "B"), CellDiff(8, 3, "B"),
                        CellDiff(11, 2, "D"), CellDiff(12, 2, "D"), CellDiff(11, 3, "B"), CellDiff(12, 3, "B") ],
            "happy": [ CellDiff(7, 2, "B"), CellDiff(8, 2, "B"), CellDiff(7, 3, "B"), CellDiff(8, 3, "B"),
                       CellDiff(11, 2, "B"), CellDiff(12, 2, "B"), CellDiff(11, 3, "B"), CellDiff(12, 3, "B"),
                       CellDiff(9, 4, "K"), CellDiff(10, 4, "K") ],  // closed eyes + smile
            "glanceL": [ CellDiff(8, 2, "B"), CellDiff(8, 3, "B"), CellDiff(6, 2, "W"), CellDiff(7, 2, "K"),
                         CellDiff(6, 3, "K"), CellDiff(7, 3, "K"),
                         CellDiff(12, 2, "B"), CellDiff(12, 3, "B"), CellDiff(10, 2, "W"), CellDiff(11, 2, "K"),
                         CellDiff(10, 3, "K"), CellDiff(11, 3, "K") ],
            "glanceR": [ CellDiff(7, 2, "B"), CellDiff(7, 3, "B"), CellDiff(8, 2, "W"), CellDiff(9, 2, "K"),
                         CellDiff(8, 3, "K"), CellDiff(9, 3, "K"),
                         CellDiff(11, 2, "B"), CellDiff(11, 3, "B"), CellDiff(13, 2, "W"), CellDiff(12, 2, "K"),
                         CellDiff(13, 3, "K"), CellDiff(12, 3, "K") ],
            // the signature quirk: a luminous shimmer wave across the wings
            "quirk": [ CellDiff(2, 6, "A"), CellDiff(3, 7, "A"), CellDiff(4, 8, "A"),
                       CellDiff(17, 6, "A"), CellDiff(16, 7, "A"), CellDiff(15, 8, "A") ],
            "perk": [ CellDiff(7, 1, "A"), CellDiff(12, 1, "A") ],  // antennae glow
            "breathe": [ CellDiff(2, 12, "B"), CellDiff(17, 12, "B") ],
            "idleA": [ CellDiff(1, 5, "B") ],
            "idleB": [ CellDiff(18, 5, "B") ],
            "yawn": [ CellDiff(7, 2, "D"), CellDiff(8, 2, "D"), CellDiff(7, 3, "B"), CellDiff(8, 3, "B"),
                      CellDiff(11, 2, "D"), CellDiff(12, 2, "D"), CellDiff(11, 3, "B"), CellDiff(12, 3, "B"),
                      CellDiff(9, 5, "K"), CellDiff(10, 5, "K") ],
        ],
        paletteHex: [
            "B": "A78BFA", "D": "6D5BD0", "K": "171226",
            "W": "F5F4EF", "A": "FFE9A8",
        ]
    )

}



/// IconCuts (Aivatar 2.0, E1): the app icon's source of truth is a GRID, not
/// a drawing. `emberFace` is a hand-authored 32x32 token grid (same 5-symbol
/// ramp as the stage: K ink, D shade, B body, W paper, A accent). 32 is chosen
/// because 1088 / 32 = 34 px per cell, an exact integer — the icon rasterizes
/// nearest-neighbor at every size with zero interpolation. Composition rules
/// (E1.1): head ~19 of 32 cells tall, optically centered; ear triangles
/// >= 5 cells; W catchlight in the left eye block; paper muzzle; A reserved
/// for the two ear-tip cells. No outline, no gradient, no dither.
///
/// The committed PNGs are produced ONLY by Tools/icon_export.swift from these
/// rows (CI hash-pins the output); edit the grid here, never the PNGs.
nonisolated enum IconCuts {
    static let gridWidth = 32
    static let gridHeight = 32

    /// Ember fox head, 32x32. Rows are top-to-bottom, '.' clears a cell.
    static let emberFace: [String] = [
        "................................",
        "................................",
        "................................",
        "........BAB..........BAB........",
        "........BBB..........BBB........",
        "........BBB..........BBB........",
        "........BBB..........BBB........",
        "........BBB..........BBB........",
        ".......BBBBB........BBBBB.......",
        "......BBBBBBBBBBBBBBBBBBBB......",
        "......BBBBBBBBBBBBBBBBBBBB......",
        "......BBBBBBBBBBBBBBBBBBBB......",
        ".....BBBBBBBBBBBBBBBBBBBBBB.....",
        ".....BBBBBBBBBBBBBBBBBBBBBB.....",
        ".....BBBBBBBBBBBBBBBBBBBBBB.....",
        "....BBBBBBBBBBBBBBBBBBBBBBBB....",
        "....BBBBBBBBBBBBBBBBBBBBBBBB....",
        "....BBBBWKBBBBBBBBBWKBBBBBBB....",
        "....BBBBKKBBBBBBBBBKKBBBBBBB....",
        "....BBBBBBBBBBBBBBBBBBBBBBBB....",
        "....BBBBBBBBBBBBBBBBBBBBBBBB....",
        "....BBBBBWWWWWWWWWWWWWWBBBBB....",
        "....BBBBBWWWWWWWWWWWWWWBBBBB....",
        "....BBBBBWWWWWWWWWWWWWWBBBBB....",
        ".....BBBBWWWWWWKKWWWWWWBBBB.....",
        ".....BBBBWWWWWWWWWWWWWWBBBB.....",
        ".....BBBBWWWWWWWWWWWWWWBBBB.....",
        ".......BBBBBDDDDDDDDBBBBB.......",
        "................................",
        "................................",
        "................................",
        "................................",
    ]

    /// The icon grid resolved to symbol cells (validated 32x32).
    static func emberFaceSymbols() -> [[Character]] {
        precondition(emberFace.count == gridHeight)
        return emberFace.map { row in
            precondition(row.count == gridWidth)
            return Array(row)
        }
    }

    /// Ember's stage palette reused for the icon (one hue family, 5 tokens).
    /// The icon keeps its own pinned ramp (the v13 fox-head palette) —
    /// v40 changed the STAGE palette to the downsampled pet art, but the
    /// app icon is hash-pinned by icon_export.swift and must not drift.
    static let emberFacePaletteHex: [Character: String] = [
        "B": "FF9E4A", "D": "C4621B", "K": "241206",
        "W": "F5F4EF", "A": "FFC800",
    ]
}
