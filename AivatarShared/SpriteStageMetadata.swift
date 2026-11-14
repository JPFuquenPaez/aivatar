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
        // v40 HD pets: the pet image is drawn aspect-fit into rows 0...15
        // (bottom-anchored), so the ground tile sits at rows 15-17 and the
        // face band follows the head in the HD art (cell coords of the same
        // 20x18 box — boop hit math is unchanged).
        case .ember:
            // Fox: head left-of-center (ears x1-11, rows 2-13); tail drags
            // the body center right.
            return AnimalMeta(
                faceRect: (1, 2, 12, 12),
                shadowRow: 15, shadowWidth: 14, shadowCenterX: 11,
                blushL: (2, 9), blushR: (11, 9),
                vapor: [(5, 0), (6, 0)]
            )
        case .willow:
            // Shiba: head top-center, facing forward.
            return AnimalMeta(
                faceRect: (6, 1, 10, 11),
                shadowRow: 15, shadowWidth: 10, shadowCenterX: 9,
                blushL: (7, 7), blushR: (15, 7),
                vapor: [(10, 0), (11, 0)]
            )
        case .compass:
            // Corgi: head top-center-right.
            return AnimalMeta(
                faceRect: (6, 1, 11, 11),
                shadowRow: 15, shadowWidth: 12, shadowCenterX: 9,
                blushL: (7, 7), blushR: (16, 7),
                vapor: [(10, 0), (11, 0)]
            )
        case .prism:
            // Sphynx: small head top-center, big ears.
            return AnimalMeta(
                faceRect: (6, 1, 8, 9),
                shadowRow: 15, shadowWidth: 8, shadowCenterX: 9,
                blushL: (6, 5), blushR: (13, 5),
                vapor: [(9, 0), (10, 0)]
            )
        case .nimbus:
            // Mockingbird: head at the right end of its branch.
            return AnimalMeta(
                faceRect: (10, 1, 9, 11),
                shadowRow: 15, shadowWidth: 8, shadowCenterX: 13,
                blushL: (10, 7), blushR: (18, 7),
                vapor: [(13, 0), (14, 0)]
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

    /// True when the cell is inside the face rect (E7 hit routing).
    static func isFaceCell(_ archetype: Archetype, x: Int, y: Int) -> Bool {
        let f = meta(for: archetype).faceRect
        return x >= f.x && x < f.x + f.w && y >= f.y && y < f.y + f.h
    }

    /// The ground tile (E9.1 shadow, evolved v35 into a pseudo-3D isometric
    /// slab — flat tokens only, no gradients, so the pixel-honesty rules hold):
    ///   row+0: width w-2, `D` (top face, narrow)
    ///   row+1: width w,   `D` (top face, widest)
    ///   row+2: width w,   `K` (ink front face = the slab's thickness)
    /// The diamond-plus-lip reads as an isometric ground plane in classic
    /// pixel-art fashion. `widthExtra` widens every row (the breathe frame
    /// swells the tile as the companion inhales — the tile is animated).
    /// Rows past the grid bottom are clamped away.
    static func shadowCells(_ archetype: Archetype, widthExtra: Int = 0) -> [CompanionSprite.CellDiff] {
        let m = meta(for: archetype)
        let w = m.shadowWidth + widthExtra
        let rows: [(dy: Int, width: Int, symbol: Character)] = [
            (0, max(0, w - 2), "D"),
            (1, w, "D"),
            (2, w, "K"),
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
