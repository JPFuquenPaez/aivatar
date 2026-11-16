import XCTest
@testable import Aivatar_Watch_App

/// v3 CompanionToyTests: the five companions + lumen are TOY SPECS — the
/// doc §5.3 palettes, the baby-schema ratios (cuteness as an engineering
/// target: eye >= 0.30 of head width, chibi head diameter), the identity
/// shapes (one exaggerated part per animal, pairwise distinct), and the P3
/// keep mechanics (growth scale + the accessory ladder).
final class CompanionToyTests: XCTestCase {

    /// Doc §5.3 exact family palettes — the authored brand colors.
    func testFamilyPalettesMatchDocSpecs() {
        let pins: [Archetype: (body: String, belly: String, shade: String,
                               ink: String, accent: String, ui: String)] = [
            .ember:  ("FF7A45", "FFE8D1", "E8601F", "4A2C1E", "76C893", "FF7A45"),
            .willow: ("FFF3DC", "FFFDF2", "F0B060", "5C3A28", "FFB7C5", "F0B060"),
            .compass:("FFFDF7", "FFFDF7", "FFA02E", "8A8578", "4FC1C0", "FFA02E"),
            .prism:  ("FFC9A8", "FFE8DC", "D89B85", "3E2A33", "8FE3C8", "D89B85"),
            .nimbus: ("F2F2F0", "FCFCFB", "9AA3AE", "2E3138", "FFD166", "9AA3AE"),
            .lumen:  ("A78BFA", "F5F4EF", "6D5BD0", "171226", "FFE9A8", "A78BFA"),
        ]
        for archetype in Archetype.allCases {
            let spec = CompanionToys.spec(for: archetype)
            let p = pins[archetype]!
            XCTAssertEqual(spec.bodyHex, p.body, "\(archetype.rawValue) body")
            XCTAssertEqual(spec.bellyHex, p.belly, "\(archetype.rawValue) belly")
            XCTAssertEqual(spec.shadeHex, p.shade, "\(archetype.rawValue) shade")
            XCTAssertEqual(spec.inkHex, p.ink, "\(archetype.rawValue) ink")
            XCTAssertEqual(spec.accentHex, p.accent, "\(archetype.rawValue) art accent")
            XCTAssertEqual(spec.uiAccentHex, p.ui, "\(archetype.rawValue) chrome accent")
            // The chrome accent is one of the family's own hues — never a
            // foreign tone (one identity everywhere).
            XCTAssertTrue([spec.bodyHex, spec.shadeHex, spec.accentHex].contains(spec.uiAccentHex),
                          "\(archetype.rawValue): chrome accent is a family hue")
        }
    }

    /// Baby schema (doc §5.2): eye width >= 30% of head width on every
    /// companion; heads stay chibi (480...540 of the 1000 grid).
    func testBabySchemaRatios() {
        for archetype in Archetype.allCases {
            let spec = CompanionToys.spec(for: archetype)
            XCTAssertGreaterThanOrEqual(spec.eyeRatio, 0.30,
                "\(archetype.rawValue): infantile eye ratio (the caretaking trigger)")
            XCTAssertLessThanOrEqual(spec.eyeRatio, 0.35,
                "\(archetype.rawValue): eyes never pass uncanny (35% cap)")
            XCTAssertGreaterThanOrEqual(spec.headDiameter, 470)
            XCTAssertLessThanOrEqual(spec.headDiameter, 540,
                "\(archetype.rawValue): chibi head")
        }
    }

    /// One exaggerated identity shape per animal (the silhouette test):
    /// warm-blooded companions carry ears, the bird and the moth do not;
    /// every identity combo is pairwise distinct.
    func testIdentityShapesAreDistinct() {
        var combos: Set<String> = []
        for archetype in Archetype.allCases {
            let spec = CompanionToys.spec(for: archetype)
            switch archetype {
            case .ember, .willow, .compass, .prism:
                XCTAssertGreaterThan(spec.earHeight, 120, "\(archetype.rawValue): the ears are the silhouette")
            case .nimbus, .lumen:
                XCTAssertEqual(spec.earHeight, 0, "\(archetype.rawValue): no external ears")
                XCTAssertTrue(spec.beak || spec.antennae, "\(archetype.rawValue): beak/antennae instead")
            }
            let combo = "\(spec.tailKind)|\(spec.wingKind)"
            XCTAssertTrue(combos.insert(combo).inserted,
                          "\(archetype.rawValue): identity shape combo \(combo) is unique")
        }
        // Spot pins: ember's brush with cream tip, willow's curl, compass's
        // nub, prism's slim, nimbus's fan, lumen none.
        XCTAssertEqual(CompanionToys.spec(for: .ember).tailKind, .brush)
        XCTAssertEqual(CompanionToys.spec(for: .willow).tailKind, .curl)
        XCTAssertEqual(CompanionToys.spec(for: .compass).tailKind, .nub)
        XCTAssertEqual(CompanionToys.spec(for: .prism).tailKind, .slim)
        XCTAssertEqual(CompanionToys.spec(for: .nimbus).tailKind, .fan)
        XCTAssertEqual(CompanionToys.spec(for: .lumen).tailKind, .none)
        XCTAssertEqual(CompanionToys.spec(for: .nimbus).wingKind, .oneSwept)
        XCTAssertEqual(CompanionToys.spec(for: .lumen).wingKind, .mothPair)
        // Family toggles: willow's ruff, compass's saddle, prism's wrinkles.
        XCTAssertTrue(CompanionToys.spec(for: .willow).ruff)
        XCTAssertTrue(CompanionToys.spec(for: .compass).saddle)
        XCTAssertTrue(CompanionToys.spec(for: .prism).wrinkleRows)
        XCTAssertTrue(CompanionToys.spec(for: .ember).muzzle)
    }

    /// The pupil is the family ink deepened toward black (glossy discs).
    func testPupilsDeepenFamilyInk() {
        for archetype in Archetype.allCases {
            let spec = CompanionToys.spec(for: archetype)
            XCTAssertNotEqual(spec.pupilHex, spec.inkHex)
            let pupil = ColorHex.rgb(spec.pupilHex)
            let ink = ColorHex.rgb(spec.inkHex)
            XCTAssertLessThan(pupil.r, ink.r, "\(archetype.rawValue): pupil darker than ink")
            XCTAssertLessThan(pupil.g, ink.g)
            XCTAssertLessThan(pupil.b, ink.b)
        }
    }

    // MARK: - P3 keep mechanics

    /// Visible growth: 1 -> 1.00 ... 5 -> 1.05 (0.0125 per level, clamped).
    func testGrowthScaleLadder() {
        XCTAssertEqual(CompanionToys.growthScale(bondLevel: 1), 1.0)
        XCTAssertEqual(CompanionToys.growthScale(bondLevel: 2), 1.0125, accuracy: 1e-9)
        XCTAssertEqual(CompanionToys.growthScale(bondLevel: 3), 1.025, accuracy: 1e-9)
        XCTAssertEqual(CompanionToys.growthScale(bondLevel: 5), 1.05, accuracy: 1e-9)
        // Clamps both ways.
        XCTAssertEqual(CompanionToys.growthScale(bondLevel: 0), 1.0)
        XCTAssertEqual(CompanionToys.growthScale(bondLevel: 99), 1.05)
        // Monotone.
        var last: CGFloat = 0
        for level in 1...5 {
            let scale = CompanionToys.growthScale(bondLevel: level)
            XCTAssertGreaterThan(scale, last, "growth is monotone")
            last = scale
        }
    }

    /// The accessory ladder: 2 bandana, 3 collar, 4 charm, 5 bell; the
    /// latest unlocked is worn; level 1 and below carry nothing.
    func testAccessoryLadder() {
        XCTAssertNil(CompanionToys.accessory(bondLevel: 1))
        XCTAssertNil(CompanionToys.accessory(bondLevel: 0))
        XCTAssertEqual(CompanionToys.accessory(bondLevel: 2), .bandana)
        XCTAssertEqual(CompanionToys.accessory(bondLevel: 3), .collar)
        XCTAssertEqual(CompanionToys.accessory(bondLevel: 4), .charm)
        XCTAssertEqual(CompanionToys.accessory(bondLevel: 5), .bell)
        XCTAssertEqual(CompanionToys.accessory(bondLevel: 6), .bell, "past max keeps the top rung")
        for accessory in PuppetAccessory.allCases {
            XCTAssertFalse(CompanionToys.accessoryName(accessory).isEmpty)
        }
    }
}
