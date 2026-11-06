import XCTest
@testable import Aivatar_Watch_App

/// v14 sonic presence suite (Tools/PIXEL_DESIGN.md §7 — sonic presence).
/// The mic is impure; everything downstream is pure: synthetic loudness
/// fixtures pin the detector schedules and rate budgets, and the director's
/// reaction map is asserted per archetype — the same discipline as the
/// blink/saccade rate budgets.
final class SoundPresenceTests: XCTestCase {

    private func run(_ layer: SoundPresenceLayer, levels: [Float]) -> [SoundPresenceEvent] {
        levels.flatMap { layer.process(level: $0) }
    }

    private func director(_ archetype: Archetype) throws -> SpriteDirector {
        SpriteDirector(profile: try PersonalityProfile.load(archetype), seed: 20261103)
    }

    // MARK: - Detector fixtures

    func testSilenceEmitsNoEvents() {
        let layer = SoundPresenceLayer()
        XCTAssertTrue(run(layer, levels: Array(repeating: 0.008, count: 1200)).isEmpty,
                      "a quiet room must produce zero awareness events")
    }

    func testVoiceUtteranceFiresOnceThenRearms() {
        let layer = SoundPresenceLayer()
        var events: [SoundPresenceEvent] = []
        // 2 s quiet (arms the voice detector from a clean baseline).
        events += run(layer, levels: Array(repeating: 0.01, count: 40))
        // 3 s of sustained voice-band level (0.12).
        events += run(layer, levels: Array(repeating: 0.12, count: 60))
        XCTAssertEqual(events.filter { $0 == .voiceSustained }.count, 1,
                       "one utterance = one acknowledgment")
        // Still talking: the 10 s refractory holds.
        events += run(layer, levels: Array(repeating: 0.12, count: 100))
        XCTAssertEqual(events.filter { $0 == .voiceSustained }.count, 1,
                       "no re-fire inside the refractory")
        // A second utterance after the 10 s refractory + a quiet re-arm
        // is acknowledged again.
        events += run(layer, levels: Array(repeating: 0.01, count: 230))
        let before = events.filter { $0 == .voiceSustained }.count
        events += run(layer, levels: Array(repeating: 0.14, count: 60))
        XCTAssertEqual(events.filter { $0 == .voiceSustained }.count, before + 1,
                       "a later utterance gets its own acknowledgment")
    }

    func testConstantLoudAmbienceIsNotAConversation() {
        // The assessment's red line: constant rain/traffic/engine ambience
        // does nothing. The initial step IS one onset; nothing after.
        let layer = SoundPresenceLayer()
        var events: [SoundPresenceEvent] = []
        events += run(layer, levels: Array(repeating: 0.01, count: 40))
        events += run(layer, levels: Array(repeating: 0.35, count: 700))
        XCTAssertEqual(events.filter { $0 == .voiceSustained }.count, 0,
                        "constant loud ambience never reads as voice")
        XCTAssertLessThanOrEqual(events.filter { $0 == .onset }.count, 1,
                                 "the step fires once; the held level is silence")
    }

    func testVoiceInsideVeryLoudNoiseDisarms() {
        // You cannot have a conversation inside a blender: the band ceiling
        // disarms the detector instead of saturating it.
        let layer = SoundPresenceLayer()
        var events: [SoundPresenceEvent] = []
        events += run(layer, levels: Array(repeating: 0.01, count: 40))
        events += run(layer, levels: Array(repeating: 0.9, count: 400))
        XCTAssertEqual(events.filter { $0 == .voiceSustained }.count, 0)
    }

    func testSingleTransientIsAnOnset() {
        let layer = SoundPresenceLayer()
        var levels: [Float] = Array(repeating: 0.01, count: 40)
        levels.append(0.5)
        levels += Array(repeating: 0.01, count: 40)
        let events = run(layer, levels: levels)
        XCTAssertEqual(events.filter { $0 == .onset }.count, 1, "a clap is exactly one onset")
    }

    func testSubFloorNoiseNeverOnsets() {
        // Wrist friction and rustle stay under the absolute floor.
        let layer = SoundPresenceLayer()
        var levels: [Float] = Array(repeating: 0.01, count: 40)
        levels += [0.3, 0.09, 0.09, 0.1, 0.09]
        levels += Array(repeating: 0.01, count: 40)
        XCTAssertEqual(run(layer, levels: levels).filter { $0 == .onset }.count, 1,
                       "only the real transient above the floor counts")
    }

    func testClapStormStaysInsideTheOnsetBudget() {
        // Rate budget (§7): a clap every half-second must produce bounded
        // onsets — the refractory (1.2 s) pins it at ~50/min regardless
        // of how hard the user tries.
        let layer = SoundPresenceLayer()
        var events: [SoundPresenceEvent] = []
        events += run(layer, levels: Array(repeating: 0.01, count: 40))
        for _ in 0..<60 {
            events += run(layer, levels: [0.8, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01])
        }
        let onsets = events.filter { $0 == .onset }.count
        XCTAssertLessThanOrEqual(onsets, 25, "onset storm bounded (\(onsets) in 30 s)")
        XCTAssertGreaterThanOrEqual(onsets, 10, "real claps still register")
    }

    // MARK: - Director reaction map

    func testOnsetPerksEveryAnimal() throws {
        // A startle plays the authored alert pose — the animal's "ear".
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            d.handleSound(.onset)
            XCTAssertEqual(d.currentFrame, "perk", "\(archetype.rawValue): clap -> perk")
        }
    }

    func testVoiceAcknowledgmentPerArchetype() throws {
        // Personality-owned acknowledgments (the sonic reaction map):
        // ember perks toward you, willow blinks slowly, compass ticks,
        // prism locks the turret on you, nimbus chirps.
        let ember = try director(.ember)
        ember.handleSound(.voiceSustained)
        XCTAssertEqual(ember.currentFrame, "perk")

        let willow = try director(.willow)
        willow.handleSound(.voiceSustained)
        willow.advance(toTick: willow.tick + 3)
        XCTAssertEqual(willow.currentFrame, "blink")

        let compass = try director(.compass)
        compass.handleSound(.voiceSustained)
        XCTAssertEqual(compass.currentFrame, "perk", "the tick answers with a wind-up")
        compass.advance(toTick: compass.tick + 1)
        XCTAssertEqual(compass.currentFrame, "quirk", "...then the metronome tick")

        let prism = try director(.prism)
        prism.handleSound(.voiceSustained)
        XCTAssertEqual(prism.currentFrame, "glanceR")

        let nimbus = try director(.nimbus)
        nimbus.handleSound(.voiceSustained)
        XCTAssertEqual(nimbus.currentFrame, "happy")
    }

    func testSoundActGapBounded() throws {
        // A clap storm cannot chain perks: sound acts respect a 2.4 s
        // director-side gap, so a noisy room still leaves the stage quiet.
        let d = try director(.ember)
        d.handleSound(.onset)
        let afterFirst = d.actCount
        for _ in 0..<10 {
            d.advance(toTick: d.tick + 1)
            d.handleSound(.onset)
        }
        XCTAssertEqual(d.actCount, afterFirst, "sound acts inside the gap are dropped")
        d.advance(toTick: d.tick + SpriteDirector.soundActGapTicks)
        d.handleSound(.onset)
        XCTAssertEqual(d.actCount, afterFirst + 1, "a later onset earns a new act")
    }

    func testReduceMotionL2SoundIsFaceReadableBlink() throws {
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            d.accessibilityMode = .reduceMotionL2
            d.handleSound(.onset)
            XCTAssertEqual(d.currentFrame, "blink", "\(archetype.rawValue): L2 degrades sound to the face")
        }
    }

    func testRestingCompanionNeverReactsToSound() throws {
        let d = try director(.willow)
        d.setResting(true)
        d.handleSound(.onset)
        d.handleSound(.voiceSustained)
        XCTAssertEqual(d.currentFrame, "sleepy", "the mic is dead in the rest state; so are reactions")
    }
}
