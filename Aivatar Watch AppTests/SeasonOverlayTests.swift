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

    func testVaporSuppressedInWorkoutAndSession() throws {
        let d = try director(.nimbus)
        d.setCondition(.cold)
        d.setWorkoutMode(true)
        for t in 1...600 { d.advance(toTick: t) }
        XCTAssertFalse(d.vaporActive, "no vapor while the run is the motion")
        d.setWorkoutMode(false)
        d.setSessionMode(true)
        for t in 601...1200 { d.advance(toTick: t) }
        XCTAssertFalse(d.vaporActive, "no vapor during a breath session")
    }
}
