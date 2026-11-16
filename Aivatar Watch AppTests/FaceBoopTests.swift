import XCTest
import CoreGraphics
@testable import Aivatar_Watch_App

/// Aivatar 2.0 E7 — boop the face (v3 geometry). The face is a hit CIRCLE
/// (PuppetDrawing maps the toy head disc, not a cell rect): center/edge/outside
/// math per archetype, the happy ack within 2 ticks, the blush riding the
/// puppet drive (cheek channel), the 600-tick (90 s) refractory with
/// normal-pool fallback, and session/rest gating.
final class FaceBoopTests: XCTestCase {

    private func director(_ archetype: Archetype) throws -> SpriteDirector {
        let profile = try PersonalityProfile.load(archetype)
        return SpriteDirector(profile: profile, seed: 20261010 + UInt64(Archetype.allCases.firstIndex(of: archetype) ?? 0))
    }

    func testHeadCircleHitMathPerArchetype() {
        let canvas = CGSize(width: 200, height: 320)
        for archetype in Archetype.allCases {
            let hit = PuppetDrawing.headHitCircle(archetype: archetype, canvas: canvas)
            // The circle's own center is inside.
            XCTAssertTrue(hypot(0, 0) <= hit.radius, "\(archetype): center must hit")
            // Slightly inside the rim is a hit; just past the rim is not.
            XCTAssertTrue(hypot(hit.radius * 0.95, 0) <= hit.radius,
                          "\(archetype): inside the rim hits")
            XCTAssertGreaterThan(hit.radius * 1.05, hit.radius)
            // The head disc sits in the upper half of the band, never bottom.
            XCTAssertLessThan(hit.center.y, 0.60 * 320,
                              "\(archetype): head circle sits in the upper band")
            XCTAssertGreaterThan(hit.center.y, 0.05 * 320)
            // Radius tracks the spec: bigger heads (willow 540) out-circle
            // smaller ones (nimbus 480) at the same canvas.
        }
        let willow = PuppetDrawing.headHitCircle(archetype: .willow, canvas: canvas)
        let nimbus = PuppetDrawing.headHitCircle(archetype: .nimbus, canvas: canvas)
        XCTAssertGreaterThan(willow.radius, nimbus.radius, "radius follows the head diameter")
    }

    func testBoopAckWithinTwoTicksAndBlushChannel() throws {
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            var drive = d.puppetDrive(atTick: 10)
            XCTAssertFalse(drive.blushing, "\(archetype): no flush at rest")
            XCTAssertTrue(d.boopFace(), "\(archetype): first boop accepted")
            // The landing frame (sampled at the boop's own tick, pre-advance)
            // carries the pulse; the stage renders exactly this.
            drive = d.puppetDrive(atTick: d.tick)
            XCTAssertTrue(drive.blushing, "\(archetype): flush rides the drive")
            XCTAssertTrue(drive.boopPulse, "\(archetype): the landing tick is the pulse")
            XCTAssertTrue(PuppetPoser.resolve(drive).pose.cheekGlow >= 0.85,
                          "\(archetype): blush paints the cheek channel")
            // Ack (happy) begins within <= 2 ticks.
            var ackTick = -1
            for t in 11...12 {
                drive = d.puppetDrive(atTick: t)
                if drive.frameID == "happy" { ackTick = t }
            }
            XCTAssertGreaterThan(ackTick, 0, "\(archetype): happy ack within 2 ticks")
        }
    }

    func testBlushLifetimeExactlySixTicks() throws {
        let d = try director(.ember)
        d.advance(toTick: 5)
        XCTAssertTrue(d.boopFace())
        var blushTicks = 0
        for t in 6...20 {
            // Sample the flush as rendered at this tick, before stepping.
            if d.blushing { blushTicks += 1 }
            d.advance(toTick: t)
        }
        XCTAssertEqual(blushTicks, SpriteDirector.blushDurationTicks, "flush lives exactly 6 ticks")
    }

    func testBoopPulseSquashesThePuppet() throws {
        let d = try director(.ember)
        d.advance(toTick: 11)
        XCTAssertTrue(d.boopFace())
        let drive = d.puppetDrive(atTick: d.tick)
        XCTAssertTrue(drive.boopPulse)
        let pose = PuppetPoser.resolve(drive).pose
        XCTAssertLessThan(pose.bodyScaleY, 0.92, "the boop squashes the body")
        XCTAssertGreaterThan(pose.bodyScaleX, 1.05, "and widens it (squash-and-stretch)")
        XCTAssertEqual(pose.mouth, .ws, "the boop is a happy face")
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

    func testBoopSuppressedInSessionAndRest() throws {
        let d = try director(.nimbus)
        d.advance(toTick: 50)
        d.setSessionMode(true)
        XCTAssertFalse(d.boopFace(), "no boop during a breath session")
        d.setSessionMode(false)
        d.setResting(true)
        XCTAssertFalse(d.boopFace(), "no boop while resting")
        // Rest pose never carries a blush: lids heavy, cheeks quiet.
        let drive = d.puppetDrive(atTick: 52)
        XCTAssertTrue(drive.resting)
        XCTAssertFalse(drive.blushing)
        let pose = PuppetPoser.resolve(drive).pose
        XCTAssertLessThan(pose.lidOpen, 0.3, "rest lids stay heavy")
        XCTAssertEqual(pose.cheekGlow, 0, "rest cheeks stay quiet")
    }
}
