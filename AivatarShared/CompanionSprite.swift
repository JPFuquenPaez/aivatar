import Foundation

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

    /// AMS v2: the HD pet PORTRAIT asset (avatars/ sheet cuts), used ONLY by
    /// static portrait surfaces (picker disc, naming hero, iPhone card,
    /// postcard front). No surface animates it — the live stage, phone grid
    /// and postcard moment render the authored grid + patches (§5.6
    /// "two skins, one animal": the portrait is a photo OF the companion,
    /// the grid IS the companion).
    let portraitAssetName: String?
    /// UI accent for portrait surfaces (selection ring, disc): authored
    /// separately from the ramp (the family accent, not the body tone).
    let accentHexOverride: String?

    init(archetype: Archetype, base: [String], patches: [String: [CellDiff]],
         paletteHex: [Character: String], portraitAssetName: String? = nil,
         accentHexOverride: String? = nil) {
        self.archetype = archetype
        self.base = base
        self.patches = patches
        self.paletteHex = paletteHex
        self.portraitAssetName = portraitAssetName
        self.accentHexOverride = accentHexOverride
    }

    nonisolated var hasPortrait: Bool { portraitAssetName != nil }
    nonisolated var uiAccentHex: String { accentHexOverride ?? paletteHex["B"] ?? "FF9E4A" }

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

    // MARK: AMS v2 AUTHORED GRIDS (the five pets, P0)
    //
    // v43 (AMS v2): the stage is pixel art again. Each pet is HAND-AUTHORED
    // on the 20x18 cell grid with the full patch grammar (lumen was the
    // literal template) — silhouette-first, uniform eye style (a 2x2 `W K /
    // K K` block, catchlight upper-left, 3-cell glance window), 1-2 mouth
    // cells, family-locked 5-token ramps, and per-animal signature patches
    // (fox: ear flick + tail ride; shiba: head cock + the smile; corgi: stub
    // nub pop + far-ear flick; sphynx: ear twitch + kneading press; bird:
    // wing flick + crest spread). The auto-downsampled v40 grids (HD art in
    // a pixel costume — the second "costume mistake" after v5-v12) are
    // retired; the HD cuts live on as PORTRAITS only (portraitAssetName):
    // picker disc, naming hero, iPhone card, postcard front.

    static let petFoxGrid: [String] = [
        "....A..........A....",
        "....BA........AB....",
        "....BB........BB....",
        "....BBB......BBB....",
        "....BBBBBBBBBBBB....",
        "....BWKBBBBBWKBB....",
        "....BKKBBBBBKKBB....",
        "....BBBBBBBBBBBB....",
        "....BWWWWWWWWWWB....",
        "....BWWWWKKWWWWB....",
        ".....BWWWWWWWWB.....",
        "....BBBBWWWWBBBB....",
        "....BBBBWWWWBBBBDD..",
        "....BBBWWBBBWWBBBDW.",
        "....................",
        "....................",
        "....................",
        "....................",
    ]

    static let petShibaGrid: [String] = [
        ".....A........A.....",
        ".....BB......BB.....",
        ".....BBB....BBB.....",
        "....BBBBBBBBBBBB....",
        "....BBBBBBBBBBBB....",
        "....BWKBBBBBWKBB....",
        "....BKKBBBBBKKBB....",
        "...BBBBBBBBBBBBBB...",
        "...BBWWWWWWWWWWD....",
        "....BWWKWKKWKWWDW...",
        ".....DDDDDDDDDDD....",
        ".....BBBWWWWBBB.....",
        ".....BBBWWWWBBB.....",
        ".....BBWWBBBWWB.....",
        "....................",
        "....................",
        "....................",
        "....................",
    ]

    static let petCorgiGrid: [String] = [
        "..A..A..............",
        "..B.BBB.............",
        "..B.BBB.............",
        ".BBWBBB.............",
        ".BBBWKB.............",
        "KWWWKKB.............",
        ".WWBBBB.............",
        ".KBBBBBBBBBBBBBBW...",
        ".WWWBBBBBBBBBBBBBW..",
        ".WWBBBBBBBBBBBBBB...",
        "..BBBBBBBBBBBBBBB...",
        "..BWWWWWWWWWWWWWB...",
        "..BWWWWWWWWWWWWWB...",
        "..BBWWBBBWWBBBWBB...",
        "....................",
        "....................",
        "....................",
        "....................",
    ]

    static let petSphynxGrid: [String] = [
        "..A..............A..",
        "..BB............BB..",
        "..BBB..........BBB..",
        "..BBBBBBBBBB...BBB..",
        "....DBBBBBBD........",
        "....BWKBBWKB........",
        "....BKKBBKKB........",
        "....BDDBBBDD........",
        "....BBBKKBBB........",
        ".....BBWWWWBB.......",
        ".....BBWWWWBBD......",
        ".....BBBBBBBB.D.....",
        ".....BBBBBBBB.D.....",
        ".....BWWBBWWB.......",
        "....................",
        "....................",
        "....................",
        "....................",
    ]

    static let petMockingbirdGrid: [String] = [
        ".......B............",
        "...BBBBB............",
        "...BBBBB............",
        "DDDBBWKB............",
        ".D.BBKKB............",
        "...BBBBB............",
        "....BBBBDDDBBB......",
        "....BBBBBDDDBBBB....",
        "....BBBBBBDDDBBBBB..",
        "....BBBBBBBDDDBBB...",
        "....BWWWWWBBBB......",
        "....BWWWWWBBBB......",
        ".......K..K.........",
        ".......K..K.........",
        "....................",
        "....................",
        "....................",
        "....................",
    ]

    // Family-locked 5-token ramps (value-ordered: ink < shade < body < paper;
    // accent = the family accent, not a body re-tint). The fox keeps the
    // hash-pinned icon ramp (one hue family across stage + icon + app icon).

    static let petFoxPalette: [Character: String] = [
        "K": "2A1612", "D": "C4621B", "B": "FF9E4A",
        "W": "F5F4EF", "A": "FFC800",
    ]

    static let petShibaPalette: [Character: String] = [
        "K": "2F2118", "D": "C0854B", "B": "F0DFC0",
        "W": "FDF8EC", "A": "6FA0FF",
    ]

    static let petCorgiPalette: [Character: String] = [
        "K": "2E1E12", "D": "9C6B3E", "B": "E19547",
        "W": "F2E9D8", "A": "5FAE4A",
    ]

    static let petSphynxPalette: [Character: String] = [
        "K": "2F2624", "D": "6E4F43", "B": "C9A489",
        "W": "E9DCC9", "A": "2ED3C6",
    ]

    static let petMockingbirdPalette: [Character: String] = [
        "K": "373B44", "D": "6B7280", "B": "B9C0CC",
        "W": "E4E9ED", "A": "FFE066",
    ]

    static let foxPatches: [String: [CellDiff]] = [
        "blink": [
            CellDiff(5, 5, "D"), CellDiff(6, 5, "D"), CellDiff(12, 5, "D"),
            CellDiff(13, 5, "D")
        ],
        "sleepy": [
            CellDiff(5, 5, "D"), CellDiff(6, 5, "D"), CellDiff(12, 5, "D"),
            CellDiff(13, 5, "D"), CellDiff(5, 6, "D"), CellDiff(6, 6, "D"),
            CellDiff(12, 6, "D"), CellDiff(13, 6, "D"), CellDiff(5, 1, "B"),
            CellDiff(14, 1, "B")
        ],
        "happy": [
            CellDiff(5, 5, "B"), CellDiff(6, 5, "B"), CellDiff(12, 5, "B"),
            CellDiff(13, 5, "B"), CellDiff(7, 9, "K"), CellDiff(12, 9, "K")
        ],
        "glanceL": [
            CellDiff(4, 5, "W"), CellDiff(5, 5, "K"), CellDiff(6, 5, "B"),
            CellDiff(4, 6, "K"), CellDiff(6, 6, "B"), CellDiff(11, 5, "W"),
            CellDiff(12, 5, "K"), CellDiff(13, 5, "B"), CellDiff(11, 6, "K"),
            CellDiff(13, 6, "B")
        ],
        "glanceR": [
            CellDiff(5, 5, "B"), CellDiff(6, 5, "W"), CellDiff(7, 5, "K"),
            CellDiff(5, 6, "B"), CellDiff(7, 6, "K"), CellDiff(12, 5, "B"),
            CellDiff(13, 5, "W"), CellDiff(14, 5, "K"), CellDiff(12, 6, "B"),
            CellDiff(14, 6, "K")
        ],
        "quirk": [
            CellDiff(4, 1, "A"), CellDiff(15, 1, "A"), CellDiff(19, 13, "W"),
            CellDiff(18, 13, "D")
        ],
        "perk": [
            CellDiff(5, 4, "D"), CellDiff(6, 4, "D"), CellDiff(12, 4, "D"),
            CellDiff(13, 4, "D")
        ],
        "breathe": [
            CellDiff(7, 11, "W"), CellDiff(12, 11, "W")
        ],
        "idleA": [
            CellDiff(18, 13, "D"), CellDiff(17, 13, "W")
        ],
        "idleB": [
            CellDiff(19, 13, "W"), CellDiff(18, 13, "D")
        ],
        "yawn": [
            CellDiff(5, 5, "D"), CellDiff(6, 5, "D"), CellDiff(12, 5, "D"),
            CellDiff(13, 5, "D"), CellDiff(5, 6, "D"), CellDiff(6, 6, "D"),
            CellDiff(12, 6, "D"), CellDiff(13, 6, "D"), CellDiff(9, 10, "K"),
            CellDiff(10, 10, "K")
        ],
    ]

    static let shibaPatches: [String: [CellDiff]] = [
        "blink": [
            CellDiff(5, 5, "D"), CellDiff(6, 5, "D"), CellDiff(12, 5, "D"),
            CellDiff(13, 5, "D")
        ],
        "sleepy": [
            CellDiff(5, 5, "D"), CellDiff(6, 5, "D"), CellDiff(12, 5, "D"),
            CellDiff(13, 5, "D"), CellDiff(5, 6, "D"), CellDiff(6, 6, "D"),
            CellDiff(12, 6, "D"), CellDiff(13, 6, "D")
        ],
        "happy": [
            CellDiff(5, 5, "B"), CellDiff(6, 5, "B"), CellDiff(12, 5, "B"),
            CellDiff(13, 5, "B"), CellDiff(6, 9, "K"), CellDiff(11, 9, "K")
        ],
        "glanceL": [
            CellDiff(4, 5, "W"), CellDiff(5, 5, "K"), CellDiff(6, 5, "B"),
            CellDiff(4, 6, "K"), CellDiff(6, 6, "B"), CellDiff(11, 5, "W"),
            CellDiff(12, 5, "K"), CellDiff(13, 5, "B"), CellDiff(11, 6, "K"),
            CellDiff(13, 6, "B")
        ],
        "glanceR": [
            CellDiff(5, 5, "B"), CellDiff(6, 5, "W"), CellDiff(7, 5, "K"),
            CellDiff(5, 6, "B"), CellDiff(7, 6, "K"), CellDiff(12, 5, "B"),
            CellDiff(13, 5, "W"), CellDiff(14, 5, "K"), CellDiff(12, 6, "B"),
            CellDiff(14, 6, "K")
        ],
        "quirk": [
            CellDiff(14, 0, "B"), CellDiff(13, 0, "A"), CellDiff(8, 9, "K"),
            CellDiff(11, 9, "K")
        ],
        "perk": [
            CellDiff(5, 0, "W"), CellDiff(14, 0, "W"), CellDiff(6, 9, "K"),
            CellDiff(11, 9, "K")
        ],
        "breathe": [
            CellDiff(7, 11, "W"), CellDiff(12, 11, "W")
        ],
        "idleA": [
            CellDiff(7, 13, "B"), CellDiff(8, 13, "W")
        ],
        "idleB": [
            CellDiff(12, 13, "B"), CellDiff(13, 13, "W")
        ],
        "yawn": [
            CellDiff(5, 5, "D"), CellDiff(6, 5, "D"), CellDiff(12, 5, "D"),
            CellDiff(13, 5, "D"), CellDiff(5, 6, "D"), CellDiff(6, 6, "D"),
            CellDiff(12, 6, "D"), CellDiff(13, 6, "D"), CellDiff(8, 9, "K"),
            CellDiff(11, 9, "K")
        ],
    ]

    static let corgiPatches: [String: [CellDiff]] = [
        "blink": [
            CellDiff(4, 4, "D"), CellDiff(5, 4, "D")
        ],
        "sleepy": [
            CellDiff(4, 4, "D"), CellDiff(5, 4, "D"), CellDiff(4, 5, "D"),
            CellDiff(5, 5, "D")
        ],
        "happy": [
            CellDiff(4, 4, "B"), CellDiff(5, 4, "B"), CellDiff(2, 7, "K"),
            CellDiff(3, 7, "K")
        ],
        "glanceL": [
            CellDiff(3, 4, "W"), CellDiff(4, 4, "K"), CellDiff(5, 4, "B"),
            CellDiff(3, 5, "K"), CellDiff(5, 5, "B")
        ],
        "glanceR": [
            CellDiff(4, 4, "B"), CellDiff(5, 4, "W"), CellDiff(6, 4, "K"),
            CellDiff(4, 5, "B"), CellDiff(6, 5, "K")
        ],
        "quirk": [
            CellDiff(17, 7, "W"), CellDiff(16, 7, "B"), CellDiff(2, 1, "A")
        ],
        "perk": [
            CellDiff(2, 0, "W"), CellDiff(5, 0, "W")
        ],
        "breathe": [
            CellDiff(2, 11, "W"), CellDiff(16, 11, "W")
        ],
        "idleA": [
            CellDiff(4, 13, "B"), CellDiff(3, 13, "W")
        ],
        "idleB": [
            CellDiff(9, 13, "B"), CellDiff(8, 13, "W")
        ],
        "yawn": [
            CellDiff(4, 4, "D"), CellDiff(5, 4, "D"), CellDiff(4, 5, "D"),
            CellDiff(5, 5, "D"), CellDiff(1, 6, "K"), CellDiff(2, 6, "K")
        ],
    ]

    static let sphynxPatches: [String: [CellDiff]] = [
        "blink": [
            CellDiff(5, 5, "D"), CellDiff(6, 5, "D"), CellDiff(9, 5, "D"),
            CellDiff(10, 5, "D")
        ],
        "sleepy": [
            CellDiff(5, 5, "D"), CellDiff(6, 5, "D"), CellDiff(9, 5, "D"),
            CellDiff(10, 5, "D"), CellDiff(5, 6, "D"), CellDiff(6, 6, "D"),
            CellDiff(9, 6, "D"), CellDiff(10, 6, "D")
        ],
        "happy": [
            CellDiff(5, 5, "B"), CellDiff(6, 5, "B"), CellDiff(9, 5, "B"),
            CellDiff(10, 5, "B"), CellDiff(6, 8, "K"), CellDiff(9, 8, "K")
        ],
        "glanceL": [
            CellDiff(4, 5, "W"), CellDiff(5, 5, "K"), CellDiff(6, 5, "B"),
            CellDiff(4, 6, "K"), CellDiff(6, 6, "B"), CellDiff(8, 5, "W"),
            CellDiff(9, 5, "K"), CellDiff(10, 5, "B"), CellDiff(8, 6, "K"),
            CellDiff(10, 6, "B")
        ],
        "glanceR": [
            CellDiff(5, 5, "B"), CellDiff(6, 5, "W"), CellDiff(7, 5, "K"),
            CellDiff(5, 6, "B"), CellDiff(7, 6, "K"), CellDiff(9, 5, "B"),
            CellDiff(10, 5, "W"), CellDiff(11, 5, "K"), CellDiff(9, 6, "B"),
            CellDiff(11, 6, "K")
        ],
        "quirk": [
            CellDiff(15, 2, "D"), CellDiff(8, 13, "W"), CellDiff(9, 13, "W")
        ],
        "perk": [
            CellDiff(2, 0, "W"), CellDiff(17, 0, "W")
        ],
        "breathe": [
            CellDiff(5, 10, "W"), CellDiff(12, 10, "W")
        ],
        "idleA": [
            CellDiff(14, 12, "W"), CellDiff(14, 13, "D")
        ],
        "idleB": [
            CellDiff(6, 13, "B"), CellDiff(7, 13, "W")
        ],
        "yawn": [
            CellDiff(5, 5, "D"), CellDiff(6, 5, "D"), CellDiff(9, 5, "D"),
            CellDiff(10, 5, "D"), CellDiff(5, 6, "D"), CellDiff(6, 6, "D"),
            CellDiff(9, 6, "D"), CellDiff(10, 6, "D"), CellDiff(6, 8, "K"),
            CellDiff(9, 7, "K")
        ],
    ]

    static let birdPatches: [String: [CellDiff]] = [
        "blink": [
            CellDiff(5, 3, "D"), CellDiff(6, 3, "D")
        ],
        "sleepy": [
            CellDiff(5, 3, "D"), CellDiff(6, 3, "D"), CellDiff(5, 4, "D"),
            CellDiff(6, 4, "D")
        ],
        "happy": [
            CellDiff(5, 3, "B"), CellDiff(6, 3, "B"), CellDiff(2, 4, "D"),
            CellDiff(1, 4, "B")
        ],
        "glanceL": [
            CellDiff(4, 3, "W"), CellDiff(5, 3, "K"), CellDiff(6, 3, "B"),
            CellDiff(4, 4, "K"), CellDiff(6, 4, "B")
        ],
        "glanceR": [
            CellDiff(5, 3, "B"), CellDiff(6, 3, "W"), CellDiff(7, 3, "K"),
            CellDiff(5, 4, "B"), CellDiff(7, 4, "K")
        ],
        "quirk": [
            CellDiff(7, 6, "D"), CellDiff(8, 5, "D"), CellDiff(8, 6, "B")
        ],
        "perk": [
            CellDiff(6, 0, "B"), CellDiff(8, 0, "B")
        ],
        "breathe": [
            CellDiff(4, 10, "W"), CellDiff(4, 11, "W")
        ],
        "idleA": [
            CellDiff(17, 9, "B"), CellDiff(16, 9, "B")
        ],
        "idleB": [
            CellDiff(7, 6, "D"), CellDiff(8, 6, "B")
        ],
        "yawn": [
            CellDiff(5, 3, "D"), CellDiff(6, 3, "D"), CellDiff(2, 4, "D"),
            CellDiff(1, 4, "B")
        ],
    ]

    static let foxTailPoses: [Int: [CellDiff]] = [
        -1: [
            CellDiff(18, 13, "D"), CellDiff(17, 13, "W")
        ],
        1: [
            CellDiff(19, 13, "W"), CellDiff(18, 13, "B")
        ],
    ]

    static let shibaTailPoses: [Int: [CellDiff]] = [
        -1: [
            CellDiff(16, 9, "D"), CellDiff(17, 9, "W")
        ],
        1: [
            CellDiff(15, 8, "W"), CellDiff(16, 9, "D")
        ],
    ]

    static let corgiTailPoses: [Int: [CellDiff]] = [
        -1: [
            CellDiff(17, 7, "W"), CellDiff(16, 7, "B")
        ],
        1: [
            CellDiff(18, 8, "W"), CellDiff(17, 8, "B")
        ],
    ]

    static let sphynxTailPoses: [Int: [CellDiff]] = [
        -1: [
            CellDiff(14, 11, "D"), CellDiff(13, 10, "D"), CellDiff(15, 13, "K")
        ],
        1: [
            CellDiff(15, 12, "D"), CellDiff(16, 13, "D")
        ],
    ]

    static let birdTailPoses: [Int: [CellDiff]] = [
        -1: [
            CellDiff(14, 6, "B"), CellDiff(13, 6, "B")
        ],
        1: [
            CellDiff(17, 7, "B"), CellDiff(16, 7, "D")
        ],
    ]


    // MARK: The five companions (authored grids + HD portraits)

    static let ember = CompanionSprite(
        archetype: .ember,
        base: petFoxGrid,
        patches: foxPatches,
        paletteHex: petFoxPalette,
        portraitAssetName: "pet-fox",
        accentHexOverride: "FFC800"
    )

    static let willow = CompanionSprite(
        archetype: .willow,
        base: petShibaGrid,
        patches: shibaPatches,
        paletteHex: petShibaPalette,
        portraitAssetName: "pet-shiba",
        accentHexOverride: "6FA0FF"
    )

    static let compass = CompanionSprite(
        archetype: .compass,
        base: petCorgiGrid,
        patches: corgiPatches,
        paletteHex: petCorgiPalette,
        portraitAssetName: "pet-corgi",
        accentHexOverride: "5FAE4A"
    )

    static let prism = CompanionSprite(
        archetype: .prism,
        base: petSphynxGrid,
        patches: sphynxPatches,
        paletteHex: petSphynxPalette,
        portraitAssetName: "pet-sphynx",
        accentHexOverride: "2ED3C6"
    )

    static let nimbus = CompanionSprite(
        archetype: .nimbus,
        base: petMockingbirdGrid,
        patches: birdPatches,
        paletteHex: petMockingbirdPalette,
        portraitAssetName: "pet-mockingbird",
        accentHexOverride: "FFE066"
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
