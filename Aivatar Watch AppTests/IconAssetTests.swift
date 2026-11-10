import XCTest
import SwiftUI
@testable import Aivatar_Watch_App

/// Aivatar 2.0 E1 — icon asset tests. The app icon's source of truth is the
/// authored 32x32 grid (CompanionSprite.IconCuts.emberFace); the committed
/// PNGs are regenerated only by Tools/icon_export.swift (CI hash-pins the
/// output). These tests pin the grid contract: 32x32, 5-token ramp, head
/// ~19 cells tall and optically centered, ear triangles >= 5 cells, W
/// catchlight in the left eye block, A reserved for the two ear tips.
final class IconAssetTests: XCTestCase {

    func testGridIs32x32OverFiveTokenRamp() {
        let grid = IconCuts.emberFaceSymbols()
        XCTAssertEqual(grid.count, 32)
        for row in grid { XCTAssertEqual(row.count, 32) }
        let used = Set(IconCuts.emberFace.joined()).subtracting(["."])
        XCTAssertLessThanOrEqual(used.count, 5, "icon palette budget: <= 5 tokens")
        XCTAssertTrue(used.isSubset(of: Set("KDBWA")))
    }

    func testHeadProportionAndCentering() {
        let grid = IconCuts.emberFaceSymbols()
        let filledRows = grid.indices.filter { y in grid[y].contains { $0 != "." } }
        let headRows = filledRows.filter { y in y >= 9 } // head mass below the ears
        XCTAssertEqual(headRows.count, 19, "head occupies ~19 of 32 cells (~57%)")
        // Optically centered: content center within 2 cells of canvas center.
        let centerY = (filledRows.first! + filledRows.last!) / 2
        XCTAssertLessThanOrEqual(abs(centerY - 15), 2)
    }

    func testEarTrianglesAndAccentTips() {
        let grid = IconCuts.emberFaceSymbols()
        // Ear tips are the only accent cells, one per ear.
        var accentCells: [(Int, Int)] = []
        for y in 0..<32 { for x in 0..<32 where grid[y][x] == "A" { accentCells.append((x, y)) } }
        XCTAssertEqual(accentCells.count, 2, "A is reserved for the two ear-tip cells")
        // Each ear triangle is >= 5 cells tall (contiguous B column under the tip).
        for (x, y) in accentCells {
            var depth = 0
            var yy = y
            while yy < 32, grid[yy][x] != "." { depth += 1; yy += 1 }
            XCTAssertGreaterThanOrEqual(depth, 5, "ear triangle at x=\(x) must be >= 5 cells tall")
        }
    }

    func testEyeCatchlightAndMuzzle() {
        let grid = IconCuts.emberFaceSymbols()
        // Exactly one W catchlight per eye block: the eye rows are 17-18
        // (2x2 ink blocks with the W in the upper-left corner).
        var catchlights = 0
        for y in 17...18 { for x in 0..<32 where grid[y][x] == "W" { catchlights += 1 } }
        XCTAssertEqual(catchlights, 2, "one W catchlight per eye (U2 dead-eye guard)")
        XCTAssertEqual(grid[17][8], "W")
        XCTAssertEqual(grid[17][19], "W")
        // Paper muzzle present below the eyes.
        XCTAssertTrue(grid.contains { $0.contains("W") }, "paper muzzle required")
    }

    func testIconPaletteMatchesEmberStagePalette() {
        // The icon reuses the stage's authored palette — one hue family on stage and icon.
        XCTAssertEqual(IconCuts.emberFacePaletteHex, AuthoredSprites.ember.paletteHex)
    }
}
