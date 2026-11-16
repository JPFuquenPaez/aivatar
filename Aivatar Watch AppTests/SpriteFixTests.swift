import XCTest
import CoreGraphics
@testable import Aivatar_Watch_App

/// v3 sprite-craft fixes (the puppet edition): the face grammar holds on
/// every companion (glossy dark pupil + white catchlight embedded inside
/// it, at icon size — the readability floor), the icon states are visually
/// distinct (event flashes the family accent, asleep dims the scan), every
/// icon byte-render is deterministic, the moment renderer answers for all
/// six companions, and the weather hue-shift cap stays enforced in code
/// (<= 20 deg, Prism only).
final class SpriteFixTests: XCTestCase {

    private func bytes(_ archetype: Archetype, _ state: IconState) -> [UInt8] {
        CompanionIcon.snapshotBytes(for: archetype, state: state)
    }
    private var byteCount: Int { CompanionIcon.iconWidth * CompanionIcon.iconHeight * 4 }

    // MARK: - The face is the avatar (v13 rule, v3 form)

    /// The uniform eye style: every companion's icon carries glossy dark
    /// pupils with a white catchlight embedded INSIDE the pupil disc (the
    /// single most alive pixel). White pixels far from any pupil (a pale
    /// muzzle, a white head fill) do not satisfy the grammar.
    func testFaceStyleHoldsAcrossAllSix() {
        for archetype in Archetype.allCases {
            let data = bytes(archetype, .awake)
            XCTAssertEqual(data.count, byteCount)
            let w = CompanionIcon.iconWidth, h = CompanionIcon.iconHeight
            func isDark(_ x: Int, _ y: Int) -> Bool {
                let o = (y * w + x) * 4
                return data[o] < 90 && data[o + 1] < 90 && data[o + 2] < 110
            }
            func isWhite(_ x: Int, _ y: Int) -> Bool {
                let o = (y * w + x) * 4
                return data[o] >= 240 && data[o + 1] >= 240 && data[o + 2] >= 240
            }
            var pupils = 0
            var catchlights = 0
            for y in 2..<(h - 2) {
                for x in 2..<(w - 2) {
                    if isDark(x, y) {
                        pupils += 1
                        // catchlight = white touching a dark pupil cell
                        if !isWhite(x, y) && (isWhite(x + 1, y) || isWhite(x - 1, y)
                            || isWhite(x, y + 1) || isWhite(x, y - 1)
                            || isWhite(x + 2, y) || isWhite(x - 2, y)) {
                            catchlights += 1
                        }
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(pupils, 300,
                "\(archetype.rawValue): the dark pupil discs paint at icon size")
            XCTAssertGreaterThanOrEqual(catchlights, 8,
                "\(archetype.rawValue): white catchlight embedded in the pupil")
        }
    }

    // MARK: - Icon states

    func testEventIconDiffersForAllArchetypes() {
        for archetype in Archetype.allCases {
            let awake = bytes(archetype, .awake)
            let event = bytes(archetype, .event)
            XCTAssertNotEqual(awake, event, "\(archetype.rawValue): event visible on every animal")
            // Legibility floor: the event flash repaints a real area of the
            // head cut (>= 200 px), not a speck.
            var changed = 0
            for i in stride(from: 0, to: awake.count, by: 4) {
                if awake[i] != event[i] || awake[i + 1] != event[i + 1] || awake[i + 2] != event[i + 2] {
                    changed += 1
                }
            }
            XCTAssertGreaterThanOrEqual(changed, 200,
                "\(archetype.rawValue): event icon changes >= 200 px (got \(changed))")
        }
    }

    func testAsleepIconIsDimmerThanAwake() {
        for archetype in Archetype.allCases {
            let awake = bytes(archetype, .awake)
            let asleep = bytes(archetype, .asleep)
            XCTAssertNotEqual(awake, asleep, "\(archetype.rawValue): asleep differs from awake")
            func meanLum(_ d: [UInt8]) -> Double {
                var sum = 0.0
                for i in stride(from: 0, to: d.count, by: 4) {
                    sum += 0.2126 * Double(d[i]) + 0.7152 * Double(d[i + 1]) + 0.0722 * Double(d[i + 2])
                }
                return sum / Double(d.count / 4)
            }
            XCTAssertLessThan(meanLum(asleep), meanLum(awake),
                              "\(archetype.rawValue): asleep scan is the dim state")
        }
    }

    func testIconBytesAreDeterministicAcrossRuns() {
        for archetype in Archetype.allCases {
            for state in [IconState.awake, .asleep, .event] {
                XCTAssertEqual(bytes(archetype, state), bytes(archetype, state),
                               "\(archetype.rawValue)/\(state.rawValue): icon bytes bit-stable")
            }
        }
    }

    /// One identity everywhere: the moment renderer (postcard + iPhone card
    /// path) answers for every companion with a real clay scan.
    func testMomentRendererAnswersForAllCompanions() {
        for archetype in Archetype.allCases {
            let drive = PuppetDrive(archetype: archetype, frameID: "idle")
            let image = CompanionIcon.cgImage(for: drive)
            XCTAssertNotNil(image, "\(archetype.rawValue): moment render composes")
            XCTAssertEqual(image?.width, CompanionIcon.momentWidth)
            XCTAssertEqual(image?.height, CompanionIcon.momentHeight)
            XCTAssertNotNil(CompanionIcon.pngData(for: archetype), "\(archetype.rawValue): icon PNG exports")
        }
    }

    // MARK: - Weather hue shift (kept from v24/v40)

    func testHueShiftClampedInCode() throws {
        // Synthetic profile with an out-of-budget dial: clamp at +-20 for
        // Prism, zero for everyone else.
        func profileWithHotDial(_ archetype: Archetype) throws -> PersonalityProfile {
            let base = try PersonalityProfile.load(archetype)
            let data = try JSONEncoder().encode(base)
            var dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var dials = try XCTUnwrap(dict["weatherDials"] as? [String: Any])
            var classes = try XCTUnwrap(dials["classes"] as? [String: Any])
            classes["hot"] = ["tempoScale": 1.0, "amplitudeScale": 1.0, "accentBias": 0.0, "hueShiftDeg": 99.0]
            dials["classes"] = classes
            dict["weatherDials"] = dials
            return try JSONDecoder().decode(PersonalityProfile.self,
                                            from: JSONSerialization.data(withJSONObject: dict))
        }
        let prism = SpriteDirector(profile: try profileWithHotDial(.prism), seed: 1)
        prism.setCondition(.hot)
        XCTAssertEqual(prism.weatherHueShiftDeg, 20, "clamped at +20 even with a 99-deg dial")

        let ember = SpriteDirector(profile: try profileWithHotDial(.ember), seed: 1)
        ember.setCondition(.hot)
        XCTAssertEqual(ember.weatherHueShiftDeg, 0, "non-Prism never rotates, whatever the data says")
        // And the drive carries it for the tint resolver: Prism only.
        let drive = prism.puppetDrive(atTick: 1)
        XCTAssertEqual(drive.hueShiftDeg, 20)
        XCTAssertEqual(PuppetPoser.resolve(drive).pose.hashValue64(),
                       PuppetPoser.resolve(PuppetDrive(archetype: .prism, frameID: "idle")).pose.hashValue64(),
                       "hue shift is a tint, never a pose change")
    }
}
