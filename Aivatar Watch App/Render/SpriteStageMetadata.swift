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
    nonisolated struct AnimalMeta: Sendable, Equatable {
        var faceRect: (x: Int, y: Int, w: Int, h: Int)
        var shadowRow: Int
        var shadowWidth: Int
        var blushL: (x: Int, y: Int)
        var blushR: (x: Int, y: Int)
        var vapor: [(x: Int, y: Int)]
    }

    static func meta(for archetype: Archetype) -> AnimalMeta {
        switch archetype {
        case .ember:
            // Fox: eyes rows 4-5; head mass rows 2-13; ground row 15.
            return AnimalMeta(
                faceRect: (4, 3, 13, 6),
                shadowRow: 15, shadowWidth: 10,
                blushL: (3, 6), blushR: (16, 6),
                vapor: [(9, 0), (10, 0)]  // between the ears
            )
        case .willow:
            // Frog: dome eyes rows 0-3 on top of the head; body bottom row 15.
            return AnimalMeta(
                faceRect: (4, 0, 12, 7),
                shadowRow: 16, shadowWidth: 14,
                blushL: (3, 4), blushR: (16, 4),
                vapor: [(9, 0), (10, 0)]
            )
        case .compass:
            // Fish (side profile): eye cols 3-6 rows 5-6; body bottom row 13.
            return AnimalMeta(
                faceRect: (2, 4, 8, 4),
                shadowRow: 14, shadowWidth: 12,
                blushL: (1, 6), blushR: (9, 6),
                vapor: [(4, 2), (5, 2)]
            )
        case .prism:
            // Chameleon: turret eye rows 5-7 cols 2-7; feet row 14.
            return AnimalMeta(
                faceRect: (2, 4, 9, 5),
                shadowRow: 15, shadowWidth: 10,
                blushL: (1, 6), blushR: (9, 6),
                vapor: [(4, 0), (5, 0)]
            )
        case .nimbus:
            // Bird: eyes rows 5-6; feet row 15; beak band row 7-8.
            return AnimalMeta(
                faceRect: (4, 4, 11, 5),
                shadowRow: 16, shadowWidth: 10,
                blushL: (3, 5), blushR: (15, 5),
                vapor: [(9, 0), (10, 0)]
            )
        }
    }

    /// True when the cell is inside the face rect (E7 hit routing).
    static func isFaceCell(_ archetype: Archetype, x: Int, y: Int) -> Bool {
        let f = meta(for: archetype).faceRect
        return x >= f.x && x < f.x + f.w && y >= f.y && y < f.y + f.h
    }

    /// The ground-shadow strip (E9.1): `widthExtra` cells wider (breathe frame).
    /// One cell high, horizontally centered under the body. `D` shade token.
    static func shadowCells(_ archetype: Archetype, widthExtra: Int = 0) -> [CompanionSprite.CellDiff] {
        let m = meta(for: archetype)
        let w = m.shadowWidth + widthExtra
        let x0 = (CompanionSprite.gridWidth - w) / 2
        return (0..<w).map { CompanionSprite.CellDiff(x0 + $0, m.shadowRow, "D") }
    }

    /// The stage's shadow overlay decision, factored pure for tests: present
    /// in every awake frame (width +1 on the breathe frame), absent during
    /// the farewell wipe and in the rest LOD (the rest path never calls this).
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
