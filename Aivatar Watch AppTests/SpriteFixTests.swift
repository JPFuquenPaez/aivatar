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

    // MARK: - AMS v2 (v43)

    /// Two skins, one animal (§5.6): the five pets carry their HD PORTRAIT
    /// asset + the family accent; lumen (grid-only) carries neither. No
    /// surface animates the portrait — the stage renders the authored grid.
    func testPortraitAssetsAreWired() {
        let expected: [Archetype: String] = [
            .ember: "pet-fox", .willow: "pet-shiba", .compass: "pet-corgi",
            .prism: "pet-sphynx", .nimbus: "pet-mockingbird",
        ]
        for (archetype, asset) in expected {
            let sprite = AuthoredSprites.sprite(for: archetype)
            XCTAssertTrue(sprite.hasPortrait, "\(archetype.rawValue): portrait wired")
            XCTAssertEqual(sprite.portraitAssetName, asset)
            XCTAssertNotNil(sprite.accentHexOverride, "\(archetype.rawValue): vivid accent override")
            XCTAssertEqual(sprite.uiAccentHex, sprite.accentHexOverride)
            XCTAssertFalse(sprite.patches.isEmpty, "\(archetype.rawValue): authored patch grammar restored")
        }
        XCTAssertFalse(AuthoredSprites.sprite(for: .lumen).hasPortrait, "lumen stays a grid-only sprite")
        XCTAssertNil(AuthoredSprites.sprite(for: .lumen).portraitAssetName)
    }

    /// The face is the avatar (§5.4): every one of the six companions owns
    /// the uniform eye style in its IDLE grid — a W catchlight with ink to
    /// its right and below-right.
    func testFaceStyleHoldsAcrossAllSix() {
        for archetype in Archetype.allCases {
            let grid = AuthoredSprites.sprite(for: archetype).symbols(frameID: "idle")
            var catchlights = 0
            for y in 0..<(CompanionSprite.gridHeight - 1) {
                for x in 0..<(CompanionSprite.gridWidth - 1) {
                    if grid[y][x] == "W" && grid[y][x + 1] == "K" && grid[y + 1][x + 1] == "K" {
                        catchlights += 1
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(catchlights, 1,
                "\(archetype.rawValue): the shared eye style (W catchlight + K pupil)")
        }
    }

    /// CellQuantizer (§5.3): the pixel-honesty gate — floor, hold, step
    /// economy, determinism.
    func testCellQuantizerRules() {
        // Rule 1 — cell floor: sub-cell proposals are deleted, not rounded.
        XCTAssertEqual(CellQuantizer.quantizedTarget(0.0), 0)
        XCTAssertEqual(CellQuantizer.quantizedTarget(0.9), 0)
        XCTAssertEqual(CellQuantizer.quantizedTarget(-0.99), 0)
        XCTAssertEqual(CellQuantizer.quantizedTarget(1.0), 1)
        XCTAssertEqual(CellQuantizer.quantizedTarget(-1.4), -1)
        // Rule 2 — hold: a new state is kept for >= 2 ticks (ambient default).
        var q = CellQuantizer()
        XCTAssertEqual(q.output, 0)
        _ = q.step(proposal: 1.4)   // first move allowed (long held)
        XCTAssertEqual(q.output, 1)
        _ = q.step(proposal: 1.4)   // still held
        XCTAssertEqual(q.output, 1)
        _ = q.step(proposal: 0)     // target 0 after only 1 hold tick -> held
        XCTAssertEqual(q.output, 1, "ambient holds >= 2 ticks")
        _ = q.step(proposal: 0)
        XCTAssertEqual(q.output, 0, "then converges to neutral")
        // Rule 3 — step economy: a reversal passes through neutral (never
        // directly +1 -> -1), gated by the same hold rule.
        var r = CellQuantizer()
        _ = r.step(proposal: 1.4)
        XCTAssertEqual(r.output, 1)
        _ = r.step(proposal: -1.4)  // economy clamps the target to 0, held
        XCTAssertEqual(r.output, 1, "hold rule still applies to reversals")
        _ = r.step(proposal: -1.4)  // held again (1 tick since the last change)
        XCTAssertEqual(r.output, 1)
        _ = r.step(proposal: -1.4)  // held expired -> settles through NEUTRAL
        XCTAssertEqual(r.output, 0, "reversal must pass through neutral")
        _ = r.step(proposal: -1.4)
        XCTAssertEqual(r.output, 0)
        _ = r.step(proposal: -1.4)
        XCTAssertEqual(r.output, 0)
        _ = r.step(proposal: -1.4)
        XCTAssertEqual(r.output, -1, "then the other pose")
        // Determinism: the same trace folds bit-identically.
        func run() -> [Int] {
            var c = CellQuantizer()
            return (0..<500).map { i in c.step(proposal: 1.4 * sin(Double(i) / 7.0)) }
        }
        XCTAssertEqual(run(), run())
    }

    /// The LPR tail part (§5.2): authored pose diffs for every pet, lumen
    /// none — sized like a cat-class patch, never a crop or a rotation.
    func testTailPosesAreAuthoredAndBounded() {
        for archetype in Archetype.allCases {
            guard let poses = SpriteStageMetadata.tailPoses(archetype) else {
                XCTAssertEqual(archetype, .lumen, "only lumen has no tail part")
                continue
            }
            for (pose, cells) in poses {
                XCTAssertFalse(cells.isEmpty, "\(archetype.rawValue): pose \(pose) authored")
                XCTAssertLessThanOrEqual(cells.count, 6,
                    "\(archetype.rawValue): pose \(pose) is cat-class small")
                for d in cells {
                    XCTAssertTrue(d.x >= 0 && d.x < CompanionSprite.gridWidth
                        && d.y >= 0 && d.y < CompanionSprite.gridHeight,
                        "\(archetype.rawValue): pose \(pose) cell in-grid")
                    XCTAssertNotEqual(d.symbol, ".", "\(archetype.rawValue): poses paint, not clear")
                }
            }
        }
    }

    /// The ambient tail channel (§5.5): wags happen, hold >= 2 ticks, and
    /// re-converge to neutral between bursts — deterministic per seed.
    func testTailChannelWagsHoldsAndReconverges() {
        var channel = TailChannel(seed: 20261103)
        var poses: [Int] = []
        var nonNeutralTicks = 0
        for _ in 0..<4000 {
            let pose = channel.step(modeAllows: true, ticksPerMinute: 400, tempoScale: 1)
            poses.append(pose)
            if pose != 0 { nonNeutralTicks += 1 }
        }
        XCTAssertGreaterThan(nonNeutralTicks, 0, "the tail wags at ambient rate")
        XCTAssertLessThan(nonNeutralTicks, 2000 * 3, "the tail is not perpetually up")
        // Holds: a non-zero pose lasts at least 2 consecutive ticks (ignoring
        // the boundary pass through neutral).
        var violations = 0
        var i = 0
        while i < poses.count {
            if poses[i] != 0 {
                var len = 0
                while i + len < poses.count, poses[i + len] == poses[i] { len += 1 }
                if len < 2 { violations += 1 }
                i += len
            } else { i += 1 }
        }
        XCTAssertEqual(violations, 0, "quantized poses hold >= 2 ticks")
        // Re-convergence: the run ENDS settled (long stretches of neutral).
        XCTAssertLessThan(poses.suffix(600).filter { $0 != 0 }.count, 100,
            "the tail returns to neutral between bursts")
        // Determinism per seed.
        func run(_ seed: UInt64) -> [Int] {
            var c = TailChannel(seed: seed)
            return (0..<1000).map { _ in c.step(modeAllows: true, ticksPerMinute: 400, tempoScale: 1) }
        }
        XCTAssertEqual(run(7), run(7))
        XCTAssertNotEqual(run(7), run(8))
        // Suppression settles to neutral immediately.
        var halted = TailChannel(seed: 20261103)
        _ = halted.step(modeAllows: false, ticksPerMinute: 400, tempoScale: 1)
        XCTAssertEqual(halted.pose, 0, "mode gates freeze the tail neutral")
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
