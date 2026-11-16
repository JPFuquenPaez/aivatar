import XCTest
import CoreGraphics
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
        // Same moment, same shape class across archetypes: farewell/
        // greet/wake are identical for all six (only ack/lifeEvent flavor).
        for moment in [HapticMoment.farewell, .greet, .wake] {
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

    /// FNV-1a digest over the whole drive run (frame id + pose hash per
    /// frame). The neutral idle frame is family-independent, so a single
    /// frame hash cannot separate archetypes — the run digest can.
    private func runDigest(_ inputs: PostcardInputs) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in inputs.archetypeRaw.utf8 {
            h ^= UInt64(byte); h &+= 0x100000001b3
        }
        for drive in PostcardComposer.drives(inputs) {
            var p = PuppetPoser.resolve(drive).pose.hashValue64()
            for byte in drive.frameID.utf8 {
                h ^= UInt64(byte); h &+= 0x100000001b3
            }
            for _ in 0..<8 {
                h ^= p & 0xff; h &+= 0x100000001b3; p >>= 8
            }
        }
        return h
    }

    func testPostcardGoldenPins() {
        // v22 golden pins (first pin 2026-11-07) re-pinned for v3: the digest
        // of the drive run (seed 20261111, bond 3, day 23, streak 5, rain)
        // per archetype — pose truth layer. Re-record with zeros, paste below.
        let expected: [Archetype: UInt64] = [
            // Re-pinned v44 (Companion Cast v3): pose-run digests.
            .ember: 14_696_253_718_230_453_466,
            .willow: 14_696_254_817_742_083_448,
            .compass: 14_696_255_917_253_706_137,
            .prism: 14_696_253_718_230_452_352,
            .nimbus: 14_696_254_817_742_080_456,
            .lumen: 14_696_253_718_230_454_624,
        ]
        var recorded: [String] = []
        for archetype in Archetype.allCases {
            let digest = runDigest(inputs(archetype))
            recorded.append("\(archetype.rawValue) = \(digest)")
            let pin = expected[archetype] ?? 0
            if pin != 0 {
                XCTAssertEqual(digest, pin, "\(archetype.rawValue) postcard changed")
            }
        }
        PinRecorder.requirePinned(expected, recorded: recorded.joined(separator: ", "), label: "postcard pins")
    }

    func testPostcardCaptionLintAndPrivacy() {
        let cap = PostcardComposer.caption(inputs(.ember))
        XCTAssertTrue(cap.contains("Ember"))
        XCTAssertTrue(cap.contains("day 23"))
        // v30: the weather class is localized (weather.rain = "rainy"), so
        // the en caption reads "rainy day" — was the raw enum "rain day".
        XCTAssertTrue(cap.contains("rainy day"))
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

    func testPostcardFramesResolveAsPoses() throws {
        // v3: a card's frames are puppet drives — all 20 resolve through
        // the poser, and the clay moment images render for every one.
        for archetype in Archetype.allCases {
            let drives = PostcardComposer.drives(inputs(archetype))
            XCTAssertEqual(drives.count, PostcardComposer.frameCount, "\(archetype.rawValue): 20 drives")
            for drive in drives {
                let resolved = PuppetPoser.resolve(drive)
                XCTAssertNotNil(resolved.pose)
            }
            let images = PostcardComposer.frameImages(inputs(archetype))
            XCTAssertEqual(images.count, PostcardComposer.frameCount,
                           "\(archetype.rawValue): every frame renders a clay moment")
        }
        // Corrupt inputs degrade the SAME way in drives space.
        let corrupt = PostcardInputs(archetypeRaw: "not-an-animal", seed: 5, name: "???",
                                     bondLevel: 3, dayCount: -4)
        XCTAssertEqual(PostcardComposer.drives(corrupt).count, PostcardComposer.frameCount,
                       "a corrupt card still composes")
    }
}
