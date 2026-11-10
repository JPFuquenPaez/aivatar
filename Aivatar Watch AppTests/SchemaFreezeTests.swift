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
        // mirror, driftFloat) — one per archetype. A5c: +slowBlink (the
        // long-press ritual, event-only — weight 0 everywhere).
        XCTAssertEqual(GestureClip.allCases.count, 18)
        let names = GestureClip.allCases.map { "\($0)" }
        XCTAssertEqual(names, ["wave", "bounce", "stretch", "spin", "nod", "tilt", "lookAround", "shiftWeight", "shiver", "doubleTake", "sparkle", "puff", "preen", "swayCatch", "tick", "mirror", "driftFloat", "slowBlink"])
    }

    func testAllFiveProfilesLoadAndMatchArchetypes() throws {
        // §10 semantic versioning per archetype set. 2.0.0 (A5a): the v3
        // unified cloud-species — tint + token + tell stack; schema v2
        // fields (speciesTokens, motionGrammar, gazePolicy, blink, tell,
        // quirkLoop, voiceStyle) are additive and validated below.
        // v3.0.0 (v18 F3): +weatherDials (additive, optional — v2 profiles
        // still load and fall back to neutral dials).
        let expectedVersions: [Archetype: String] = [
            .ember: "3.0.0", .willow: "3.0.0", .compass: "3.0.0",
            .prism: "3.0.0", .nimbus: "3.0.0", .lumen: "3.0.0",
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
            .prism: .flicker, .nimbus: .pulse, .lumen: .dust,
        ]
        var expectedQuirk: [Archetype: QuirkLoop] = [
            .ember: .preen, .willow: .phototropism, .compass: .alignmentFidget,
            .prism: .mirrorMoment, .nimbus: .weatherMap, .lumen: .stargazing,
        ]
        var expectedPolicy: [Archetype: GazePolicy] = [
            .ember: .lock, .willow: .soft, .compass: .metricSweep,
            .prism: .wander, .nimbus: .detectThenSettle, .lumen: .linger,
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

    /// Schema v3 (v18 F3): every profile carries a weatherDials table with
    /// all seven condition classes, neutral "unknown", dials in range —
    /// and the per-archetype intent (Prism owns the hue shifts).
    func testWeatherDialsV3PresentAndParity() throws {
        for archetype in Archetype.allCases {
            let profile = try PersonalityProfile.load(archetype, bundle: .main)
            let dials = try XCTUnwrap(profile.weatherDials, "\(archetype.rawValue): weatherDials required at assetVersion 3")
            XCTAssertEqual(Set(dials.classes.keys), Set(ConditionClass.allCases.map(\.rawValue)),
                           "\(archetype.rawValue): all condition classes present")
            let unknown = try XCTUnwrap(dials.classes["unknown"])
            XCTAssertEqual(unknown, WeatherDial(), "\(archetype.rawValue): unknown is neutral")
            for (_, dial) in dials.classes {
                XCTAssertGreaterThan(dial.tempoScale, 0)
                XCTAssertGreaterThan(dial.amplitudeScale, 0)
                XCTAssertLessThanOrEqual(abs(dial.accentBias), 1)
                XCTAssertLessThanOrEqual(abs(dial.hueShiftDeg), 20, "hue shifts stay inside the LUT budget")
            }
        }
        // Prism is the hue-shift archetype; the others keep their palette.
        let prism = try XCTUnwrap(try PersonalityProfile.load(.prism, bundle: .main).weatherDials)
        XCTAssertTrue(prism.classes.values.contains { $0.hueShiftDeg != 0 })
        for archetype in Archetype.allCases where archetype != .prism {
            let dials = try XCTUnwrap(try PersonalityProfile.load(archetype, bundle: .main).weatherDials)
            XCTAssertTrue(dials.classes.values.allSatisfy { $0.hueShiftDeg == 0 },
                          "\(archetype.rawValue): only Prism rotates hue")
        }
    }

    /// G8: a v2 profile (no weatherDials key) still decodes, dials nil —
    /// the director falls back to neutral multipliers.
    func testProfileV2WithoutWeatherDialsFallsBack() throws {
        let profile = try PersonalityProfile.load(.ember, bundle: .main)
        let data = try JSONEncoder().encode(profile)
        var dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "weatherDials")
        let v2data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(PersonalityProfile.self, from: v2data)
        XCTAssertNil(decoded.weatherDials)
        XCTAssertEqual(decoded.dial(for: .rain), WeatherDial(), "nil dials = neutral")
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

    /// v16 memory schema v3 (Ambient Life F1, G8): additive fields with
    /// lenient decode — a v15 payload (no bondXP/lifeLog/ritual-day keys)
    /// still decodes, defaulted, and the v3 keys round-trip when present.
    func testCompanionMemorySchemaV3IsAdditive() throws {
        let legacy = """
        {"firstLaunch":1793620800,"lastSeen":1793620800,"sessions":3,"streakDays":2,
         "sproutDays":4.0,"rehearsalLevel":0,"trinketDay":-1,"usualHourEMA":null}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CompanionMemory.self, from: legacy)
        XCTAssertEqual(decoded.bondXP, 0)
        XCTAssertEqual(decoded.lifeLog, [])
        XCTAssertEqual(decoded.lastPresenceDay, -1)
        XCTAssertEqual(decoded.lastGreetingDay, -1)
        XCTAssertEqual(decoded.bondLevel, 1)

        var full = CompanionMemory(firstLaunch: Date(timeIntervalSince1970: 1793620800),
                                   lastSeen: Date(timeIntervalSince1970: 1793620800))
        full.bondXP = 60
        full.appendLifeLog(LifeLogEntry(kindHash: 7, dayIndex: 20_800))
        let data = try JSONEncoder().encode(full)
        XCTAssertEqual(try JSONDecoder().decode(CompanionMemory.self, from: data), full)
        XCTAssertEqual(full.bondLevel, 4)
    }

    /// v25 fault isolation: corrupt VALUES (wrong types, one bad ring entry,
    /// a future enum raw value) fall back per-field instead of wiping the
    /// whole payload.
    func testMemoryDecodesWithCorruptValuesPerField() throws {
        let corrupt = """
        {"firstLaunch":"not-a-date","lastSeen":1793620800,"sessions":"many","streakDays":2,
         "sproutDays":4.0,"rehearsalLevel":0,"trinketDay":-1,"usualHourEMA":null,
         "bondXP":"lots","lifeLog":[{"kindHash":"x","dayIndex":1},{"kindHash":7,"dayIndex":20800,"at":1793620800}],
         "lastPresenceDay":-1,"lastGreetingDay":-1,"lastBeatDay":-1}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(CompanionMemory.self, from: corrupt)
        XCTAssertEqual(m.sessions, 0, "corrupt sessions -> default")
        XCTAssertEqual(m.streakDays, 2, "intact fields survive")
        XCTAssertEqual(m.lifeLog.count, 1, "only the valid ring entry survives")
        XCTAssertEqual(m.lifeLog.first?.kindHash, 7)
    }

    func testWidgetSnapshotDecodesWithCorruptValuesPerField() throws {
        let corrupt = """
        {"archetypeRaw":"willow","name":"Willow","streakDays":3,"presence":"someFutureState","dayCount":"lots"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(CompanionWidgetSnapshot.self, from: corrupt)
        XCTAssertEqual(s.presence, .asleep, "unknown/future presence raw -> asleep")
        XCTAssertEqual(s.streakDays, 3)
        XCTAssertEqual(s.dayCount, 1, "corrupt dayCount -> default")
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
