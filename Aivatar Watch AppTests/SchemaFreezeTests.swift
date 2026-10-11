import XCTest
@testable import Aivatar_Watch_App

/// A1 schema freeze tests: rig.json v1 and PersonalityProfile v1 decode
/// correctly, registries match the code enums, and every archetype has full
/// gesture-clip parity (§10).
final class SchemaFreezeTests: XCTestCase {
    func testRigIsFrozenAtVersion1() throws {
        let rig = try RigDocument.load(bundle: .main)
        XCTAssertEqual(rig.formatVersion, 1)
    }

    func testExpressionChannelRegistryMatchesPlan() {
        XCTAssertEqual(ExpressionChannel.allCases.map(\.self).count, 10)
        let names = ExpressionChannel.allCases.map { "\($0)" }
        XCTAssertEqual(names, ["joy", "sad", "surprise", "alert", "sleepy", "focus", "warm", "wry", "startle", "rest"])
    }

    func testGestureClipRegistryMatchesPlan() {
        // v5b: +5 owner-exclusive quirk clips (preen, swayCatch, tick,
        // mirror, driftFloat) — one per archetype.
        XCTAssertEqual(GestureClip.allCases.count, 17)
        let names = GestureClip.allCases.map { "\($0)" }
        XCTAssertEqual(names, ["wave", "bounce", "stretch", "spin", "nod", "tilt", "lookAround", "shiftWeight", "shiver", "doubleTake", "sparkle", "puff", "preen", "swayCatch", "tick", "mirror", "driftFloat"])
    }

    func testAllFiveProfilesLoadAndMatchArchetypes() throws {
        // §10 semantic versioning per archetype set. 2.0.0 (A5a): the v3
        // unified cloud-species — tint + token + tell stack; schema v2
        // fields (speciesTokens, motionGrammar, gazePolicy, blink, tell,
        // quirkLoop, voiceStyle) are additive and validated below.
        let expectedVersions: [Archetype: String] = [
            .ember: "2.0.0", .willow: "2.0.0", .compass: "2.0.0",
            .prism: "2.0.0", .nimbus: "2.0.0",
        ]
        for archetype in Archetype.allCases {
            let profile = try PersonalityProfile.load(archetype, bundle: .main)
            XCTAssertEqual(profile.id, archetype.rawValue)
            XCTAssertEqual(profile.assetVersion, expectedVersions[archetype])
        }
    }

    /// Schema v2 (A5a): every profile carries the species token stack and a
    /// consistent v3 grammar (one tell, one quirk loop, one gaze policy per
    /// temperament — the distinctness discipline of §6 v2).
    func testSpeciesSchemaV2FieldsPresentAndDistinct() throws {
        var tells: Set<String> = []
        var quirks: Set<String> = []
        var policies: Set<String> = []
        var expectedTell: [Archetype: PersonalityTell] = [
            .ember: .spark, .willow: .leaf, .compass: .tick,
            .prism: .flicker, .nimbus: .pulse,
        ]
        var expectedQuirk: [Archetype: QuirkLoop] = [
            .ember: .preen, .willow: .phototropism, .compass: .alignmentFidget,
            .prism: .mirrorMoment, .nimbus: .weatherMap,
        ]
        var expectedPolicy: [Archetype: GazePolicy] = [
            .ember: .lock, .willow: .soft, .compass: .metricSweep,
            .prism: .wander, .nimbus: .detectThenSettle,
        ]
        for archetype in Archetype.allCases {
            let profile = try PersonalityProfile.load(archetype, bundle: .main)
            let species = try XCTUnwrap(profile.speciesTokens, "\(archetype.rawValue): speciesTokens required at assetVersion 2")
            XCTAssertFalse(species.bodyLight.isEmpty)
            XCTAssertEqual(profile.tell, expectedTell[archetype])
            XCTAssertEqual(profile.quirkLoop, expectedQuirk[archetype])
            XCTAssertEqual(profile.gazePolicy, expectedPolicy[archetype])
            XCTAssertNotNil(profile.motionGrammar, "\(archetype.rawValue): motionGrammar required")
            XCTAssertNotNil(profile.blink, "\(archetype.rawValue): blink grammar required")
            XCTAssertNotNil(profile.voiceStyle, "\(archetype.rawValue): voiceStyle required")
            tells.insert(profile.tell?.rawValue ?? "")
            quirks.insert(profile.quirkLoop?.rawValue ?? "")
            policies.insert(profile.gazePolicy?.rawValue ?? "")
        }
        XCTAssertEqual(tells.count, Archetype.allCases.count, "each archetype must own a unique tell")
        XCTAssertEqual(quirks.count, Archetype.allCases.count, "each archetype must own a unique quirk loop")
        XCTAssertEqual(policies.count, Archetype.allCases.count, "each archetype must own a unique gaze policy")
    }

    /// §10 parity: every gesture clip must exist for every archetype
    /// (weight 0 allowed) so archetypes cannot drift apart.
    func testGesturePoolParityAcrossArchetypes() throws {
        let allClips = Set(GestureClip.allCases.map { "\($0)" })
        for archetype in Archetype.allCases {
            let profile = try PersonalityProfile.load(archetype, bundle: .main)
            let keys = Set(profile.gesturePoolWeights.keys)
            XCTAssertEqual(keys, allClips, "profile \(archetype.rawValue) must list all 12 clips")
            for weight in profile.gesturePoolWeights.values {
                XCTAssertGreaterThanOrEqual(weight, 0)
            }
            let sum = profile.gesturePoolWeights.values.reduce(0, +)
            XCTAssertEqual(sum, 1.0, accuracy: 0.02, "profile \(archetype.rawValue) weights must sum to 1")
        }
    }

    func testProfilesAreWellFormed() throws {
        for archetype in Archetype.allCases {
            let profile = try PersonalityProfile.load(archetype, bundle: .main)
            XCTAssertGreaterThan(profile.motionProfile.gestureRatePerMin, 0)
            XCTAssertGreaterThan(profile.motionProfile.amplitudeScale, 0)
            XCTAssertGreaterThan(profile.motionProfile.tempoScale, 0)
            XCTAssertEqual(profile.motionProfile.transitionDurationSec.count, 2)
            XCTAssertLessThanOrEqual(
                profile.motionProfile.transitionDurationSec[0],
                profile.motionProfile.transitionDurationSec[1]
            )
            XCTAssertGreaterThan(profile.gazeProfile.blinkRatePerMin, 0)
            XCTAssertGreaterThan(profile.gazeProfile.saccadeRatePerMin, 0)
            XCTAssertGreaterThanOrEqual(profile.visualTokens.palette.count, 3)
            XCTAssertGreaterThan(profile.visualTokens.silhouetteWeights.roundness, 0)
        }
    }

    /// §5 anchor traits: each archetype peaks on its own Big Five dimension.
    func testArchetypeAnchorTraits() throws {
        func profile(_ a: Archetype) throws -> PersonalityProfile { try PersonalityProfile.load(a, bundle: .main) }

        let ember = try profile(.ember)
        XCTAssertGreaterThan(ember.traitVector.extraversion, ember.traitVector.agreeableness)

        let willow = try profile(.willow)
        XCTAssertGreaterThan(willow.traitVector.agreeableness, willow.traitVector.extraversion)

        let compass = try profile(.compass)
        XCTAssertGreaterThan(compass.traitVector.conscientiousness, compass.traitVector.extraversion)

        let prism = try profile(.prism)
        XCTAssertGreaterThan(prism.traitVector.openness, prism.traitVector.conscientiousness)

        let nimbus = try profile(.nimbus)
        XCTAssertGreaterThan(nimbus.traitVector.neuroticism, nimbus.traitVector.extraversion)
    }

    /// Per-archetype budget (§11): each profile JSON stays far under 1.5 MB
    /// and the full bundle under 8 MB.
    func testAssetSizeBudget() throws {
        let main = Bundle.main
        var total: Int = 0
        for archetype in Archetype.allCases {
            guard let url = main.url(forResource: "profile_\(archetype.rawValue)", withExtension: "json") else {
                XCTFail("profile_\(archetype.rawValue).json missing from bundle")
                continue
            }
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            XCTAssertLessThan(size, 1_500_000, "per-archetype assets must be <= 1.5 MB")
            total += size
        }
        guard let rigURL = main.url(forResource: "rig", withExtension: "json") else {
            XCTFail("rig.json missing from bundle")
            return
        }
        total += (try FileManager.default.attributesOfItem(atPath: rigURL.path)[.size] as? Int ?? 0)
        XCTAssertLessThan(total, 8_000_000, "avatar bundle must be <= 8 MB")
    }

    /// ArchetypeVisualSet resolves palette tokens from the profile.
    func testVisualSetResolvesPalette() throws {
        let profile = try PersonalityProfile.load(.ember, bundle: .main)
        let visual = ArchetypeVisualSet(profile: profile)
        XCTAssertEqual(visual.archetype, .ember)
        XCTAssertEqual(visual.primaryHex, "#FF8A3D")
        XCTAssertEqual(visual.dominantShape, "circle")
        XCTAssertEqual(visual.accentShape, "triangle")
    }
}
