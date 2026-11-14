import XCTest
@testable import Aivatar_Watch_App

/// Aivatar 2.0 E9 — ambient season overlays. PR-2 covers the ground shadow
/// (E9.1, evolved v35 into a 3-row isometric pixel tile: D top face + K front
/// lip); PR-9 extends this file with the cold-weather breath vapor (E9.2).
/// Tile rules pinned here: present in every awake frame, every row +1 wide on
/// the breathe frame, absent during the farewell wipe and in the rest LOD,
/// and the tile rows must be empty in every base grid (the overlay never
/// collides with authored art).
final class SeasonOverlayTests: XCTestCase {

    func testShadowRowsAreEmptyInEveryBaseGrid() {
        // v35: the ground tile spans shadowRow..shadowRow+2 (clamped) — every
        // tile row must be empty in the base grid (overlay never collides
        // with authored art).
        for archetype in Archetype.allCases {
            let sprite = AuthoredSprites.sprite(for: archetype)
            // v40: image-backed pets draw the HD art over rows 0...15 and the
            // tile UNDER it (rows 15-17 may hold fallback feet cells); the
            // empty-row rule binds authored grids (lumen) only.
            if sprite.isImageBacked { continue }
            let row = SpriteStageMetadata.meta(for: archetype).shadowRow
            for dy in 0...2 {
                let y = row + dy
                guard y < CompanionSprite.gridHeight else { continue }
                for x in 0..<CompanionSprite.gridWidth {
                    XCTAssertEqual(sprite.base[y][sprite.base[y].index(sprite.base[y].startIndex, offsetBy: x)], ".",
                                   "\(archetype): tile row \(y) must be empty in the base grid at x=\(x)")
                }
            }
        }
    }

    func testTileShapeIsIsoSlabAndFollowsBreatheFrame() {
        for archetype in Archetype.allCases {
            let idle = SpriteStageMetadata.shadowCells(archetype, widthExtra: 0)
            let breathe = SpriteStageMetadata.shadowCells(archetype, widthExtra: 1)
            let row = SpriteStageMetadata.meta(for: archetype).shadowRow
            let rows = Dictionary(grouping: idle, by: \.y).sorted { $0.key < $1.key }
            // Iso slab by design: dy 0/1 = D top face, dy 2 = K front lip
            // (clipped past the grid bottom). Each visible row contiguous+centered.
            XCTAssertGreaterThanOrEqual(rows.count, 2, "\(archetype): tile has at least 2 visible rows")
            for (y, cells) in rows {
                let xs = cells.map(\.x).sorted()
                XCTAssertEqual(xs.last! - xs.first! + 1, cells.count, "\(archetype): row \(y) contiguous")
                // v40: image-backed pets center the tile under the body
                // (shadowCenterX), not the canvas.
                let meta = SpriteStageMetadata.meta(for: archetype)
                let center = meta.shadowCenterX ?? CompanionSprite.gridWidth / 2
                XCTAssertEqual(xs.first!, center - cells.count / 2, "\(archetype): row \(y) centered under the body")
                let dy = y - row
                let expected: Character = dy >= 2 ? "K" : "D"
                XCTAssertTrue(cells.allSatisfy { $0.symbol == expected },
                              "\(archetype): row \(y) is \(expected)")
            }
            // Breathe swells every row by exactly one cell (the tile inhales).
            let idleByRow = Dictionary(grouping: idle, by: \.y)
            let breatheByRow = Dictionary(grouping: breathe, by: \.y)
            for (y, cells) in idleByRow {
                XCTAssertEqual(breatheByRow[y]?.count ?? -1, cells.count + 1,
                               "\(archetype): breathe widens tile row \(y) by 1")
            }
            XCTAssertEqual(Set(breathe.map(\.y)), Set(idle.map(\.y)), "same rows awake/breathe")
            XCTAssertTrue(idle.allSatisfy { $0.y >= row && $0.y < CompanionSprite.gridHeight }, "clamped to grid")
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
                    if let diff = shadow.first(where: { $0.x == x && $0.y == y }) {
                        XCTAssertEqual(with[y][x], diff.symbol, "\(archetype) overlay cell (\(x),\(y)) draws its own token")
                    } else {
                        XCTAssertEqual(with[y][x], without[y][x], "\(archetype) cell (\(x),\(y)) changed by overlay")
                    }
                }
            }
        }
    }
}

// MARK: - E9.2 cold breath vapor (PR-9)

extension SeasonOverlayTests {

    private func director(_ archetype: Archetype, seed: UInt64 = 20261010) throws -> SpriteDirector {
        let profile = try PersonalityProfile.load(archetype)
        return SpriteDirector(profile: profile, seed: seed)
    }

    func testVaporOnlyWhenCold() throws {
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            d.setCondition(.sunny)
            var puffs = 0
            for t in 1...1000 {
                d.advance(toTick: t)
                if d.vaporActive { puffs += 1 }
            }
            XCTAssertEqual(puffs, 0, "\(archetype): sunny never vaporizes")
            d.setCondition(.unknown)
            for t in 1001...2000 { d.advance(toTick: t) }
            XCTAssertFalse(d.vaporActive, "\(archetype): unknown class never vaporizes (G8)")
        }
    }

    func testVaporScheduleStatisticsAndShape() throws {
        let d = try director(.ember)
        d.setCondition(.cold)
        var puffTicks: [Int] = []
        for t in 1...2000 {
            d.advance(toTick: t)
            if d.vaporActive { puffTicks.append(t) }
        }
        XCTAssertFalse(puffTicks.isEmpty, "cold weather produces vapor over 2000 ticks")
        // Puffs are exactly 3 contiguous ticks.
        var i = 0
        while i < puffTicks.count {
            let start = puffTicks[i]
            var len = 1
            while i + len < puffTicks.count, puffTicks[i + len] == start + len { len += 1 }
            XCTAssertEqual(len, SpriteDirector.vaporOnTicks, "puff at \(start) must be exactly 3 ticks")
            i += len
            // Gap to the next puff is >= 33 ticks.
            if i < puffTicks.count {
                XCTAssertGreaterThanOrEqual(puffTicks[i] - start, 3 + SpriteDirector.vaporMinHiddenTicks)
            }
        }
        // Overlay cells are the 2 authored ink cells.
        d.setCondition(.cold)
        for t in 2001...2600 {
            d.advance(toTick: t)
            if d.vaporActive {
                let cells = d.transientOverlayCells.filter { $0.symbol == "K" }
                XCTAssertEqual(cells.count, 2)
                XCTAssertEqual(Set(cells.map { "\($0.x),\($0.y)" }),
                               Set(SpriteStageMetadata.vaporCells(.ember).map { "\($0.x),\($0.y)" }))
                break
            }
        }
    }

    func testVaporDeterministicPerSeed() throws {
        func run() -> [Bool] {
            let d = try! director(.prism, seed: 424242)
            d.setCondition(.cold)
            var out: [Bool] = []
            for t in 1...500 { d.advance(toTick: t); out.append(d.vaporActive) }
            return out
        }
        XCTAssertEqual(run(), run())
    }

    func testVaporSuppressedInSession() throws {
        let d = try director(.nimbus)
        d.setCondition(.cold)
        d.setSessionMode(true)
        for t in 1...600 { d.advance(toTick: t) }
        XCTAssertFalse(d.vaporActive, "no vapor during a breath session")
        d.setSessionMode(false)
        for t in 601...1200 { d.advance(toTick: t) }
        XCTAssertFalse(d.vaporActive, "no vapor during a breath session")
    }
}
