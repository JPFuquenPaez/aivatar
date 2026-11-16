import XCTest
@testable import Aivatar_Watch_App

/// v18 F3 "weather-aware personality" suite: the on-device classification
/// table, the once-per-(class,day) emission rule, the director's
/// condition dials (deterministic per seed), the weather reaction mapping
/// parity, and the pure hue rotation that keeps the value-locked ramp
/// intact. Goldens inject classes — never live weather.
final class WeatherSenseTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_793_620_800)  // 2026-11-03 12:00 UTC
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func director(_ archetype: Archetype, seed: UInt64 = 20261108) throws -> SpriteDirector {
        SpriteDirector(profile: try PersonalityProfile.load(archetype), seed: seed)
    }

    // MARK: - Classification (pure)

    func testClassifyTable() {
        
        XCTAssertEqual(WeatherSenseBridge.classify(conditionRaw: "clear", temperatureC: 22, windMS: 2), .sunny)
        XCTAssertEqual(WeatherSenseBridge.classify(conditionRaw: "sunny", temperatureC: 25, windMS: 1), .sunny)
        XCTAssertEqual(WeatherSenseBridge.classify(conditionRaw: "partlyCloudy", temperatureC: 20, windMS: 3), .gray)
        XCTAssertEqual(WeatherSenseBridge.classify(conditionRaw: "overcast", temperatureC: 18, windMS: 4), .gray)
        XCTAssertEqual(WeatherSenseBridge.classify(conditionRaw: "rain", temperatureC: 15, windMS: 5), .rain)
        XCTAssertEqual(WeatherSenseBridge.classify(conditionRaw: "heavyRain", temperatureC: 12, windMS: 8), .rain)
        XCTAssertEqual(WeatherSenseBridge.classify(conditionRaw: "snow", temperatureC: -2, windMS: 3), .cold, "snow below freezing reads cold")
        XCTAssertEqual(WeatherSenseBridge.classify(conditionRaw: "snow", temperatureC: 1, windMS: 3), .rain)
        XCTAssertEqual(WeatherSenseBridge.classify(conditionRaw: "windy", temperatureC: 20, windMS: 12), .wind)
        XCTAssertEqual(WeatherSenseBridge.classify(conditionRaw: "clear", temperatureC: 20, windMS: 14), .wind, "high wind wins over clear")
        XCTAssertEqual(WeatherSenseBridge.classify(conditionRaw: "clear", temperatureC: -5, windMS: 2), .cold)
        XCTAssertEqual(WeatherSenseBridge.classify(conditionRaw: "clear", temperatureC: 33, windMS: 2), .hot)
        XCTAssertEqual(WeatherSenseBridge.classify(conditionRaw: "somethingElse", temperatureC: 20, windMS: 2), .unknown)
    }

    func testConditionClassHashRoundTrip() {
        for klass in ConditionClass.allCases {
            XCTAssertEqual(ConditionClass.fromHash(klass.hash), klass)
        }
        XCTAssertNil(ConditionClass.fromHash(42))
        // Distinct classes never collide in the payload/log keys.
        XCTAssertEqual(Set(ConditionClass.allCases.map(\.hash)).count, ConditionClass.allCases.count)
    }

    // MARK: - Emission rule (once per class per day)

    func testShouldEmitOncePerClassPerDay() {
        let day = CompanionMemoryStore.dayIndex(of: now, calendar: utc)
        let kindHash = LifeKind.hash(of: .weatherClass)
        var log: [LifeLogEntry] = []
        XCTAssertTrue(WeatherSenseBridge.shouldEmit(classHash: ConditionClass.gray.hash, dayIndex: day, log: log))
        log.append(LifeLogEntry(kindHash: kindHash, dayIndex: day, at: now, classHash: ConditionClass.gray.hash))
        XCTAssertFalse(WeatherSenseBridge.shouldEmit(classHash: ConditionClass.gray.hash, dayIndex: day, log: log),
                       "same class same day: no repeat")
        XCTAssertTrue(WeatherSenseBridge.shouldEmit(classHash: ConditionClass.rain.hash, dayIndex: day, log: log),
                      "a different class may still speak")
        XCTAssertTrue(WeatherSenseBridge.shouldEmit(classHash: ConditionClass.gray.hash, dayIndex: day + 1, log: log),
                      "tomorrow the same class may speak again")
    }

    // MARK: - Director dials

    func testSetConditionAppliesProfileDials() throws {
        let d = try director(.ember)
        XCTAssertEqual(d.condition, .unknown)
        XCTAssertEqual(d.weatherHueShiftDeg, 0)
        d.setCondition(.sunny)
        XCTAssertEqual(d.condition, .sunny)
        d.setCondition(.gray)
        XCTAssertEqual(d.condition, .gray)
        // Prism owns the hue shift.
        let p = try director(.prism)
        p.setCondition(.hot)
        XCTAssertEqual(p.weatherHueShiftDeg, 14)
        p.setCondition(.cold)
        XCTAssertEqual(p.weatherHueShiftDeg, -14)
        p.setCondition(.unknown)
        XCTAssertEqual(p.weatherHueShiftDeg, 0)
    }

    func testConditionBiasesIdleScheduleDeterministically() throws {
        // Gray days: Ember's tempo dial 0.7 -> fewer quirks than sunny 1.3.
        func quirkCount(_ condition: ConditionClass) throws -> Int {
            let d = try director(.ember)
            d.setCondition(condition)
            var quirks = 0
            var prev = ""
            for _ in 0..<6000 {
                d.advance(toTick: d.tick + 1)
                let f = d.currentFrame
                if f == "quirk" && prev != "quirk" { quirks += 1 }
                prev = f
            }
            return quirks
        }
        let sunny = try quirkCount(.sunny)
        let gray = try quirkCount(.gray)
        XCTAssertGreaterThan(sunny, gray, "sunny Ember quirks more than gray Ember")
        // Determinism: same seed + same condition = identical sequence.
        func seq(_ condition: ConditionClass) throws -> [String] {
            let d = try director(.ember)
            d.setCondition(condition)
            var s: [String] = []
            for _ in 0..<600 { d.advance(toTick: d.tick + 1); s.append(d.currentFrame) }
            return s
        }
        XCTAssertEqual(try seq(.rain), try seq(.rain))
        XCTAssertNotEqual(try seq(.sunny), try seq(.gray))
    }

    // MARK: - Weather reaction mapping parity

    func testWeatherActParityAcrossArchetypesAndClasses() throws {
        for archetype in Archetype.allCases {
            for klass in ConditionClass.allCases where klass != .unknown {
                XCTAssertNotNil(SpriteDirector.weatherAct(for: klass, archetype: archetype),
                                "\(archetype.rawValue) answers \(klass.rawValue)")
            }
            XCTAssertNil(SpriteDirector.weatherAct(for: .unknown, archetype: archetype),
                         "unknown stays neutral — no act")
        }
        XCTAssertEqual(SpriteDirector.weatherAct(for: .rain, archetype: .willow), .happy)
        XCTAssertEqual(SpriteDirector.weatherAct(for: .wind, archetype: .nimbus), .perk)
        XCTAssertEqual(SpriteDirector.weatherAct(for: .gray, archetype: .ember), .slowBlink)
    }

    func testWeatherClassLifeEventSetsConditionAndPlays() throws {
        let d = try director(.willow)
        d.handleLifeEvent(.weatherClass(classHash: ConditionClass.rain.hash))
        XCTAssertEqual(d.condition, .rain, "the event carries the class into the director")
        XCTAssertEqual(d.lifeEventCount, 1)
        // Unknown hash: no act, no condition change, not counted.
        let d2 = try director(.willow)
        d2.handleLifeEvent(.weatherClass(classHash: 42))
        XCTAssertEqual(d2.condition, .unknown)
        XCTAssertEqual(d2.lifeEventCount, 0)
    }

    // MARK: - Hue rotation (pure)

    func testHueRotation() {
        // Identity at 0 and 360.
        XCTAssertEqual(ColorHex.hueRotated("FF9E4A", degrees: 0), "FF9E4A")
        XCTAssertEqual(ColorHex.hueRotated("FF9E4A", degrees: 360), "FF9E4A")
        // Output is always a valid 6-digit hex.
        for deg in stride(from: -30.0, through: 30.0, by: 5) {
            let out = ColorHex.hueRotated("D53F8C", degrees: deg)
            XCTAssertEqual(out.count, 6)
            XCTAssertTrue(out.allSatisfy { $0.isHexDigit })
        }
        // The real invariant: hue rotation preserves VALUE (max channel), so
        // each species' family ramp ordering (ink < shade < body <= belly)
        // survives small shifts — the value-locked family read is safe.
        func vmax(_ hex: String) -> Double {
            let rgb = ColorHex.rgb(hex)
            return Double(max(rgb.r, rgb.g, rgb.b))
        }
        func lum(_ hex: String) -> Double {
            let rgb = ColorHex.rgb(hex)
            return 0.299 * Double(rgb.r) + 0.587 * Double(rgb.g) + 0.114 * Double(rgb.b)
        }
        for hex in ["FF9E4A", "55D98A", "5DA0EA", "D53F8C", "8FA3E8"] {
            let rotated = ColorHex.hueRotated(hex, degrees: 12)
            XCTAssertEqual(vmax(rotated), vmax(hex), accuracy: 1.5,
                           "\(hex): 12-degree shift preserves value")
        }
        // Ordering survives on the real species palettes (doc §5.3 tokens).
        for archetype in Archetype.allCases {
            let spec = CompanionToys.spec(for: archetype)
            let ink = ColorHex.hueRotated(spec.inkHex, degrees: 12)
            let shade = ColorHex.hueRotated(spec.shadeHex, degrees: 12)
            let body = ColorHex.hueRotated(spec.bodyHex, degrees: 12)
            let belly = ColorHex.hueRotated(spec.bellyHex, degrees: 12)
            XCTAssertLessThan(lum(ink), lum(shade), "\(archetype.rawValue): ink < shade after shift")
            XCTAssertLessThan(lum(shade), lum(body), "\(archetype.rawValue): shade < body after shift")
            XCTAssertLessThanOrEqual(lum(body), lum(belly), "\(archetype.rawValue): belly reads lightest")
        }
        // Shifting actually changes the color (non-gray input).
        XCTAssertNotEqual(ColorHex.hueRotated("FF9E4A", degrees: 14), "FF9E4A")
    }
}
