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

    /// v1.1 §5.12.2: each species' ONE unmistakable tell, exaggerated past
    /// comfort and pinned (the black-silhouette quiz at 48 px lives in
    /// StageZoneTests; these are the spec-level pins behind it).
    func testSpeciesTellsAreExaggerated() {
        let ember = CompanionToys.spec(for: .ember)
        XCTAssertGreaterThanOrEqual(ember.earHeight, 240, "fox ears are large and tall")
        XCTAssertEqual(ember.tailKind, .brush, "the huge white-tipped brush is the fox tell")

        let willow = CompanionToys.spec(for: .willow)
        XCTAssertLessThanOrEqual(willow.earWidth, 120, "shiba ears are narrow triangles, not bunny ovals")
        XCTAssertGreaterThanOrEqual(willow.earHeight, 150)
        XCTAssertTrue(willow.ruff, "the cheek ruff is the shiba tell")

        let compass = CompanionToys.spec(for: .compass)
        XCTAssertGreaterThanOrEqual(compass.earWidth, 210, "corgi airplane ears are WIDE")
        XCTAssertGreaterThanOrEqual(compass.earSplay, 0.55, "...and flare outward, not up (not rabbit)")
        XCTAssertGreaterThanOrEqual(compass.bodyWidth, 640, "the loaf body is wider than tall")
        XCTAssertLessThanOrEqual(compass.bodyHeight, 250)
        XCTAssertEqual(compass.tailKind, .nub)

        let prism = CompanionToys.spec(for: .prism)
        XCTAssertGreaterThan(prism.earWidth, prism.earHeight,
            "sphynx ears are WIDER than tall — the anti-rabbit rule (tall parallel crown ears read bunny)")
        XCTAssertGreaterThanOrEqual(prism.earSplay, 0.6, "...splayed well outward (>= 30 deg)")
        XCTAssertGreaterThanOrEqual(prism.earSetX, 0.38, "...set on the SIDES of the crown")
        XCTAssertGreaterThan(prism.earSetY, -0.35, "...not on the crown top")
        XCTAssertTrue(prism.wrinkleRows)

        let nimbus = CompanionToys.spec(for: .nimbus)
        XCTAssertTrue(nimbus.crest, "the mockingbird wears a tiny crest")
        XCTAssertTrue(nimbus.beak)
        XCTAssertEqual(nimbus.wingKind, .oneSwept, "one swept wing, asymmetric")

        XCTAssertFalse(CompanionToys.spec(for: .compass).crest)
        XCTAssertTrue(CompanionToys.spec(for: .lumen).antennae)
    }

    /// v1.3 §5.14A.1: every companion wears a muzzle mass (species read comes
    /// from muzzle + ear set, not ear size) plus its secondary marks.
    func testEveryCompanionHasAMuzzleAndSpeciesMarks() {
        let muzzles: [Archetype: ToySpec.MuzzleKind] = [
            .ember: .fox, .willow: .shiba, .compass: .corgi,
            .prism: .cat, .nimbus: .beak, .lumen: .none,
        ]
        for archetype in Archetype.allCases {
            XCTAssertEqual(CompanionToys.spec(for: archetype).muzzleKind, muzzles[archetype]!,
                "\(archetype.rawValue) muzzle kind")
        }
        let compass = CompanionToys.spec(for: .compass)
        XCTAssertTrue(compass.blaze, "the corgi's white blaze between the eyes")
        XCTAssertTrue(compass.browStop, "the corgi's brow stop")
        XCTAssertTrue(CompanionToys.spec(for: .prism).whiskerDots, "the cat's whisker dots")
        // No companion is ear-first to the point of rabbit: no mammal's ears
        // are both taller than 300 AND narrower than 200.
        for a in [Archetype.ember, .willow, .compass, .prism] {
            let s = CompanionToys.spec(for: a)
            XCTAssertFalse(s.earHeight > 300 && s.earWidth < 200,
                "\(a.rawValue): tall narrow parallel ears = the rabbit tell")
        }
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
