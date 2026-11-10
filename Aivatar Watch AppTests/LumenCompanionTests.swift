import XCTest
@testable import Aivatar_Watch_App

/// Aivatar 2.0 Phase 3, E10 — the sixth companion (lumen, the moth). Parity
/// across every per-archetype surface: profile loads + weights sum, sprite
/// grid contract (20x18, 5 tokens, all 12 frames resolve), metadata present,
/// reaction tables answer, haptic grammar maps, unlock gating + one-time
/// reveal, picker shows five pages until revealed.
final class LumenCompanionTests: XCTestCase {

    func testProfileLoadsAndWeightsSum() throws {
        let profile = try PersonalityProfile.load(.lumen)
        XCTAssertEqual(profile.id, "lumen")
        XCTAssertEqual(profile.assetVersion, "3.0.0")
        let sum = profile.gesturePoolWeights.values.reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 0.02)
        XCTAssertEqual(profile.gazePolicy, .linger)
        XCTAssertEqual(profile.tell, .dust)
        XCTAssertEqual(profile.motionProfile.tempoScale, 0.9)
        XCTAssertEqual(profile.blink?.durationScale, 1.2)
    }

    func testSpriteGridContract() {
        let sprite = AuthoredSprites.sprite(for: .lumen)
        XCTAssertEqual(sprite.base.count, 18)
        for row in sprite.base { XCTAssertEqual(row.count, 20) }
        let used = Set(sprite.base.joined()).subtracting(["."])
        XCTAssertLessThanOrEqual(used.count, 5)
        XCTAssertTrue(used.isSubset(of: Set("KDBWA")))
        // All 12 frame IDs resolve to a valid 20x18 grid.
        for frame in CompanionSprite.frameIDs {
            let grid = sprite.symbols(frameID: frame)
            XCTAssertEqual(grid.count, 18)
            XCTAssertTrue(grid.allSatisfy { $0.count == 20 })
        }
        // The quirk patch is the 6-cell luminous wing shimmer.
        let quirk = sprite.patches["quirk"] ?? []
        XCTAssertEqual(quirk.count, 6)
        XCTAssertTrue(quirk.allSatisfy { $0.symbol == "A" })
        // Palette has exactly the 5 tokens.
        XCTAssertEqual(sprite.paletteHex.count, 5)
    }

    func testMetadataPresent() {
        let m = SpriteStageMetadata.meta(for: .lumen)
        XCTAssertTrue(SpriteStageMetadata.isFaceCell(.lumen, x: 9, y: 2))
        XCTAssertFalse(SpriteStageMetadata.isFaceCell(.lumen, x: 9, y: 14))
        XCTAssertFalse(SpriteStageMetadata.shadowCells(.lumen).isEmpty)
        XCTAssertEqual(SpriteStageMetadata.blushCells(.lumen).count, 2)
        XCTAssertEqual(SpriteStageMetadata.vaporCells(.lumen).count, 2)
    }

    func testReactionTablesAnswerForLumen() {
        for event: LifeEvent in [.calendarSoon(titleHash: 1), .workoutDone(kindBand: 1, durationBand: 2),
                                 .sleptWithWatch, .weatherClass(classHash: ConditionClass.sunny.hash),
                                 .split(distanceKm: 1)] {
            XCTAssertNotNil(SpriteDirector.reactionAct(for: event, archetype: .lumen),
                            "\(event) must have a lumen answer")
        }
        XCTAssertNotNil(SpriteDirector.weatherAct(for: .cold, archetype: .lumen))
        XCTAssertNil(SpriteDirector.weatherAct(for: .unknown, archetype: .lumen))
        XCTAssertNotNil(HapticGrammar.type(for: .ack, archetype: .lumen))
        XCTAssertNotNil(HapticGrammar.type(for: .lifeEvent, archetype: .lumen))
    }

    func testUnlockGatingAndRevealFlag() {
        // Locked below confidant.
        XCTAssertFalse(BondRules.sixthCompanionUnlocked(4))
        XCTAssertTrue(BondRules.sixthCompanionUnlocked(5))
        // Reveal flag: once set, the picker shows six pages (pure gate).
        var m = CompanionMemory(firstLaunch: Date(), lastSeen: Date())
        m.bondXP = 100
        m.sixthRevealed = true
        XCTAssertTrue(BondRules.sixthCompanionUnlocked(m.bondLevel) && m.sixthRevealed)
        // Legacy memory: flag defaults false.
        let legacy = #"{"firstLaunch": 1793620800, "lastSeen": 1793620800}"#.data(using: .utf8)!
        XCTAssertFalse((try? JSONDecoder().decode(CompanionMemory.self, from: legacy))?.sixthRevealed ?? true)
    }

    func testLocalizedIdentityResolves() {
        XCTAssertEqual(LocalizedAnimalCopy.name("lumen"), "Moth")
        XCTAssertEqual(LocalizedAnimalCopy.element("lumen"), "night")
        XCTAssertFalse(LocalizedAnimalCopy.temperament("lumen").isEmpty)
        XCTAssertTrue(LocalizedAnimalCopy.isKnown("lumen"))
        XCTAssertEqual(Archetype.lumen.animal.name, "Moth")
        XCTAssertEqual(Archetype.lumen.quirkGesture, .sparkle)
        XCTAssertEqual(Archetype.lumen.farewellGesture, .slowBlink)
    }

    func testDirectorParityForLumen() throws {
        // The director runs a deterministic schedule for the sixth companion.
        let profile = try PersonalityProfile.load(.lumen)
        let a = SpriteDirector(profile: profile, seed: 20261010 + 5)
        let b = SpriteDirector(profile: profile, seed: 20261010 + 5)
        for t in 1...300 {
            a.advance(toTick: t); b.advance(toTick: t)
            XCTAssertEqual(a.currentFrame, b.currentFrame)
        }
    }

    func testWidgetSanitizerKnowsLumen() {
        XCTAssertEqual(CompanionStateDerivation.sanitizedArchetypeRaw("lumen"), "lumen")
        XCTAssertEqual(CompanionStateDerivation.sanitizedArchetypeRaw("dragon"), "ember")
    }
}
