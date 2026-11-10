import XCTest
@testable import Aivatar_Watch_App

/// Aivatar 2.0 E7 — boop the face. Face-rect hit math per archetype (center /
/// edge / outside), the flush overlay placement (2 authored accent cells), the
/// 600-tick (90 s) refractory with normal-pool fallback, and the <= 2-tick ack.
final class FaceBoopTests: XCTestCase {

    private func director(_ archetype: Archetype) throws -> SpriteDirector {
        let profile = try PersonalityProfile.load(archetype)
        return SpriteDirector(profile: profile, seed: 20261010 + UInt64(Archetype.allCases.firstIndex(of: archetype) ?? 0))
    }

    func testFaceRectHitMathPerArchetype() {
        for archetype in Archetype.allCases {
            let f = SpriteStageMetadata.meta(for: archetype).faceRect
            // Center of the rect is inside.
            XCTAssertTrue(SpriteStageMetadata.isFaceCell(archetype, x: f.x + f.w / 2, y: f.y + f.h / 2),
                          "\(archetype): rect center must hit")
            // Top-left corner cell is inside; one cell past each edge is out.
            XCTAssertTrue(SpriteStageMetadata.isFaceCell(archetype, x: f.x, y: f.y))
            XCTAssertFalse(SpriteStageMetadata.isFaceCell(archetype, x: f.x + f.w, y: f.y + f.h / 2))
            XCTAssertFalse(SpriteStageMetadata.isFaceCell(archetype, x: f.x + f.w / 2, y: f.y + f.h))
            XCTAssertFalse(SpriteStageMetadata.isFaceCell(archetype, x: f.x - 1, y: f.y + f.h / 2))
            // The shadow row is never face.
            XCTAssertFalse(SpriteStageMetadata.isFaceCell(archetype, x: 10, y: SpriteStageMetadata.meta(for: archetype).shadowRow))
        }
    }

    func testBoopAckWithinTwoTicksAndFlushPlacement() throws {
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            d.advance(toTick: 10)
            XCTAssertTrue(d.boopFace(), "\(archetype): first boop accepted")
            // Ack (happy) begins within <= 2 ticks.
            var ackTick = -1
            for t in 11...12 {
                d.advance(toTick: t)
                if d.currentFrame == "happy" { ackTick = t }
            }
            XCTAssertGreaterThan(ackTick, 0, "\(archetype): happy ack within 2 ticks")
            // Flush: exactly the 2 authored accent cells while the blush lives.
            let cells = d.transientOverlayCells
            XCTAssertEqual(cells.count, 2)
            XCTAssertTrue(cells.allSatisfy { $0.symbol == "A" })
            let expected = SpriteStageMetadata.blushCells(archetype)
            XCTAssertEqual(Set(cells.map { "\($0.x),\($0.y)" }), Set(expected.map { "\($0.x),\($0.y)" }))
        }
    }

    func testBlushLifetimeExactlySixTicks() throws {
        let d = try director(.ember)
        d.advance(toTick: 5)
        XCTAssertTrue(d.boopFace())
        var blushTicks = 0
        for t in 6...20 {
            d.advance(toTick: t)
            if d.transientOverlayCells.contains(where: { $0.symbol == "A" }) { blushTicks += 1 }
        }
        XCTAssertEqual(blushTicks, SpriteDirector.blushDurationTicks, "flush lives exactly 6 ticks")
    }

    func testRefractoryNinetySecondsAndFallback() throws {
        let d = try director(.willow)
        d.advance(toTick: 100)
        XCTAssertTrue(d.boopFace())
        // Within 600 ticks the boop is refused -> caller routes to the pool.
        d.advance(toTick: 100 + SpriteDirector.boopRefractoryTicks - 1)
        XCTAssertFalse(d.boopFace(), "refractory still active at 599 ticks")
        d.advance(toTick: 100 + SpriteDirector.boopRefractoryTicks)
        XCTAssertTrue(d.boopFace(), "refractory clears at exactly 600 ticks")
    }

    func testBoopSuppressedInWorkoutAndRest() throws {
        let d = try director(.nimbus)
        d.advance(toTick: 50)
        d.setWorkoutMode(true)
        XCTAssertFalse(d.boopFace(), "no boop while the run is the motion")
        d.setWorkoutMode(false)
        d.setResting(true)
        XCTAssertFalse(d.boopFace(), "no boop while resting")
    }
}
