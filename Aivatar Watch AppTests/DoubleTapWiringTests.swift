import XCTest
@testable import Aivatar_Watch_App

/// Aivatar 2.0 E6 — double tap ("pinch, and it plays"). The stage element's
/// primary action and the VoiceOver "Play signature move" named action route
/// through the SAME path (performQuirk -> gesture(name: quirkGesture)), so for
/// the same tick + seed they must produce the identical act stream. These
/// tests pin that parity at the director level plus the <= 2-tick ack latency
/// (U7). Hardware double-tap reachability is covered by the manual checklist
/// in Tools/visual_smoke_test.sh (not reliably simulable).
final class DoubleTapWiringTests: XCTestCase {

    private func director(_ archetype: Archetype) throws -> SpriteDirector {
        let profile = try PersonalityProfile.load(archetype)
        return SpriteDirector(profile: profile, seed: 20261010 + UInt64(Archetype.allCases.firstIndex(of: archetype) ?? 0))
    }

    func testPrimaryActionParitySameTickSameSeed() throws {
        for archetype in Archetype.allCases {
            // Path A: the primary action (double tap) -> quirk gesture event.
            let a = try director(archetype)
            // Path B: the VoiceOver named action -> the identical event.
            let b = try director(archetype)
            for t in 1...30 { a.advance(toTick: t); b.advance(toTick: t) }
            a.handleEvent(.gesture(name: archetype.quirkGesture.rawValue))
            b.handleEvent(.gesture(name: archetype.quirkGesture.rawValue))
            for t in 31...80 {
                a.advance(toTick: t)
                b.advance(toTick: t)
                XCTAssertEqual(a.currentFrame, b.currentFrame,
                               "\(archetype): primary action and VO action diverge at tick \(t)")
            }
        }
    }

    func testQuirkAckWithinTwoTicks() throws {
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            for t in 1...20 { d.advance(toTick: t) }
            d.handleEvent(.gesture(name: archetype.quirkGesture.rawValue))
            var acted = false
            for t in 21...22 {
                d.advance(toTick: t)
                if d.pendingActTicks > 0 || d.currentFrame != "idle" { acted = true }
            }
            XCTAssertTrue(acted, "\(archetype): ack act must begin within 2 ticks (300 ms, U7)")
        }
    }

    func testQuirkIsDeterministicAcrossRuns() throws {
        let archetype = Archetype.prism
        func run() -> [String] {
            let d = try! director(archetype)
            var frames: [String] = []
            for t in 1...40 { d.advance(toTick: t) }
            d.handleEvent(.gesture(name: archetype.quirkGesture.rawValue))
            for t in 41...100 { d.advance(toTick: t); frames.append(d.currentFrame) }
            return frames
        }
        XCTAssertEqual(run(), run(), "same seed + same event tick => identical act stream")
    }
}
