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

    // MARK: EMBER — fox

    static let ember = CompanionSprite(
        archetype: .ember,
        base: [
            "....BB........BB....",
            "...BBB........BBB...",
            "..BBBBBBBBBBBBBBBB..",
            "..BBBBBBBBBBBBBBBB..",
            "..BBBBWKBBBBBWKBBB..",
            "..BBBBKKBBBBBKKBBB..",
            "..BBBBBBBBBBBBBBBB..",
            "...BBBBBWWWWWWBBBB..",
            "...BBBBBWWKKWWBBBB..",
            "...BBBBBWWWWWWBBBB..",
            "...BBBBBBBBBBBBBBB..",
            "....BBBBBBBBBB......",
            ".....BBBBBBBB.......",
            "....DDDDDDDDDD......",
            "....DDD......DDD....",
            "....................",
            "....................",
            "....................",
        ],
        patches: [
            "blink": [ CellDiff(6, 4, "B"), CellDiff(7, 4, "B"), CellDiff(13, 4, "B"), CellDiff(14, 4, "B") ],
            "sleepy": [ CellDiff(6, 3, "D"), CellDiff(7, 3, "D"), CellDiff(6, 4, "B"), CellDiff(7, 4, "B"), CellDiff(13, 3, "D"), CellDiff(14, 3, "D"), CellDiff(13, 4, "B"), CellDiff(14, 4, "B") ],
            "happy": [ CellDiff(6, 4, "B"), CellDiff(7, 4, "B"), CellDiff(13, 4, "B"), CellDiff(14, 4, "B"), CellDiff(9, 8, "K"), CellDiff(12, 8, "K") ],
            "glanceL": [ CellDiff(7, 4, "B"), CellDiff(7, 5, "B"), CellDiff(5, 4, "W"), CellDiff(6, 4, "K"), CellDiff(5, 5, "K"), CellDiff(6, 5, "K"), CellDiff(14, 4, "B"), CellDiff(14, 5, "B"), CellDiff(12, 4, "W"), CellDiff(13, 4, "K"), CellDiff(12, 5, "K"), CellDiff(13, 5, "K") ],
            "glanceR": [ CellDiff(6, 4, "B"), CellDiff(6, 5, "B"), CellDiff(7, 4, "W"), CellDiff(8, 4, "K"), CellDiff(7, 5, "K"), CellDiff(8, 5, "K"), CellDiff(13, 4, "B"), CellDiff(13, 5, "B"), CellDiff(14, 4, "W"), CellDiff(15, 4, "K"), CellDiff(14, 5, "K"), CellDiff(15, 5, "K") ],
            "quirk": [ CellDiff(17, 11, "B"), CellDiff(18, 11, "B"), CellDiff(19, 11, "W") ],
            "perk": [ CellDiff(3, 0, "B"), CellDiff(16, 0, "B") ],
            "breathe": [ CellDiff(3, 11, "B"), CellDiff(16, 11, "B") ],
            "idleA": [ CellDiff(16, 0, "B") ],
            "idleB": [ CellDiff(3, 0, "B") ],
            "yawn": [ CellDiff(6, 3, "D"), CellDiff(7, 3, "D"), CellDiff(6, 4, "B"), CellDiff(7, 4, "B"), CellDiff(13, 3, "D"), CellDiff(14, 3, "D"), CellDiff(13, 4, "B"), CellDiff(14, 4, "B"), CellDiff(9, 9, "K"), CellDiff(11, 9, "K") ],
        ],
        paletteHex: [
            "B": "FF9E4A", "D": "C4621B", "K": "241206",
            "W": "F5F4EF", "A": "FFC800",
        ]
    )

    // MARK: WILLOW — frog

    static let willow = CompanionSprite(
        archetype: .willow,
        base: [
            ".....BB......BB.....",
            "....BBBB....BBBB....",
            "...BBWKBBBBBBWKBB...",
            "...BBKKBBBBBBKKBB...",
            "..BBBBBBBBBBBBBBBB..",
            "..BBBBBBBBBBBBBBBB..",
            "..BBBBBBKKKKBBBBBB..",
            "..BBBBBBBBBBBBBBBB..",
            "...BBBBBWWWWBBBB....",
            "...BBBBBBBBBBBBBBB..",
            "....BBBBBBBBBB......",
            ".....BBBBBBBB.......",
            "....DDDDDDDDDD......",
            "...DDD........DDD...",
            "....................",
            "....................",
            "....................",
            "....................",
        ],
        patches: [
            "blink": [ CellDiff(5, 2, "B"), CellDiff(6, 2, "B"), CellDiff(13, 2, "B"), CellDiff(14, 2, "B") ],
            "sleepy": [ CellDiff(5, 1, "D"), CellDiff(6, 1, "D"), CellDiff(5, 2, "B"), CellDiff(6, 2, "B"), CellDiff(13, 1, "D"), CellDiff(14, 1, "D"), CellDiff(13, 2, "B"), CellDiff(14, 2, "B") ],
            "happy": [ CellDiff(5, 2, "B"), CellDiff(6, 2, "B"), CellDiff(13, 2, "B"), CellDiff(14, 2, "B"), CellDiff(7, 6, "K"), CellDiff(12, 6, "K") ],
            "glanceL": [ CellDiff(6, 2, "B"), CellDiff(6, 3, "B"), CellDiff(4, 2, "W"), CellDiff(5, 2, "K"), CellDiff(4, 3, "K"), CellDiff(5, 3, "K"), CellDiff(14, 2, "B"), CellDiff(14, 3, "B"), CellDiff(12, 2, "W"), CellDiff(13, 2, "K"), CellDiff(12, 3, "K"), CellDiff(13, 3, "K") ],
            "glanceR": [ CellDiff(5, 2, "B"), CellDiff(5, 3, "B"), CellDiff(6, 2, "W"), CellDiff(7, 2, "K"), CellDiff(6, 3, "K"), CellDiff(7, 3, "K"), CellDiff(13, 2, "B"), CellDiff(13, 3, "B"), CellDiff(14, 2, "W"), CellDiff(15, 2, "K"), CellDiff(14, 3, "K"), CellDiff(15, 3, "K") ],
            "quirk": [ CellDiff(9, 10, "A"), CellDiff(10, 10, "A") ],
            "perk": [ CellDiff(7, 6, "K"), CellDiff(12, 6, "K") ],
            "breathe": [ CellDiff(1, 11, "B"), CellDiff(18, 11, "B") ],
            "idleA": [ CellDiff(7, 6, "D") ],
            "idleB": [ CellDiff(12, 6, "D") ],
            "yawn": [ CellDiff(5, 1, "D"), CellDiff(6, 1, "D"), CellDiff(5, 2, "B"), CellDiff(6, 2, "B"), CellDiff(13, 1, "D"), CellDiff(14, 1, "D"), CellDiff(13, 2, "B"), CellDiff(14, 2, "B"), CellDiff(8, 9, "K"), CellDiff(9, 9, "D"), CellDiff(10, 9, "D"), CellDiff(11, 9, "K") ],
        ],
        paletteHex: [
            "B": "55D98A", "D": "2A9C5E", "K": "0C2018",
            "W": "F5F4EF", "A": "F2D64B",
        ]
    )

    // MARK: COMPASS — fish

    static let compass = CompanionSprite(
        archetype: .compass,
        base: [
            "......BB............",
            ".....BBBB...........",
            "....BBBBBB..........",
            "...BBBBBBBB....AA...",
            "..BBWKBBBBBBBBB..AAA",
            "..BBKKBBBBBBBBB.AAAA",
            ".BBBBBBBBBBBBBAAAAA.",
            ".KKBBBBBBBBBBBAAAAA.",
            ".DWWWWWWWBBBBBAAA...",
            "..DWWWWWWBBBBBBAA...",
            "...DDDDDDDDBBBB.....",
            ".....DDDDD..........",
            "....................",
            "....................",
            "....................",
            "....................",
            "....................",
            "....................",
        ],
        patches: [
            "blink": [ CellDiff(4, 4, "B"), CellDiff(5, 4, "B") ],
            "sleepy": [ CellDiff(4, 3, "D"), CellDiff(5, 3, "D"), CellDiff(4, 4, "B"), CellDiff(5, 4, "B") ],
            "happy": [ CellDiff(4, 4, "B"), CellDiff(5, 4, "B"), CellDiff(1, 8, "K"), CellDiff(2, 8, "K") ],
            "glanceL": [ CellDiff(5, 4, "B"), CellDiff(5, 5, "B"), CellDiff(3, 4, "W"), CellDiff(4, 4, "K"), CellDiff(3, 5, "K"), CellDiff(4, 5, "K") ],
            "glanceR": [ CellDiff(4, 4, "B"), CellDiff(4, 5, "B"), CellDiff(5, 4, "W"), CellDiff(6, 4, "K"), CellDiff(5, 5, "K"), CellDiff(6, 5, "K") ],
            "quirk": [ CellDiff(6, 2, "D"), CellDiff(7, 1, "D") ],
            "perk": [ CellDiff(5, 0, "B"), CellDiff(8, 1, "B"), CellDiff(4, 1, "B"), CellDiff(9, 2, "B") ],
            "breathe": [ CellDiff(0, 7, "B"), CellDiff(13, 10, "B") ],
            "idleA": [ CellDiff(6, 2, "D") ],
            "idleB": [ CellDiff(2, 7, "B") ],
            "yawn": [ CellDiff(4, 3, "D"), CellDiff(5, 3, "D"), CellDiff(4, 4, "B"), CellDiff(5, 4, "B"), CellDiff(1, 8, "K"), CellDiff(3, 8, "K") ],
        ],
        paletteHex: [
            "B": "3E8EF7", "D": "1F5FA8", "K": "0C1524",
            "W": "F5F4EF", "A": "7FD8FF",
        ]
    )

    // MARK: PRISM — chameleon

    static let prism = CompanionSprite(
        archetype: .prism,
        base: [
            "......AA............",
            ".....BAAB...........",
            "....BBAABB..........",
            "...BBBBBBBBB....DD..",
            "..BBWKBBBBBBBB..D..D",
            "..BBKKBBBBBBBB.D...D",
            "..BBBBBBBBBBBB.DD..D",
            ".BBBBBBBBBBBBB.DDD..",
            ".BBBBBBBBBBBBBDD....",
            "..BBBBBBBBBBBBDD....",
            "..BBBBBBBBBBB.......",
            "...BBBBBBBBB........",
            "...DDD...DDD........",
            "....................",
            "....................",
            "....................",
            "....................",
            "....................",
        ],
        patches: [
            "blink": [ CellDiff(4, 4, "B"), CellDiff(5, 4, "B") ],
            "sleepy": [ CellDiff(4, 3, "D"), CellDiff(5, 3, "D"), CellDiff(4, 4, "B"), CellDiff(5, 4, "B") ],
            "happy": [ CellDiff(4, 4, "B"), CellDiff(5, 4, "B"), CellDiff(2, 7, "K"), CellDiff(12, 7, "K") ],
            "glanceL": [ CellDiff(5, 4, "B"), CellDiff(5, 5, "B") ],
            "glanceR": [ CellDiff(4, 4, "B"), CellDiff(4, 5, "B"), CellDiff(5, 4, "W"), CellDiff(6, 4, "K"), CellDiff(5, 5, "K"), CellDiff(6, 5, "K") ],
            "quirk": [ CellDiff(18, 7, "D") ],
            "perk": [ CellDiff(5, 0, "A"), CellDiff(8, 0, "A") ],
            "breathe": [ CellDiff(1, 9, "B"), CellDiff(1, 10, "B") ],
            "idleA": [ CellDiff(7, 0, ".") ],
            "idleB": [ CellDiff(2, 7, "K") ],
            "yawn": [ CellDiff(4, 3, "D"), CellDiff(5, 3, "D"), CellDiff(4, 4, "B"), CellDiff(5, 4, "B"), CellDiff(5, 8, "K") ],
        ],
        paletteHex: [
            "B": "EA6FF5", "D": "9C3AA8", "K": "1A0C20",
            "W": "F5F4EF", "A": "FFC800",
        ]
    )

    // MARK: NIMBUS — bird

    static let nimbus = CompanionSprite(
        archetype: .nimbus,
        base: [
            ".......BB...........",
            "......BBBB..........",
            ".....BBBBBB.........",
            "....BBBBBBBB........",
            "...BBBBBBBBBB.......",
            "...BBWKBBBWKBBB.....",
            "...BBKKBBBKKBBB.....",
            "....BBBBAABBBB......",
            "....BBBBBBBBBB......",
            "..D.BBBBBBBBB.......",
            ".DDD.BBBBBBBBB......",
            ".DDD.BBBBWWBBBB.....",
            "..BBBBBBWWWWBBBB....",
            "...BBBBBBBBBB.......",
            "....DDDD..DDDD......",
            "....................",
            "....................",
            "....................",
        ],
        patches: [
            "blink": [ CellDiff(5, 5, "B"), CellDiff(6, 5, "B"), CellDiff(10, 5, "B"), CellDiff(11, 5, "B") ],
            "sleepy": [ CellDiff(5, 4, "D"), CellDiff(6, 4, "D"), CellDiff(5, 5, "B"), CellDiff(6, 5, "B"), CellDiff(10, 4, "D"), CellDiff(11, 4, "D"), CellDiff(10, 5, "B"), CellDiff(11, 5, "B") ],
            "happy": [ CellDiff(5, 5, "B"), CellDiff(6, 5, "B"), CellDiff(10, 5, "B"), CellDiff(11, 5, "B"), CellDiff(8, 8, "A"), CellDiff(9, 8, "A") ],
            "glanceL": [ CellDiff(6, 5, "B"), CellDiff(6, 6, "B"), CellDiff(11, 5, "B"), CellDiff(11, 6, "B"), CellDiff(4, 5, "W"), CellDiff(5, 5, "K"), CellDiff(4, 6, "K"), CellDiff(5, 6, "K"), CellDiff(9, 5, "W"), CellDiff(10, 5, "K"), CellDiff(9, 6, "K"), CellDiff(10, 6, "K") ],
            "glanceR": [ CellDiff(5, 5, "B"), CellDiff(5, 6, "B"), CellDiff(10, 5, "B"), CellDiff(10, 6, "B"), CellDiff(6, 5, "W"), CellDiff(7, 5, "K"), CellDiff(6, 6, "K"), CellDiff(7, 6, "K"), CellDiff(11, 5, "W"), CellDiff(12, 5, "K"), CellDiff(11, 6, "K"), CellDiff(12, 6, "K") ],
            "quirk": [ CellDiff(0, 9, "D"), CellDiff(1, 9, "D"), CellDiff(1, 11, "."), CellDiff(2, 11, ".") ],
            "perk": [ CellDiff(6, 0, "B"), CellDiff(9, 0, "B") ],
            "breathe": [ CellDiff(3, 10, "B"), CellDiff(14, 10, "B") ],
            "idleA": [ CellDiff(0, 10, "D") ],
            "idleB": [ CellDiff(3, 14, "D"), CellDiff(7, 14, ".") ],
            "yawn": [ CellDiff(5, 4, "D"), CellDiff(6, 4, "D"), CellDiff(5, 5, "B"), CellDiff(6, 5, "B"), CellDiff(10, 4, "D"), CellDiff(11, 4, "D"), CellDiff(10, 5, "B"), CellDiff(11, 5, "B"), CellDiff(7, 7, "A"), CellDiff(10, 7, "A") ],
        ],
        paletteHex: [
            "B": "8FA3FF", "D": "5A6ABF", "K": "101426",
            "W": "F5F4EF", "A": "FFD84B",
        ]
    )
    // MARK: LUMEN — moth (Aivatar 2.0, E10; night element, luminous)

    static let lumen = CompanionSprite(
        archetype: .lumen,
        base: [
            "......A.K..K.A......",
            ".......KBBBBK.......",
            "......BWKBBWKBB.....",
            "......BKKBBKKBB.....",
            "....BBBBBBBBBBBB....",
            "...BBBBBBBBBBBBBB...",
            "..BBBBBBBBBBBBBBBB..",
            ".BBBBBBB.BB.BBBBBBB.",
            "BBBBBBBB.BB.BBBBBBBB",
            ".BBBBBBB.BB.BBBBBBB.",
            ".BBBBBBBBBBBBBBBBBB.",
            "..BBBBBBBBBBBBBBBB..",
            "...DDDDD..BBDDDDD...",
            "....................",
            "....................",
            "....................",
            "....................",
            "....................",
        ],
        patches: [
            "blink": [ CellDiff(8, 2, "B"), CellDiff(9, 2, "B"), CellDiff(11, 2, "B"), CellDiff(12, 2, "B") ],
            "sleepy": [ CellDiff(8, 1, "D"), CellDiff(9, 1, "D"), CellDiff(8, 2, "B"), CellDiff(9, 2, "B"), CellDiff(11, 1, "D"), CellDiff(12, 1, "D"), CellDiff(11, 2, "B"), CellDiff(12, 2, "B") ],
            "happy": [ CellDiff(8, 2, "B"), CellDiff(9, 2, "B"), CellDiff(8, 3, "B"), CellDiff(9, 3, "B"), CellDiff(11, 2, "B"), CellDiff(12, 2, "B"), CellDiff(11, 3, "B"), CellDiff(12, 3, "B"), CellDiff(10, 4, "K"), CellDiff(11, 4, "K") ],
            "glanceL": [ CellDiff(9, 2, "B"), CellDiff(9, 3, "B"), CellDiff(7, 2, "W"), CellDiff(8, 2, "K"), CellDiff(7, 3, "K"), CellDiff(8, 3, "K"), CellDiff(12, 2, "B"), CellDiff(12, 3, "B"), CellDiff(10, 2, "W"), CellDiff(11, 2, "K"), CellDiff(10, 3, "K"), CellDiff(11, 3, "K") ],
            "glanceR": [ CellDiff(8, 2, "B"), CellDiff(8, 3, "B"), CellDiff(9, 2, "W"), CellDiff(10, 2, "K"), CellDiff(9, 3, "K"), CellDiff(10, 3, "K"), CellDiff(11, 2, "B"), CellDiff(11, 3, "B"), CellDiff(12, 2, "W"), CellDiff(13, 2, "K"), CellDiff(12, 3, "K"), CellDiff(13, 3, "K") ],
            "quirk": [ CellDiff(2, 7, "A"), CellDiff(3, 8, "A"), CellDiff(4, 9, "A"), CellDiff(17, 7, "A"), CellDiff(16, 8, "A"), CellDiff(15, 9, "A") ],
            "perk": [ CellDiff(7, 0, "A"), CellDiff(12, 0, "A") ],
            "breathe": [ CellDiff(1, 11, "B"), CellDiff(18, 11, "B") ],
            "idleA": [ CellDiff(1, 6, "B") ],
            "idleB": [ CellDiff(18, 6, "B") ],
            "yawn": [ CellDiff(8, 1, "D"), CellDiff(9, 1, "D"), CellDiff(8, 2, "B"), CellDiff(9, 2, "B"), CellDiff(11, 1, "D"), CellDiff(12, 1, "D"), CellDiff(11, 2, "B"), CellDiff(12, 2, "B"), CellDiff(10, 5, "K"), CellDiff(11, 5, "K") ],
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
    static let emberFacePaletteHex: [Character: String] = AuthoredSprites.ember.paletteHex
}
