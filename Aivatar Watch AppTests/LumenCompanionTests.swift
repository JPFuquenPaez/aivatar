import XCTest
@testable import Aivatar_Watch_App

/// Aivatar 2.0 Phase 3, E10 — the sixth companion (lumen, the moth). Parity
/// across every per-archetype surface: profile loads + weights sum, the toy
/// spec contract (lavender family, moth wings + antennae, every director
/// frame resolves, the glow quirk), hit-circle + vapor wiring, reaction
/// tables answer, haptic grammar maps, unlock gating + one-time reveal,
/// picker shows five pages until revealed.
final class LumenCompanionTests: XCTestCase {

    func testProfileLoadsAndWeightsSum() throws {
        let profile = try PersonalityProfile.load(.lumen)
        XCTAssertEqual(profile.id, "lumen")
        XCTAssertEqual(profile.assetVersion, "3.0.0")
        let sum = profile.gesturePoolWeights.values.reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 0.02)
        XCTAssertEqual(profile.gazePolicy, .linger)
        XCTAssertEqual(profile.tell, .dust)
        XCTAssertEqual(profile.motionProfile.tempoScale, 0.9)
        XCTAssertEqual(profile.blink?.durationScale, 1.2)
    }

    func testToyContract() {
        // v3: lumen is the moth — lavender family, winged, antennae, no
        // tail, one of the six toy specs (same rig, unique identity parts).
        let spec = CompanionToys.spec(for: .lumen)
        XCTAssertEqual(spec.bodyHex, "A78BFA", "lavender body (doc §5.3)")
        XCTAssertEqual(spec.bellyHex, "F5F4EF")
        XCTAssertEqual(spec.shadeHex, "6D5BD0")
        XCTAssertEqual(spec.inkHex, "171226")
        XCTAssertEqual(spec.accentHex, "FFE9A8", "glow accent")
        XCTAssertEqual(spec.uiAccentHex, "A78BFA")
        XCTAssertEqual(spec.wingKind, .mothPair)
        XCTAssertTrue(spec.antennae)
        XCTAssertEqual(spec.tailKind, .none)
        XCTAssertGreaterThanOrEqual(spec.eyeRatio, 0.30, "baby-schema eye ratio")
        // Every director frame id resolves to a real pose.
        for frame in ["idle", "idleA", "idleB", "breathe", "blink", "sleepy",
                      "happy", "glanceL", "glanceR", "quirk", "perk", "yawn"] {
            let drive = PuppetDrive(archetype: .lumen, frameID: frame)
            let resolved = PuppetPoser.resolve(drive)
            XCTAssertNotNil(resolved.pose)
        }
        // The quirk is the luminous wing shimmer: wings lift, glow swells.
        var qd = PuppetDrive(archetype: .lumen, frameID: "quirk")
        qd.frameAge = 3
        let quirk = PuppetPoser.resolve(qd).pose
        XCTAssertGreaterThan(quirk.wing, 0.5, "wings lift on the shimmer")
        XCTAssertEqual(quirk.catchGlow, 1, "the glow is the tell")
    }

    func testHitCircleAndVaporTellWiring() throws {
        // v3: lumen's hit circle matches the shared head geometry, and the
        // cold-vapor tell rides the drive as a prop (rest suppresses it).
        let canvas = CGSize(width: 200, height: 320)
        let hit = PuppetDrawing.headHitCircle(archetype: .lumen, canvas: canvas)
        XCTAssertTrue(hit.radius > 30, "moth head is boopable")
        let center = CGPoint(x: 200, y: 320).applying(CGAffineTransform(scaleX: 0.5, y: 0.5))
        XCTAssertLessThan(hypot(hit.center.x - center.x, hit.center.y - center.y), hit.radius,
                          "the hit circle contains the canvas center")
        var drive = PuppetDrive(archetype: .lumen, frameID: "idle")
        drive.vapor = true
        XCTAssertTrue(PuppetPoser.resolve(drive).props.vapor, "vapor rides the props")
        drive.resting = true
        XCTAssertFalse(PuppetPoser.resolve(drive).props.vapor, "rest LOD suppresses vapor")
    }

    func testReactionTablesAnswerForLumen() {
        for event: LifeEvent in [.calendarSoon(titleHash: 1), .workoutDone(kindBand: 1, durationBand: 2),
                                 .sleptWithWatch, .weatherClass(classHash: ConditionClass.sunny.hash)] {
            XCTAssertNotNil(SpriteDirector.reactionAct(for: event, archetype: .lumen),
                            "\(event) must have a lumen answer")
        }
        XCTAssertNotNil(SpriteDirector.weatherAct(for: .cold, archetype: .lumen))
        XCTAssertNil(SpriteDirector.weatherAct(for: .unknown, archetype: .lumen))
        XCTAssertNotNil(HapticGrammar.type(for: .ack, archetype: .lumen))
        XCTAssertNotNil(HapticGrammar.type(for: .lifeEvent, archetype: .lumen))
    }

    func testUnlockGatingAndRevealFlag() {
        // Locked below confidant.
        XCTAssertFalse(BondRules.sixthCompanionUnlocked(4))
        XCTAssertTrue(BondRules.sixthCompanionUnlocked(5))
        // Reveal flag: once set, the picker shows six pages (pure gate).
        var m = CompanionMemory(firstLaunch: Date(), lastSeen: Date())
        m.bondXP = 100
        m.sixthRevealed = true
        XCTAssertTrue(BondRules.sixthCompanionUnlocked(m.bondLevel) && m.sixthRevealed)
        // Legacy memory: flag defaults false.
        let legacy = #"{"firstLaunch": 1793620800, "lastSeen": 1793620800}"#.data(using: .utf8)!
        XCTAssertFalse((try? JSONDecoder().decode(CompanionMemory.self, from: legacy))?.sixthRevealed ?? true)
    }

    func testLocalizedIdentityResolves() {
        XCTAssertEqual(LocalizedAnimalCopy.name("lumen"), "Moth")
        XCTAssertEqual(LocalizedAnimalCopy.element("lumen"), "night")
        XCTAssertFalse(LocalizedAnimalCopy.temperament("lumen").isEmpty)
        XCTAssertTrue(LocalizedAnimalCopy.isKnown("lumen"))
        XCTAssertEqual(Archetype.lumen.animal.name, "Moth")
        XCTAssertEqual(Archetype.lumen.quirkGesture, .sparkle)
        XCTAssertEqual(Archetype.lumen.farewellGesture, .slowBlink)
    }

    func testDirectorParityForLumen() throws {
        // The director runs a deterministic schedule for the sixth companion.
        let profile = try PersonalityProfile.load(.lumen)
        let a = SpriteDirector(profile: profile, seed: 20261010 + 5)
        let b = SpriteDirector(profile: profile, seed: 20261010 + 5)
        for t in 1...300 {
            a.advance(toTick: t); b.advance(toTick: t)
            XCTAssertEqual(a.currentFrame, b.currentFrame)
        }
    }

    func testWidgetSanitizerKnowsLumen() {
        XCTAssertEqual(CompanionStateDerivation.sanitizedArchetypeRaw("lumen"), "lumen")
        XCTAssertEqual(CompanionStateDerivation.sanitizedArchetypeRaw("dragon"), "ember")
    }
}
