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

    func testEmberIdleAKeepsWhiteTailTip() {
        let base = grid(.ember, "idle")
        let idleA = grid(.ember, "idleA")
        XCTAssertEqual(base[9][16], "W", "tip in base")
        XCTAssertEqual(idleA[9][16], ".", "old cell cleared")
        XCTAssertEqual(idleA[9][19], "W", "v24: the tip rides the wag to x=19")
    }

    func testEventIconDiffersForAllArchetypes() {
        for archetype in Archetype.allCases {
            let awake = CompanionIcon.snapshotBytes(for: archetype, state: .awake)
            let event = CompanionIcon.snapshotBytes(for: archetype, state: .event)
            XCTAssertNotEqual(awake, event, "\(archetype.rawValue): event visible on every animal now")
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
