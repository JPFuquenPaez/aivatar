import XCTest
@testable import Aivatar_Watch_App

/// v27 localization tests: every key the setup surfaces use must resolve in
/// the base (English) bundle, the French localization must ship, and
/// %-placeholders must survive interpolation.
final class LocalizationTests: XCTestCase {

    private let keys = [
        "beat.noticed_day", "beat.celebrated_run", "beat.slept_beside", "beat.ran_with",
        "beat.finished_lap", "beat.glows_sun", "beat.cozy", "beat.loves_rain", "beat.rides_wind",
        "beat.keeps_warm", "beat.seeks_shade", "beat.rehearsed", "beat.watered",
        "beat.finished_audit", "beat.found_trinket", "beat.saw_coming",
        "hint.slow_blink", "hint.pages",
        "workout.run_with", "workout.running_with", "workout.end_run", "workout.sub",
        "workout.elapsed", "workout.start",
        "postcard.day", "postcard.old_friends", "postcard.weather_day",
        "postcard.nav", "postcard.preview",
        "presence.napping", "presence.awake", "presence.noticed_day",
        "presence.celebrated_workout", "presence.slept_beside", "presence.checked_sky",
        "presence.ran_with", "presence.lap_done", "presence.noticed_something",
        "inline.line", "rect.line", "about.day",
        "picker.choose", "picker.current", "picker.nav",
        "naming.nav", "naming.title", "naming.subtitle", "naming.placeholder",
        "naming.preview", "naming.field", "naming.clear", "naming.commit",
        "naming.commit_hint", "naming.cancel",
        "settings.nav", "settings.companion", "settings.name", "settings.animal",
        "settings.accessibility", "settings.reduce_motion", "settings.reduce_motion_footer", "settings.sounds",
        "settings.sounds_header", "settings.sounds_footer", "settings.calendar",
        "settings.health", "settings.weather", "settings.life_sense",
        "settings.life_sense_footer", "settings.about", "settings.postcard",
        "settings.about_copy", "settings.tip",
        // v30: animal identity, weather class names, a11y labels, stage
        // VoiceOver, bond announcement, workout hints.
        "animal.ember.name", "animal.ember.element", "animal.ember.temperament",
        "animal.willow.name", "animal.willow.element", "animal.willow.temperament",
        "animal.compass.name", "animal.compass.element", "animal.compass.temperament",
        "animal.prism.name", "animal.prism.element", "animal.prism.temperament",
        "animal.nimbus.name", "animal.nimbus.element", "animal.nimbus.temperament",
        "animal.lumen.name", "animal.lumen.element", "animal.lumen.temperament",
        "identity.full",
        "weather.sunny", "weather.gray", "weather.rain", "weather.wind",
        "weather.cold", "weather.hot", "weather.unknown",
        "a11y.identity_card", "a11y.name_row", "a11y.animal_row",
        "a11y.reduce_motion", "a11y.reduce_motion_hint", "a11y.sounds_hint",
        "a11y.calendar_hint", "a11y.health_hint", "a11y.weather_hint",
        "a11y.postcard_hint", "a11y.picker_selected", "a11y.picker_button_selected",
        "a11y.action_quirk", "a11y.action_slow_blink",
        "stage.hint", "stage.kind", "stage.state_resting", "stage.state_listening",
        "stage.state_calm", "stage.tag_here", "stage.tag_resting",
        "bond.announce", "workout.start_hint", "workout.end_hint", "workout.error",
        // Aivatar 2.0 (E3/E4/E5/E8/E10).
        "beat.namingday.title", "beat.namingday.caption",
        "beat.sixth.title", "beat.sixth.caption",
        "ceremony.level5.caption",
        "sit.entry.title", "sit.entry.hint", "sit.session.hint",
        "sit.session.breatheIn", "sit.session.breatheOut", "sit.session.done",
        "sit.privacy.footer",
    ]

    func testEveryKeyResolvesInBaseBundle() {
        for key in keys {
            let value = String(localized: String.LocalizationValue(key))
            XCTAssertNotEqual(value, key, "missing base (en) value for \(key)")
            XCTAssertFalse(value.isEmpty, "\(key) is empty")
        }
    }

    func testFrenchShipsAndDiffers() throws {
        XCTAssertTrue(Bundle.main.localizations.contains("fr"), "fr.lproj must be bundled")
        // Read the compiled fr table directly (the test host does not route
        // String(localized:locale:) to it).
        guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: "fr.lproj"),
              let data = FileManager.default.contents(atPath: path),
              let table = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else {
            return XCTFail("fr.lproj/Localizable.strings missing or unreadable in the bundle")
        }
        for key in keys {
            let fr = table[key]
            XCTAssertNotNil(fr, "missing fr value for \(key)")
            XCTAssertNotEqual(fr, key, "\(key): fr fell back to the key")
        }
        for key in ["picker.current", "naming.title", "settings.nav", "beat.cozy", "presence.napping"] {
            XCTAssertNotEqual(table[key], String(localized: String.LocalizationValue(key)),
                              "\(key): fr must differ from en")
        }
    }

    func testPlaceholdersSurviveInterpolation() {
        let choose = String(format: String(localized: "picker.choose"), "frog")
        XCTAssertTrue(choose.contains("frog"))
        let beat = String(format: String(localized: "beat.cozy"), "Ember")
        XCTAssertTrue(beat.contains("Ember"))
        XCTAssertLessThanOrEqual(beat.split(separator: " ").count, 8, "house voice: <= 8 words")
        let rect = String(format: String(localized: "rect.line"), 23, "napping")
        XCTAssertTrue(rect.contains("23") && rect.contains("napping"))
    }

    /// v30: a fr value that drops or reorders a %@/%d placeholder would
    /// silently corrupt (or crash) String(format:) at runtime. The placeholder
    /// SEQUENCE must be identical in en and fr for every pinned key.
    func testPlaceholderSequenceParityEnFr() throws {
        let pattern = try NSRegularExpression(pattern: "%\\d*\\$?[@d]")
        func placeholders(_ s: String) -> [String] {
            pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)).map {
                String(s[Range($0.range, in: s)!])
            }
        }
        guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: "fr.lproj"),
              let data = FileManager.default.contents(atPath: path),
              let frTable = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else {
            return XCTFail("fr.lproj/Localizable.strings missing or unreadable in the bundle")
        }
        for key in keys {
            let en = placeholders(String(localized: String.LocalizationValue(key)))
            let fr = placeholders(frTable[key] ?? "")
            XCTAssertEqual(en, fr, "\(key): placeholder sequence differs between en and fr")
        }
    }

    /// v30: the house voice (<= 8 words) is linted over ALL glanceable copy
    /// (beats + watch-face presence lines), not just one key.
    func testHouseVoiceWordCountAcrossGlanceableCopy() {
        for key in keys where key.hasPrefix("beat.") || key.hasPrefix("presence.") {
            let value = String(localized: String.LocalizationValue(key))
            XCTAssertLessThanOrEqual(value.split(separator: " ").count, 8,
                                     "\(key): house voice is <= 8 words")
        }
    }
}
