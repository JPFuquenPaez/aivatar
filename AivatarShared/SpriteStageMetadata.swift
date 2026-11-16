import Foundation

/// SpriteStageMetadata (Aivatar 2.0): authored per-archetype cell metadata over
/// the shared 20x18 stage grid — one table for everything the shell/renderer
/// needs to locate features on the face/body. Pure, static, test-pinned per
/// animal (checked in review at 32 px icon scale):
///
/// - `faceRect`: the hit band for boop-the-face (E7) — the eye block plus a
///   1-cell margin (Willow's dome-eye rows, Nimbus's beak band, ...).
/// - `shadowRow` / `shadowWidth`: the ground-shadow strip (E9.1) — one cell
///   high, centered under the body; width grows by 1 on the breathe frame.
/// - `blushL` / `blushR`: the two accent blush cells at face-rect mid-height (E7).
/// - `vapor`: the two ink breath-vapor cells above the face center (E9.2).
nonisolated enum SpriteStageMetadata {
    nonisolated struct AnimalMeta: Sendable {
        var faceRect: (x: Int, y: Int, w: Int, h: Int)
        var shadowRow: Int
        var shadowWidth: Int
        /// v40: image-backed pets are not grid-centered (fox tail, bird on
        /// its branch) — the ground tile centers under the body, not the
        /// canvas. Nil = canvas center (authored-grid animals).
        var shadowCenterX: Int? = nil
        var blushL: (x: Int, y: Int)
        var blushR: (x: Int, y: Int)
        var vapor: [(x: Int, y: Int)]
    }

    static func meta(for archetype: Archetype) -> AnimalMeta {
        switch archetype {
        // v43 (AMS v2): all six companions are authored grids again — the
        // meta re-authored for the P0 grids (feet at row 13, tile rows 14-16,
        // grid-centered bodies so shadowCenterX is nil everywhere).
        case .ember:
            // Fox: head rows 4-9 cols 4-15; ears rows 0-3; paws row 13.
            return AnimalMeta(
                faceRect: (4, 4, 12, 6),
                shadowRow: 14, shadowWidth: 12,
                blushL: (5, 7), blushR: (14, 7),
                vapor: [(7, 2), (8, 2)]
            )
        case .willow:
            // Shiba: head rows 3-9 cols 4-15; curl at the right shoulder.
            return AnimalMeta(
                faceRect: (4, 4, 12, 6),
                shadowRow: 14, shadowWidth: 10,
                blushL: (4, 6), blushR: (15, 6),
                vapor: [(7, 1), (8, 1)]
            )
        case .compass:
            // Corgi: side-profile loaf; head rows 3-8 cols 1-6, nose at (0,5).
            return AnimalMeta(
                faceRect: (0, 3, 8, 6),
                shadowRow: 14, shadowWidth: 14,
                blushL: (2, 4), blushR: (3, 7),
                vapor: [(0, 2), (1, 2)]
            )
        case .prism:
            // Sphynx: narrow face rows 3-8 cols 4-11, giant ears rows 0-3.
            return AnimalMeta(
                faceRect: (4, 4, 8, 5),
                shadowRow: 14, shadowWidth: 8,
                blushL: (4, 7), blushR: (11, 7),
                vapor: [(8, 1), (9, 1)]
            )
        case .nimbus:
            // Mockingbird: head rows 1-5 cols 3-7, beak at cols 0-2 row 3.
            return AnimalMeta(
                faceRect: (2, 2, 6, 4),
                shadowRow: 14, shadowWidth: 8,
                blushL: (3, 5), blushR: (7, 5),
                vapor: [(4, 0), (5, 0)]
            )
        case .lumen:
            // Moth: eyes rows 2-3 cols 6-13 (antennae row 0); body bottom row 13.
            return AnimalMeta(
                faceRect: (6, 1, 8, 4),
                shadowRow: 14, shadowWidth: 12,
                blushL: (6, 4), blushR: (13, 4),
                vapor: [(9, 0), (10, 0)]
            )
        }
    }

    /// The LPR tail part (AMS v2 §5.2): the authored pose diffs for the
    /// TailChannel's quantized pose (-1 tailL, +1 tailR; 0 = the idle tail).
    /// Only translation-grade cell diffs — no crops, no rotation. Lumen has
    /// no tail part (nil = never wags).
    static func tailPoses(_ archetype: Archetype) -> [Int: [CellDiff]]? {
        switch archetype {
        case .ember: return AuthoredSprites.foxTailPoses
        case .willow: return AuthoredSprites.shibaTailPoses
        case .compass: return AuthoredSprites.corgiTailPoses
        case .prism: return AuthoredSprites.sphynxTailPoses
        case .nimbus: return AuthoredSprites.birdTailPoses
        case .lumen: return nil
        }
    }

    /// The tail overlay for the current quantized pose (renderer/consumer).
    static func tailOverlay(_ archetype: Archetype, pose: Int) -> [CellDiff] {
        guard pose != 0, let poses = tailPoses(archetype) else { return [] }
        return poses[pose] ?? []
    }

    /// True when the cell is inside the face rect (E7 hit routing).
    static func isFaceCell(_ archetype: Archetype, x: Int, y: Int) -> Bool {
        let f = meta(for: archetype).faceRect
        return x >= f.x && x < f.x + f.w && y >= f.y && y < f.y + f.h
    }

    /// The ground tile (E9.1, evolved v35/v41 into an isometric DIAMOND —
    /// flat tokens only, no gradients, so the pixel-honesty rules hold):
    ///   row+0: width w-2, `D` (top face, pointed)
    ///   row+1: width w,   `D` (top face, widest)
    ///   row+2: width w-2, `K` (ink front lip, inset)
    /// The pointed rows read as a classic 2:1 iso ground plane instead of a
    /// flat bar. `widthExtra` widens every row (the breathe frame swells the
    /// tile as the companion inhales — the tile is animated).
    /// Rows past the grid bottom are clamped away.
    static func shadowCells(_ archetype: Archetype, widthExtra: Int = 0) -> [CompanionSprite.CellDiff] {
        let m = meta(for: archetype)
        let w = m.shadowWidth + widthExtra
        let rows: [(dy: Int, width: Int, symbol: Character)] = [
            (0, max(0, w - 2), "D"),
            (1, w, "D"),
            (2, max(0, w - 2), "K"),
        ]
        var cells: [CompanionSprite.CellDiff] = []
        for (dy, width, symbol) in rows {
            let y = m.shadowRow + dy
            guard y < CompanionSprite.gridHeight, width > 0 else { continue }
            let center = m.shadowCenterX ?? CompanionSprite.gridWidth / 2
            let x0 = center - width / 2
            for i in 0..<width {
                let x = x0 + i
                guard x >= 0, x < CompanionSprite.gridWidth else { continue }
                cells.append(CompanionSprite.CellDiff(x, y, symbol))
            }
        }
        return cells
    }

    /// The stage's ground-tile overlay decision, factored pure for tests:
    /// present in every awake frame (width +1 on the breathe frame), absent
    /// during the farewell wipe and in the rest LOD (the rest path never
    /// calls this).
    static func shadowOverlayIfAwake(_ archetype: Archetype, frame: String, farewellPending: Bool) -> [CompanionSprite.CellDiff] {
        guard !farewellPending else { return [] }
        return shadowCells(archetype, widthExtra: frame == "breathe" ? 1 : 0)
    }

    /// The two accent blush cells (E7 flush).
    static func blushCells(_ archetype: Archetype) -> [CompanionSprite.CellDiff] {
        let m = meta(for: archetype)
        return [CompanionSprite.CellDiff(m.blushL.x, m.blushL.y, "A"),
                CompanionSprite.CellDiff(m.blushR.x, m.blushR.y, "A")]
    }

    /// The two ink vapor cells above the face (E9.2).
    static func vaporCells(_ archetype: Archetype) -> [CompanionSprite.CellDiff] {
        meta(for: archetype).vapor.map { CompanionSprite.CellDiff($0.x, $0.y, "K") }
    }
}
