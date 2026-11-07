import XCTest
@testable import Aivatar_Watch_App

/// v22 suite for F7 (haptic language) + F8 (postcards): the moment->haptic
/// grammar (parity, shape consistency, limiter caps under adversarial
/// bursts) and the postcard composer (determinism pins, caption lint,
/// corrupt-input fallback, privacy).
final class HapticsAndPostcardTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_793_620_800)

    // MARK: - F7 HapticGrammar

    func testEveryMomentHasAnAnswerForEveryArchetype() {
        for moment in HapticMoment.allCases {
            for archetype in Archetype.allCases {
                // WKHapticType is a struct enum; just exercise the table.
                _ = HapticGrammar.type(for: moment, archetype: archetype)
            }
        }
        // Shape consistency: one moment = one haptic shape (single tick or
        // the bond pair) — never a loop, never silent-but-meaningful.
        XCTAssertTrue(HapticGrammar.isPair(.bond))
        for moment in HapticMoment.allCases where moment != .bond {
            XCTAssertFalse(HapticGrammar.isPair(moment))
        }
        // Same moment, same shape class across archetypes: split/farewell/
        // greet/wake are identical for all five (only ack/lifeEvent flavor).
        for moment in [HapticMoment.split, .farewell, .greet, .wake] {
            let types = Set(Archetype.allCases.map { HapticGrammar.type(for: moment, archetype: $0) })
            XCTAssertEqual(types.count, 1, "\(moment.rawValue) must be one identical haptic for all archetypes")
        }
    }

    func testRateLimiterCapsUnderAdversarialBurst() {
        var limiter = HapticRateLimiter()
        // A storm of 50 haptics at the same instant: the min interval lets
        // exactly one through.
        var burst = 0
        for _ in 0..<50 {
            if limiter.allowing(now: now) { burst += 1 }
        }
        XCTAssertEqual(burst, 1, "same-instant storm: one haptic (min interval)")
        // Spread over time: capped at 6 per rolling hour.
        var hour = 0
        for i in 0..<20 {
            if limiter.allowing(now: now.addingTimeInterval(Double(i) * 2)) { hour += 1 }
        }
        XCTAssertEqual(burst + hour, HapticRateLimiter.maxPerHour, "capped at 6/hour in total")
        // The hour rolls: the old entries expire, 6 more are allowed.
        var nextHour = 0
        for i in 0..<20 {
            if limiter.allowing(now: now.addingTimeInterval(3_600 + Double(i) * 2)) { nextHour += 1 }
        }
        XCTAssertEqual(nextHour, HapticRateLimiter.maxPerHour, "caps are per rolling hour")
    }

    // MARK: - F8 PostcardComposer

    private func inputs(_ archetype: Archetype, seed: UInt64 = 20261111) -> PostcardInputs {
        PostcardInputs(archetypeRaw: archetype.rawValue, seed: seed, name: archetype.displayName,
                       bondLevel: 3, dayCount: 23, streakDays: 5, weatherClassRaw: "rain")
    }

    func testPostcardFramesAreDeterministicPerSeed() {
        for archetype in Archetype.allCases {
            let a = PostcardComposer.frameHashes(inputs(archetype))
            let b = PostcardComposer.frameHashes(inputs(archetype))
            XCTAssertEqual(a, b, "\(archetype.rawValue): same inputs -> same hashes")
            XCTAssertEqual(a.count, PostcardComposer.frameCount)
            // Different seed -> different card (the seed matters).
            let c = PostcardComposer.frameHashes(inputs(archetype, seed: 999))
            XCTAssertNotEqual(a, c, "\(archetype.rawValue): different seed, different card")
        }
    }

    func testPostcardGoldenPins() {
        // v22 golden pins (first pin 2026-11-07): frame-hash prefixes per
        // archetype (seed 20261111, bond 3, day 23, streak 5, rain).
        let expected: [Archetype: UInt64] = [
            // Pinned 2026-11-07 (v22); re-pinned 2026-11-07 (v28): ember base
            // tail-tip cell, compass base mouth + happy patch, and nimbus
            // idleB foot step change the authored frames; willow and prism
            // first frames are unchanged.
            .ember: 2_189_887_195_745_852_862,
            .willow: 5_779_802_598_010_730_844,
            .compass: 5_426_752_643_789_965_734,
            .prism: 2_059_382_512_568_751_236,
            .nimbus: 11_416_384_784_677_474_054,
        ]
        var recorded: [String] = []
        for archetype in Archetype.allCases {
            let hashes = PostcardComposer.frameHashes(inputs(archetype))
            let first = hashes.first ?? 0
            recorded.append("\(archetype.rawValue) = \(first)")
            let pin = expected[archetype] ?? 0
            if pin != 0 {
                XCTAssertEqual(first, pin, "\(archetype.rawValue) postcard changed")
            }
        }
        PinRecorder.requirePinned(expected, recorded: recorded.joined(separator: ", "), label: "postcard pins")
    }

    func testPostcardCaptionLintAndPrivacy() {
        let cap = PostcardComposer.caption(inputs(.ember))
        XCTAssertTrue(cap.contains("Ember"))
        XCTAssertTrue(cap.contains("day 23"))
        XCTAssertTrue(cap.contains("rain day"))
        XCTAssertLessThanOrEqual(cap.split(separator: " ").count, 8)
        let confidant = PostcardComposer.caption(PostcardInputs(
            archetypeRaw: "willow", seed: 1, name: "Willow", bondLevel: 5, dayCount: 40))
        XCTAssertTrue(confidant.contains("old friends"))
        XCTAssertFalse(confidant.contains("workoutDone"), "no raw kinds in captions")
        // Unknown weather class contributes nothing.
        let noWeather = PostcardComposer.caption(PostcardInputs(
            archetypeRaw: "compass", seed: 1, name: "Compass", dayCount: 3, weatherClassRaw: "unknown"))
        XCTAssertEqual(noWeather, "Compass · day 3")
    }

    func testPostcardCorruptInputsFallBackToWarmGreeting() {
        let corrupt = PostcardInputs(archetypeRaw: "not-an-animal", seed: 5, name: "???",
                                     bondLevel: 3, dayCount: -4)
        let hashes = PostcardComposer.frameHashes(corrupt)
        XCTAssertEqual(hashes.count, PostcardComposer.frameCount, "a corrupt card still composes")
        // Unknown archetype degrades to the default companion, same seed.
        let fallback = PostcardComposer.frameHashes(PostcardInputs(
            archetypeRaw: "ember", seed: 5, name: "???", bondLevel: 3, dayCount: 1))
        XCTAssertEqual(hashes, fallback)
    }

    func testPostcardFramesStayOnGrid() {
        for archetype in Archetype.allCases {
            for grid in PostcardComposer.frames(inputs(archetype)) {
                XCTAssertEqual(grid.count, CompanionSprite.gridHeight)
                for row in grid { XCTAssertEqual(row.count, CompanionSprite.gridWidth) }
            }
        }
    }
}
