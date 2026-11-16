import Foundation

/// IconCuts (Aivatar 2.0, E1 — moved to AivatarShared in v3): the app icon's
/// source of truth stays a GRID, not a drawing. `emberFace` is the
/// hand-authored 32x32 token grid the committed PNGs are regenerated from via
/// Tools/icon_export.swift (CI hash-pins the output); it is NOT the live
/// character system (v3 companions are the soft-toy puppets). The app icon
/// keeps its pinned pixel ramp deliberately: the launcher is a static brand
/// mark, and the v3 cast lives on the stage.
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

    /// The icon's pinned ramp (one hue family across stage tokens and the
    /// app icon; the v3 toy palette changes the STAGE family — the icon
    /// ramp is hash-pinned by icon_export and must not drift with casts).
    static let emberFacePaletteHex: [Character: String] = [
        "B": "FF9E4A", "D": "C4621B", "K": "241206",
        "W": "F5F4EF", "A": "FFC800",
    ]
}
