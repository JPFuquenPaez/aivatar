import XCTest
@testable import Aivatar_Watch_App

/// v36 — PhoneCompanionAnimator (the iPhone shell's living avatar). The phone
/// runs the SAME authored sprite on the SAME 150 ms clock; these pins lock
/// determinism, the life-floor schedule, the asleep mode, quirk cadence and
/// palette legality (the sprite's symbols are the 5-token ramp only).
final class PhoneCompanionAnimatorTests: XCTestCase {

    private func frames(_ archetype: Archetype, _ presence: CompanionPresence, _ ticks: Int) -> [String] {
        let a = PhoneCompanionAnimator(archetype: archetype, presence: presence)
        var out: [String] = []
        for t in 1...ticks {
            a.advance(toTick: t)
            out.append(a.currentFrame)
        }
        return out
    }

    func testDeterministicSameSeedSameFrames() {
        for archetype in Archetype.allCases {
            let fa = frames(archetype, .awake, 300)
            let fb = frames(archetype, .awake, 300)
            XCTAssertEqual(fa, fb, "\(archetype): same seed + tick -> same frame sequence")
        }
    }

    func testLifeFloorBreatheSchedule() {
        for archetype in Archetype.allCases {
            let fs = frames(archetype, .awake, 48)
            // Breathe holds 4 ticks every 24: ticks 24..<28 (0-based frames 23..26)
            // must be the breathe frame.
            let breatheTicks = (24..<28).map { fs[$0 - 1] }
            XCTAssertTrue(breatheTicks.allSatisfy { $0 == "breathe" },
                          "\(archetype): breathe holds ticks 24-27, got \(breatheTicks)")
        }
    }

    func testAsleepOnlyRestFaces() {
        for archetype in Archetype.allCases {
            let fs = frames(archetype, .asleep, 300)
            XCTAssertTrue(fs.allSatisfy { $0 == "sleepy" || $0 == "blink" },
                          "\(archetype): asleep shows only sleepy/blink, got \(Set(fs))")
        }
    }

    func testQuirkCadenceBounds() {
        // Quirk frames per 1000 ticks (a quirk holds up to 12 ticks; the
        // breathe floor can cut one short). Awake p=1/240 per idle tick,
        // event p=1/90 — event must quirk clearly more often than awake.
        for archetype in Archetype.allCases {
            let awake = frames(archetype, .awake, 1000).filter { $0 == "quirk" }.count
            let event = frames(archetype, .event, 1000).filter { $0 == "quirk" }.count
            XCTAssertGreaterThanOrEqual(awake, 12, "\(archetype): at least one full quirk per 1000 awake ticks")
            XCTAssertLessThanOrEqual(awake, 72, "\(archetype): awake quirk bounded")
            XCTAssertGreaterThan(event, awake, "\(archetype): event presence quirks more often")
            XCTAssertLessThanOrEqual(event, 156, "\(archetype): event quirk bounded")
        }
    }

    func testSpriteSymbolsStayWithinFiveTokenRamp() {
        for archetype in Archetype.allCases {
            let sprite = AuthoredSprites.sprite(for: archetype)
            XCTAssertLessThanOrEqual(sprite.paletteHex.count, 5, "\(archetype): palette budget")
            for frame in CompanionSprite.frameIDs {
                let grid = sprite.symbols(frameID: frame)
                for row in grid {
                    for s in row where s != "." {
                        XCTAssertNotNil(sprite.paletteHex[s], "\(archetype) \(frame): symbol \(s) has a palette entry")
                    }
                }
            }
        }
    }
}
