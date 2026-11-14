import XCTest
import CoreGraphics
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

    /// v42: every non-idle act is a real ENVELOPE (non-identity at some age
    /// 1...6), and the ambient layer is non-static but bounded — continuous
    /// life, never a snap or a runaway.
    func testImageBackedActEnvelopesCoverEveryFrame() {
        let frameIDs = ["blink", "sleepy", "happy", "glanceL", "glanceR",
                        "quirk", "perk", "breathe", "idleA", "idleB", "yawn"]
        for id in frameIDs {
            let moving = (1...6).contains { age in PetMotion.act(id, age) != .identity }
            XCTAssertTrue(moving, "\(id): act envelope must move at some age")
        }
        // Ambient: bounded amplitude, non-zero (the animal is never a still).
        for seed: UInt64 in [1, 20261010, 999] {
            var maxRot = 0.0, maxDx = 0.0, maxWag = 0.0
            var anyMotion = false
            for tick in 0..<500 {
                let p = PetMotion.ambient(tick, seed: seed)
                maxRot = max(maxRot, abs(p.rotation))
                maxDx = max(maxDx, abs(p.dx))
                maxWag = max(maxWag, abs(p.tailWag))
                if p != .identity { anyMotion = true }
            }
            XCTAssertTrue(anyMotion, "ambient must move")
            XCTAssertLessThan(maxRot, 0.05, "sway stays subtle")
            XCTAssertLessThan(maxDx, 0.5, "drift stays on the tile")
            XCTAssertLessThan(maxWag, 0.25, "wag stays subtle")
        }
        // Determinism: same (frameID, age, tick, seed) -> same pose.
        XCTAssertEqual(PetMotion.pose(frameID: "quirk", frameAge: 3, tick: 120, seed: 42),
                       PetMotion.pose(frameID: "quirk", frameAge: 3, tick: 120, seed: 42))
        // Non-repeating: the FULL ambient pose takes many distinct values over
        // an hour of ticks. (Each layer has an integer period, but the periods
        // are coprime, so the combined pose's period is ~1.2e9 ticks — no
        // visible loop.)
        func hash(_ p: PetMotion.Pose) -> Int {
            var h = 0
            for v in [p.dx, p.dy, p.scaleX, p.scaleY, p.rotation, p.headTilt, p.headBob, p.tailWag] {
                h = h &* 31 &+ Int(v * 1_000_000)
            }
            return h
        }
        let poses = Set((0..<24000).map { hash(PetMotion.ambient($0, seed: 7)) })
        XCTAssertGreaterThan(poses.count, 1000, "ambient motion must not loop visibly")
    }

    /// v42: the five HD pets carry puppet regions (head + tail) inside the
    /// image bounds; the grid-authored lumen has none.
    func testPuppetRegionsAreWiredPerPet() throws {
        for archetype in Archetype.allCases {
            let sprite = AuthoredSprites.sprite(for: archetype)
            if sprite.isImageBacked {
                for region in [sprite.puppetHead, sprite.puppetTail] {
                    let r = try XCTUnwrap(region, "\(archetype.rawValue): puppet region missing")
                    XCTAssertTrue(r.rect.minX >= 0 && r.rect.maxX <= 1 && r.rect.minY >= 0 && r.rect.maxY <= 1,
                                  "\(archetype.rawValue): region rect inside the image")
                    XCTAssertTrue(r.anchor.x >= 0 && r.anchor.x <= 1 && r.anchor.y >= 0 && r.anchor.y <= 1,
                                  "\(archetype.rawValue): anchor inside the image")
                }
            } else {
                XCTAssertNil(sprite.puppetHead)
                XCTAssertNil(sprite.puppetTail)
            }
        }
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
                    let moving = (1...6).contains { age in PetMotion.act(id, age) != .identity }
                    XCTAssertTrue(moving, "\(archetype.rawValue) \(id): no-op act envelope")
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
