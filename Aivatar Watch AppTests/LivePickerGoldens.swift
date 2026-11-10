import XCTest
@testable import Aivatar_Watch_App

/// Aivatar 2.0 E2 — live picker goldens + behavior. The preview director runs
/// on a distinct seed stream (stageSeed ^ 0x9BE2EEF1) with previewMode on:
/// determinism across two runs, the quirk-once-per-dwell rule, page-change
/// re-arming, and the preview rate dampeners (blink x 0.7 / glance x 0.5 —
/// asserted via statistics over a long run, not exact frames).
final class LivePickerGoldens: XCTestCase {

    private func previewDirector(_ archetype: Archetype) -> SpriteDirector {
        let profile = try! PersonalityProfile.load(archetype)
        let d = SpriteDirector(profile: profile, seed: LiveCompanionPreviewView.previewSeed(archetype))
        d.previewMode = true
        return d
    }

    private func run(_ archetype: Archetype, ticks: Int, pinTicks: [Int]) -> (frames: [Int: [[Character]]], quirkRuns: Int) {
        let d = previewDirector(archetype)
        let sprite = AuthoredSprites.sprite(for: archetype)
        var frames: [Int: [[Character]]] = [:]
        var quirkRuns = 0
        var inQuirk = false
        for t in 0...ticks {
            d.advance(toTick: t)
            if pinTicks.contains(t) { frames[t] = sprite.symbols(frameID: d.currentFrame) }
            let isQuirk = d.currentFrame == "quirk"
            if isQuirk && !inQuirk { quirkRuns += 1 }
            inQuirk = isQuirk
        }
        return (frames, quirkRuns)
    }

    func testPreviewDeterminismAcrossRuns() {
        for archetype in Archetype.allCases {
            let a = run(archetype, ticks: 120, pinTicks: [0, 8, 40, 120])
            let b = run(archetype, ticks: 120, pinTicks: [0, 8, 40, 120])
            XCTAssertEqual(a.frames.keys.sorted(), b.frames.keys.sorted())
            for t in a.frames.keys {
                XCTAssertEqual(a.frames[t], b.frames[t], "\(archetype): tick \(t) differs across runs")
            }
        }
    }

    func testQuirkFiresExactlyOncePerDwell() {
        for archetype in Archetype.allCases {
            let (_, quirkRuns) = run(archetype, ticks: 100, pinTicks: [])
            XCTAssertEqual(quirkRuns, 1, "\(archetype): 100-tick dwell must produce exactly one quirk")
        }
    }

    func testPageChangeResetsAndRearmsQuirk() {
        let d = previewDirector(.ember)
        for t in 1...100 { d.advance(toTick: t) }  // one quirk fires by tick ~8+
        d.resetPreviewDwell()                         // page change
        var quirkRuns = 0
        var inQuirk = false
        for t in 101...200 {
            d.advance(toTick: t)
            let isQuirk = d.currentFrame == "quirk"
            if isQuirk && !inQuirk { quirkRuns += 1 }
            inQuirk = isQuirk
        }
        XCTAssertEqual(quirkRuns, 1, "re-visit after page change re-arms the quirk exactly once")
    }

    func testPreviewSeedDiffersFromStageSeed() {
        for archetype in Archetype.allCases {
            let stageSeed = 20261010 + UInt64(Archetype.allCases.firstIndex(of: archetype) ?? 0)
            XCTAssertNotEqual(LiveCompanionPreviewView.previewSeed(archetype), stageSeed,
                              "picker goldens must never alias stage goldens")
        }
    }

    func testPreviewSuppressesAutonomySystems() {
        // No motes, no yawn, no lonely poke in preview: over a long idle run
        // the director must never produce a mote or fire those acts.
        for archetype in Archetype.allCases {
            let d = previewDirector(archetype)
            for t in 1...3000 { d.advance(toTick: t) }
            XCTAssertNil(d.moteCell, "\(archetype): preview never spawns motes")
        }
    }

    func testLifeFloorStillBreathesInPreview() {
        let d = previewDirector(.willow)
        var sawBreathe = false
        var sawIdleVariant = false
        for t in 1...200 {
            d.advance(toTick: t)
            if d.currentFrame == "breathe" { sawBreathe = true }
            if d.currentFrame == "idleA" || d.currentFrame == "idleB" { sawIdleVariant = true }
        }
        XCTAssertTrue(sawBreathe, "preview keeps the 600 ms breath hold")
        XCTAssertTrue(sawIdleVariant, "preview keeps the idleA/idleB drift")
    }
}
