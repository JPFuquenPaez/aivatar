import XCTest
@testable import Aivatar_Watch_App

/// v24 sprite-craft fixes (from the visual audit): gaze patches must slide
/// the eyes cleanly (clearing vacated cells), the fox keeps its white tail
/// tip on idleA, the event icon differs for ALL animals, and the hue-shift
/// cap is enforced in code (<= 20 deg, Prism only).
final class SpriteFixTests: XCTestCase {

    private func grid(_ archetype: Archetype, _ frameID: String) -> [[Character]] {
        AuthoredSprites.sprite(for: archetype).symbols(frameID: frameID)
    }

    // MARK: - v40 HD pets

    /// The five companions are image-backed (avatars/ sheet cuts): they own
    /// an asset name, a vivid UI accent override, no cell patches, and a
    /// non-identity transform for every non-idle frame (motion is a pure
    /// function of the frameID — the director clock stays the only input).
    func testImageBackedSpritesAreWired() {
        let expectedAssets: [Archetype: String] = [
            .ember: "pet-fox", .willow: "pet-shiba", .compass: "pet-corgi",
            .prism: "pet-sphynx", .nimbus: "pet-mockingbird",
        ]
        for (archetype, asset) in expectedAssets {
            let sprite = AuthoredSprites.sprite(for: archetype)
            XCTAssertTrue(sprite.isImageBacked, "\(archetype.rawValue): image-backed")
            XCTAssertEqual(sprite.imageAssetName, asset)
            XCTAssertNotNil(sprite.accentHexOverride, "\(archetype.rawValue): vivid accent override")
            XCTAssertEqual(sprite.uiAccentHex, sprite.accentHexOverride)
            XCTAssertTrue(sprite.patches.isEmpty, "\(archetype.rawValue): no cell patches on HD art")
        }
        XCTAssertFalse(AuthoredSprites.sprite(for: .lumen).isImageBacked, "lumen stays an authored grid")
    }

    func testImageBackedTransformsCoverEveryFrame() {
        let frameIDs = ["blink", "sleepy", "happy", "glanceL", "glanceR",
                        "quirk", "perk", "breathe", "idleA", "idleB", "yawn"]
        for archetype in Archetype.allCases {
            guard AuthoredSprites.sprite(for: archetype).isImageBacked else { continue }
            XCTAssertEqual(CompanionSprite.frameTransform("idle"), .identity,
                           "\(archetype.rawValue): idle is the rest pose")
            for id in frameIDs {
                XCTAssertNotEqual(CompanionSprite.frameTransform(id), .identity,
                                  "\(archetype.rawValue) \(id): transform must be a real pose")
            }
        }
        // The mapping itself is pinned (pure, seed-free — determinism by construction).
        XCTAssertEqual(CompanionSprite.frameTransform("breathe"),
                       CompanionSprite.FrameTransform(dy: 0.5, scaleX: 1.015, scaleY: 1.045))
        XCTAssertEqual(CompanionSprite.frameTransform("quirk"),
                       CompanionSprite.FrameTransform(dy: 1.1, scaleX: 1.03, scaleY: 1.05, rotation: 0.04))
        XCTAssertEqual(CompanionSprite.frameTransform("glanceL").dx, -0.7)
        XCTAssertEqual(CompanionSprite.frameTransform("glanceR").dx, 0.7)
        XCTAssertEqual(CompanionSprite.frameTransform("blink").scaleY, 0.90)
    }

    /// v31 rule carried to v40: a frame that renders as plain idle is an
    /// invisible act. Image-backed sprites satisfy it via the transform
    /// (covered above); authored grids via a real cell diff.
    func testEveryNonIdleFrameDiffersFromBase() {
        let frameIDs = ["blink", "sleepy", "happy", "glanceL", "glanceR",
                        "quirk", "perk", "breathe", "idleA", "idleB", "yawn"]
        for archetype in Archetype.allCases {
            let sprite = AuthoredSprites.sprite(for: archetype)
            let base = sprite.symbols(frameID: "idle")
            for id in frameIDs {
                if sprite.isImageBacked {
                    XCTAssertNotEqual(CompanionSprite.frameTransform(id), .identity,
                                      "\(archetype.rawValue) \(id): no-op frame")
                    continue
                }
                let frame = sprite.symbols(frameID: id)
                var diffs = 0
                for y in 0..<CompanionSprite.gridHeight {
                    for x in 0..<CompanionSprite.gridWidth where frame[y][x] != base[y][x] {
                        diffs += 1
                    }
                }
                XCTAssertGreaterThanOrEqual(diffs, 1,
                    "\(archetype.rawValue) \(id): patch is a zero-diff no-op against the base grid")
            }
        }
    }

    func testEventIconDiffersForAllArchetypes() {
        for archetype in Archetype.allCases {
            let awake = CompanionIcon.snapshotBytes(for: archetype, state: .awake)
            let event = CompanionIcon.snapshotBytes(for: archetype, state: .event)
            XCTAssertNotEqual(awake, event, "\(archetype.rawValue): event visible on every animal now")
            // v29: legibility floor — the event flash must change at least 8
            // art cells (>= 72 device px at cellScale 3), not a speck. Each
            // cell is uniform, so sampling its first pixel is enough.
            let cellBytes = CompanionIcon.cellScale * CompanionIcon.cellScale * 4
            var changedCells = 0
            for i in stride(from: 0, to: min(awake.count, event.count), by: cellBytes) {
                if awake[i] != event[i] || awake[i + 1] != event[i + 1] || awake[i + 2] != event[i + 2] {
                    changedCells += 1
                }
            }
            XCTAssertGreaterThanOrEqual(changedCells, 8,
                "\(archetype.rawValue): event icon changes >= 8 cells (got \(changedCells))")
        }
    }

    func testHueShiftClampedInCode() throws {
        // Synthetic profile with an out-of-budget dial: clamp at +-20 for
        // Prism, zero for everyone else.
        let base = try PersonalityProfile.load(.prism)
        let data = try JSONEncoder().encode(base)
        var dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var dials = try XCTUnwrap(dict["weatherDials"] as? [String: Any])
        var classes = try XCTUnwrap(dials["classes"] as? [String: Any])
        classes["hot"] = ["tempoScale": 1.0, "amplitudeScale": 1.0, "accentBias": 0.0, "hueShiftDeg": 99.0]
        dials["classes"] = classes
        dict["weatherDials"] = dials
        let hotData = try JSONSerialization.data(withJSONObject: dict)
        let hotProfile = try JSONDecoder().decode(PersonalityProfile.self, from: hotData)

        let prism = SpriteDirector(profile: hotProfile, seed: 1)
        prism.setCondition(.hot)
        XCTAssertEqual(prism.weatherHueShiftDeg, 20, "clamped at +20 even with a 99-deg dial")

        var emberDict = try XCTUnwrap(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(try PersonalityProfile.load(.ember))) as? [String: Any])
        var eDials = try XCTUnwrap(emberDict["weatherDials"] as? [String: Any])
        var eClasses = try XCTUnwrap(eDials["classes"] as? [String: Any])
        eClasses["hot"] = ["tempoScale": 1.0, "amplitudeScale": 1.0, "accentBias": 0.0, "hueShiftDeg": 99.0]
        eDials["classes"] = eClasses
        emberDict["weatherDials"] = eDials
        let emberProfile = try JSONDecoder().decode(PersonalityProfile.self, from: try JSONSerialization.data(withJSONObject: emberDict))
        let ember = SpriteDirector(profile: emberProfile, seed: 1)
        ember.setCondition(.hot)
        XCTAssertEqual(ember.weatherHueShiftDeg, 0, "non-Prism never rotates, whatever the data says")
    }

    func testPatchBudgetStillHolds() {
        for archetype in Archetype.allCases {
            for (frameID, patch) in AuthoredSprites.sprite(for: archetype).patches {
                XCTAssertLessThan(patch.count, 13, "\(archetype.rawValue)/\(frameID)")
            }
        }
    }
}
