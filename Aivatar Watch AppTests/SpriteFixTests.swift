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

    func testCompassGlanceLSlidesEyeWithoutSmear() {
        let g = grid(.compass, "glanceL")
        // Old pupil cells cleared; the eye sits at x=3-4 as W K / K K.
        XCTAssertEqual(g[5][5], "B", "old catchlight column cleared")
        XCTAssertEqual(g[6][5], "B", "old pupil cleared")
        XCTAssertEqual(g[5][3], "W")
        XCTAssertEqual(g[5][4], "K")
        XCTAssertEqual(g[6][3], "K")
        XCTAssertEqual(g[6][4], "K")
        // No third pupil column remains at x=5.
        XCTAssertFalse(g[5][5] == "K" || g[6][5] == "K")
    }

    func testNimbusGlancesMoveBothEyes() {
        let left = grid(.nimbus, "glanceL")
        // Both eyes shifted one cell left; nothing left behind at x=7/13.
        XCTAssertEqual(left[5][7], "B"); XCTAssertEqual(left[6][7], "B")
        XCTAssertEqual(left[5][13], "B"); XCTAssertEqual(left[6][13], "B")
        XCTAssertEqual(left[5][5], "W"); XCTAssertEqual(left[5][6], "K")
        XCTAssertEqual(left[5][11], "W"); XCTAssertEqual(left[5][12], "K")

        let right = grid(.nimbus, "glanceR")
        // Right eye actually moved to x=13-14 (was: never moved).
        XCTAssertEqual(right[5][12], "B"); XCTAssertEqual(right[6][12], "B")
        XCTAssertEqual(right[5][13], "W"); XCTAssertEqual(right[5][14], "K")
        XCTAssertEqual(right[6][13], "K"); XCTAssertEqual(right[6][14], "K")
        // Left eye moved right too, nothing at x=6.
        XCTAssertEqual(right[5][6], "B"); XCTAssertEqual(right[6][6], "B")
        XCTAssertEqual(right[5][7], "W"); XCTAssertEqual(right[5][8], "K")
    }

    func testEmberTailTipIsLiteralAndRidesTheWag() {
        let base = grid(.ember, "idle")
        let idleA = grid(.ember, "idleA")
        let quirk = grid(.ember, "quirk")
        XCTAssertEqual(base[9][18], "W", "v28: tip sits at the tail's literal tip x=18")
        XCTAssertEqual(quirk[9][19], "W", "quirk wags right, tip rides the extreme")
        XCTAssertEqual(quirk[9][18], "B")
        XCTAssertEqual(idleA[9][17], "W", "idleA wags left, tip at x=17")
        XCTAssertEqual(idleA[9][18], "B")
        // No floating accent: every W in these frames touches the tail mass.
        for row in [base[9], idleA[9], quirk[9]] {
            for x in 0..<20 where row[x] == "W" {
                XCTAssertTrue([x - 1, x + 1].contains { row[$0] != "." }, "W at \(x) attaches to a mass")
            }
        }
    }

    func testPrismTurretSlidesAsABlockAndQuirkDiffers() {
        let r = grid(.prism, "glanceR")
        // Catchlight adjacent to pupil: W K K at x5-7, nothing severed at x4.
        XCTAssertEqual(r[5][4], "B")
        XCTAssertEqual(r[5][5], "W")
        XCTAssertEqual(r[5][6], "K")
        XCTAssertEqual(r[5][7], "K")
        let q = grid(.prism, "quirk")
        XCTAssertNotEqual(r, q, "quirk is no longer identical to glanceR")
        // blink clears the catchlight too (no floating W above the lid)
        let b = grid(.prism, "blink")
        XCTAssertEqual(b[5][4], "B")
        XCTAssertEqual(b[6][4], "B")
        // breathe stays off the coil ring (no anchor shimmer)
        let br = grid(.prism, "breathe")
        let base = grid(.prism, "idle")
        for x in 14...19 where base[7][x] == "D" || base[8][x] == "D" {
            XCTAssertEqual(br[7][x], base[7][x])
            XCTAssertEqual(br[8][x], base[8][x])
        }
    }

    func testCompassMouthNeverVanishes() {
        let base = grid(.compass, "idle")
        // v31: the mouth moved one cell off the bezel edge (x=1-2, was x=0-1).
        XCTAssertEqual(base[8][1], "K")
        XCTAssertEqual(base[8][2], "K", "v28/v31: two-cell mouth survives downsampling")
        XCTAssertEqual(base[8][0], ".", "v31: snout no longer touches the left bezel edge")
        let idleB = grid(.compass, "idleB")
        XCTAssertEqual(idleB[8][2], "K", "idleB no longer erases the mouth")
        XCTAssertEqual(idleB[8][1], "B", "v31: idleB narrows the mouth by one cell instead of erasing")
    }

    /// v31: a patch that produces zero real diffs against the base grid is an
    /// invisible act (prism's quirk was exactly this) — every non-idle frame
    /// of every animal must move at least one cell.
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

    /// v31: prism's signature quirk visibly contracts the coil (the old patch
    /// was a zero-diff no-op — it rendered as plain idle).
    func testPrismQuirkTightensTheCoil() {
        let base = grid(.prism, "idle")
        let q = grid(.prism, "quirk")
        for y in 5...7 {
            XCTAssertEqual(base[y][17], ".", "base hole at x=17 row \(y)")
            XCTAssertEqual(q[y][17], "D", "quirk fills x=17 row \(y) — the coil contracts")
        }
        // The v31 base has a 2-cell-thick coil right edge (x=18-19).
        for y in 5...7 {
            XCTAssertEqual(base[y][18], "D")
            XCTAssertEqual(base[y][19], "D")
        }
    }

    func testNimbusFeetStaySeparatedAndCrestIsOneTuft() {
        let idleB = grid(.nimbus, "idleB")
        let base = grid(.nimbus, "idle")
        // feet: two separated D masses in both frames
        func footMasses(_ row: [Character]) -> Int {
            var masses = 0
            var inMass = false
            for c in row {
                if c == "D" && !inMass { masses += 1; inMass = true }
                if c != "D" { inMass = false }
            }
            return masses
        }
        XCTAssertEqual(footMasses(Array(base[14])), 2)
        XCTAssertEqual(footMasses(Array(idleB[14])), 2, "v28: idleB steps the foot, no plank")
        let perk = grid(.nimbus, "perk")
        XCTAssertEqual(perk[1][8], "B")
        XCTAssertEqual(perk[1][9], "B")
        XCTAssertEqual(perk[1][7], base[1][7], "no detached tuft at x=7")
    }

    func testWillowYawnMouthIsACleanCavity() {
        let y = grid(.willow, "yawn")
        // smile row: K D D D D K — no orphaned ink clusters
        XCTAssertEqual(y[6][6], "K")
        XCTAssertEqual(y[6][7], "D")
        XCTAssertEqual(y[6][8], "D")
        XCTAssertEqual(y[6][9], "D")
        XCTAssertEqual(y[6][10], "D")
        XCTAssertEqual(y[6][11], "K")
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
