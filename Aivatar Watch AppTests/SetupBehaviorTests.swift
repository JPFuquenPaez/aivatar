import XCTest
@testable import Aivatar_Watch_App

/// v31 setup-behavior + guard tests: the rename clamp (now a pure function),
/// dynamic localization keys never echo their key, the widget's archetypeRaw
/// sanitizer, and the Smart Stack relevance ordering.
final class SetupBehaviorTests: XCTestCase {

    // MARK: Naming clamp (NamingCeremonyView.resolvedName)

    func testResolvedNameTrimsClampsAndFallsBack() {
        XCTAssertEqual(NamingCeremonyView.resolvedName("  Milo  ", fallback: "Ember"), "Milo")
        XCTAssertEqual(NamingCeremonyView.resolvedName("", fallback: "Ember"), "Ember")
        XCTAssertEqual(NamingCeremonyView.resolvedName("   ", fallback: "Willow"), "Willow")
        let long = String(repeating: "a", count: 40)
        XCTAssertEqual(NamingCeremonyView.resolvedName(long, fallback: "Ember").count, 24,
                       "a watch-stage name must fit one line (<= 24 chars)")
    }

    // MARK: Dynamic localization keys

    func testAnimalCopyKeysNeverEchoTheKey() {
        for archetype in Archetype.allCases {
            XCTAssertTrue(LocalizedAnimalCopy.isKnown(archetype.rawValue))
            for value in [LocalizedAnimalCopy.name(archetype.rawValue),
                          LocalizedAnimalCopy.element(archetype.rawValue),
                          LocalizedAnimalCopy.temperament(archetype.rawValue)] {
                XCTAssertFalse(value.contains("animal."), "key echoed into UI: \(value)")
                XCTAssertFalse(value.isEmpty)
            }
        }
        XCTAssertFalse(LocalizedAnimalCopy.isKnown("dragon"))
    }

    func testWeatherKeysNeverEchoTheKey() {
        for klass in ConditionClass.allCases {
            let key = "weather.\(klass.rawValue)"
            let value = NSLocalizedString(key, comment: "weather class name")
            XCTAssertNotEqual(value, key, "missing weather key \(key)")
        }
    }

    // MARK: Widget guards (AivatarShared)

    func testSanitizedArchetypeRawFallsBackToDefault() {
        XCTAssertEqual(CompanionStateDerivation.sanitizedArchetypeRaw("willow"), "willow")
        XCTAssertEqual(CompanionStateDerivation.sanitizedArchetypeRaw("dragon"), "ember",
                       "a corrupt raw value must never reach the strings tables or icon paths")
        XCTAssertEqual(CompanionStateDerivation.sanitizedArchetypeRaw(""), "ember")
    }

    func testRelevanceScoreOrdering() {
        let asleep = CompanionStateDerivation.relevanceScore(presence: .asleep, lastEventKind: nil)
        let awake = CompanionStateDerivation.relevanceScore(presence: .awake, lastEventKind: nil)
        let event = CompanionStateDerivation.relevanceScore(presence: .event, lastEventKind: .calendarSoon)
        let split = CompanionStateDerivation.relevanceScore(presence: .event, lastEventKind: .split)
        XCTAssertLessThan(asleep, awake)
        XCTAssertLessThan(awake, event)
        XCTAssertGreaterThanOrEqual(split, event, "live workout/split is the most relevant")
        XCTAssertLessThanOrEqual(split, 1.0)
    }

    // MARK: Bond look-at-you dial (v31)

    func testLookAtYouRequiresBondLevel3() {
        XCTAssertEqual(BondRules.lookAtYouPerMin(1), 0)
        XCTAssertEqual(BondRules.lookAtYouPerMin(2), 0)
        XCTAssertGreaterThan(BondRules.lookAtYouPerMin(3), 0)
        XCTAssertGreaterThan(BondRules.lookAtYouPerMin(5), 0)
    }
}
