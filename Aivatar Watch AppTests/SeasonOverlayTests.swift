import XCTest
@testable import Aivatar_Watch_App

/// Aivatar 2.0 E9 — ambient season overlays. PR-2 covers the ground shadow
/// (E9.1); PR-9 extends this file with the cold-weather breath vapor (E9.2).
/// Shadow rules pinned here: present in every awake frame, one cell high,
/// `D` shade token, width +1 on the breathe frame, absent during the farewell
/// wipe and in the rest LOD, and the shadow row must be empty in every base
/// grid (the overlay never collides with authored art).
final class SeasonOverlayTests: XCTestCase {

    func testShadowRowIsEmptyInEveryBaseGrid() {
        for archetype in Archetype.allCases {
            let sprite = AuthoredSprites.sprite(for: archetype)
            let row = SpriteStageMetadata.meta(for: archetype).shadowRow
            for x in 0..<CompanionSprite.gridWidth {
                XCTAssertEqual(sprite.base[row][sprite.base[row].index(sprite.base[row].startIndex, offsetBy: x)], ".",
                               "\(archetype): shadow row \(row) must be empty in the base grid at x=\(x)")
            }
        }
    }

    func testShadowWidthFollowsBreatheFrame() {
        for archetype in Archetype.allCases {
            let idle = SpriteStageMetadata.shadowCells(archetype, widthExtra: 0)
            let breathe = SpriteStageMetadata.shadowCells(archetype, widthExtra: 1)
            XCTAssertEqual(breathe.count, idle.count + 1, "\(archetype): breathe frame widens the shadow by 1 cell")
            XCTAssertTrue(idle.allSatisfy { $0.symbol == "D" }, "shadow is the D shade token only")
            // Centered: same row, contiguous, centered on the 20-cell grid.
            let row = SpriteStageMetadata.meta(for: archetype).shadowRow
            XCTAssertTrue(idle.allSatisfy { $0.y == row })
            let xs = idle.map(\.x).sorted()
            XCTAssertEqual(xs.last! - xs.first! + 1, idle.count, "contiguous strip")
            XCTAssertEqual(xs.first!, (CompanionSprite.gridWidth - idle.count) / 2, "centered")
        }
    }

    func testShadowAbsentDuringFarewellWipeAndRestGate() {
        for archetype in Archetype.allCases {
            XCTAssertTrue(SpriteStageMetadata.shadowOverlayIfAwake(archetype, frame: "idle", farewellPending: true).isEmpty,
                          "farewell wipe: no shadow")
            XCTAssertTrue(SpriteStageMetadata.shadowOverlayIfAwake(archetype, frame: "sleepy", farewellPending: true).isEmpty)
            XCTAssertFalse(SpriteStageMetadata.shadowOverlayIfAwake(archetype, frame: "idle", farewellPending: false).isEmpty)
            // Run-cycle frames are awake frames: shadow present.
            XCTAssertFalse(SpriteStageMetadata.shadowOverlayIfAwake(archetype, frame: "idleA", farewellPending: false).isEmpty)
            XCTAssertFalse(SpriteStageMetadata.shadowOverlayIfAwake(archetype, frame: "idleB", farewellPending: false).isEmpty)
        }
    }

    func testShadowComposesOverAnyFrameWithoutChangingIt() {
        // The shadow is an overlay: resolving any frame with it must not alter
        // the authored grid elsewhere.
        for archetype in Archetype.allCases {
            let sprite = AuthoredSprites.sprite(for: archetype)
            let shadow = SpriteStageMetadata.shadowCells(archetype)
            let with = sprite.symbols(frameID: "idle", overlay: shadow)
            let without = sprite.symbols(frameID: "idle")
            for y in 0..<CompanionSprite.gridHeight {
                for x in 0..<CompanionSprite.gridWidth {
                    let isShadow = shadow.contains { $0.x == x && $0.y == y }
                    if !isShadow {
                        XCTAssertEqual(with[y][x], without[y][x], "\(archetype) cell (\(x),\(y)) changed by shadow")
                    } else {
                        XCTAssertEqual(with[y][x], "D")
                    }
                }
            }
        }
    }
}
