import XCTest
@testable import Aivatar_Watch_App

/// v30 setup-theme pins: the chrome accent IS the sprite's body token (one
/// hue for icon + disc + ring + button), and every accent keeps a
/// WCAG-AA-contrastable button ink (black 0.87 or white) — the v27 engine
/// palette put compass at 4.36:1 with black ink, a fail.
final class SetupThemeTests: XCTestCase {

    func testAccentHexIsTheFamilyAccentToken() {
        // v3: the chrome accent is the toy family's ui accent — one hue for
        // the puppet art and every chrome surface (picker, disc, buttons).
        let pinned: [Archetype: String] = [
            .ember: "FF7A45", .willow: "F0B060", .compass: "FFA02E",
            .prism: "D89B85", .nimbus: "9AA3AE", .lumen: "A78BFA",
        ]
        for archetype in Archetype.allCases {
            XCTAssertEqual(SetupTheme.accentHex(for: archetype),
                           CompanionToys.spec(for: archetype).uiAccentHex,
                           "\(archetype.rawValue): chrome accent must equal the family accent")
            XCTAssertEqual(SetupTheme.accentHex(for: archetype), pinned[archetype],
                           "\(archetype.rawValue): doc §5.3 palette pin")
        }
    }

    func testButtonInkContrastPerArchetype() {
        for archetype in Archetype.allCases {
            let hex = SetupTheme.accentHex(for: archetype)
            // Whatever the style picks, the chosen ink must clear 4.5:1.
            let black = SetupTheme.contrastRatio(hex, "000000")
            let white = SetupTheme.contrastRatio(hex, "FFFFFF")
            let chosen = black >= 4.5 ? black : white
            XCTAssertGreaterThanOrEqual(chosen, 4.5,
                                        "\(archetype.rawValue) #\(hex): button ink contrast")
        }
        // The destructive stop button (system red) keeps black ink too.
        XCTAssertGreaterThanOrEqual(SetupTheme.contrastRatio("FF3B30", "000000"), 4.5)
    }

    func testButtonForegroundPrefersBlackWhenItPasses() {
        // All five body tokens pass with black at 87% — the white fallback is
        // a safety net, so pin the preferred branch.
        for archetype in Archetype.allCases {
            XCTAssertGreaterThanOrEqual(SetupTheme.contrastRatio(SetupTheme.accentHex(for: archetype), "000000"),
                                        4.5, "\(archetype.rawValue) should use the black ink")
        }
    }

    func testAnimalIdentityIsLocalizedAndNonEmpty() {
        // v30: CompanionAnimal resolves through LocalizedAnimalCopy — every
        // archetype ships name/element/temperament in the base bundle.
        for archetype in Archetype.allCases {
            XCTAssertFalse(archetype.animal.name.isEmpty)
            XCTAssertFalse(archetype.animal.element.isEmpty)
            XCTAssertFalse(archetype.animal.temperament.isEmpty)
            XCTAssertEqual(archetype.animalName, archetype.animal.name.lowercased())
            XCTAssertTrue(archetype.fullName.contains(archetype.displayName))
        }
        // v31: locale-proof — compare against the same tables, not en literals.
        XCTAssertEqual(Archetype.ember.animal.name,
                       NSLocalizedString("animal.ember.name", comment: "animal species name"))
        XCTAssertEqual(Archetype.ember.fullName,
                       String(format: NSLocalizedString("identity.full", comment: "full identity"),
                              "Ember", Archetype.ember.animalName))
    }
}
