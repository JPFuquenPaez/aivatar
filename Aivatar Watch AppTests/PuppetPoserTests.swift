import XCTest
@testable import Aivatar_Watch_App

/// v3 PuppetPoserTests: the pure frame→pose resolver is the character's
/// truth layer. Every director frame id resolves per archetype; the face
/// grammar carries the expressions (v13 rule); the quirks are species
/// signatures; greet/slowBlink/songburst/boop channels ride the drive
/// flags; rest pins everything; Reduce Motion pins the body and keeps the
/// face; and the whole map is deterministic (golden-hash-able).
final class PuppetPoserTests: XCTestCase {

    private let directorFrames = ["idle", "idleA", "idleB", "breathe", "blink", "sleepy",
                                  "happy", "glanceL", "glanceR", "quirk", "perk", "yawn"]

    private func resolve(_ archetype: Archetype = .ember, _ frame: String,
                        modify: (inout PuppetDrive) -> Void = { _ in }) -> (pose: PuppetPose, props: PuppetProps) {
        var drive = PuppetDrive(archetype: archetype, frameID: frame)
        modify(&drive)
        return PuppetPoser.resolve(drive)
    }

    // MARK: - Vocabulary coverage

    func testEveryDirectorFrameResolvesAndNonIdleActsDiffer() {
        for archetype in Archetype.allCases {
            let idle = resolve(archetype, "idle").pose
            for frame in directorFrames {
                let pose = resolve(archetype, frame).pose
                // "idle" and "breathe" are the same neutral stance by design
                // (the ambient layer carries the breath at render time);
                // every ACT frame must visibly differ.
                if frame != "idle" && frame != "breathe" {
                    XCTAssertNotEqual(pose, idle,
                        "\(archetype.rawValue)/\(frame): an act frame that reads as idle is invisible")
                }
            }
        }
    }

    // MARK: - Face grammar (the v31 system, parameterized)

    func testFaceGrammarPerFrame() {
        XCTAssertEqual(resolve(.ember, "blink").pose.lidOpen, 0, "blink closes the lids")
        let sleepy = resolve(.ember, "sleepy").pose
        XCTAssertEqual(sleepy.lidOpen, 0.22, accuracy: 0.001)
        XCTAssertEqual(sleepy.lidSoft, 0.6, accuracy: 0.001)
        let happy = resolve(.ember, "happy").pose
        XCTAssertEqual(happy.lidOpen, 0.18, accuracy: 0.001)
        XCTAssertEqual(happy.mouth, .ws)
        XCTAssertEqual(happy.cheekGlow, 1)
        XCTAssertEqual(happy.earL, 0.9)
        XCTAssertGreaterThanOrEqual(happy.wag, 0.9)
        XCTAssertLessThan(happy.bodyScaleY, 1.0, "happy squashes a little")
        let yawn = resolve(.ember, "yawn").pose
        XCTAssertEqual(yawn.mouth, .yawn)
        XCTAssertEqual(yawn.lidOpen, 0.3, accuracy: 0.001)
        let perk = resolve(.ember, "perk").pose
        XCTAssertEqual(perk.earL, 1)
        XCTAssertEqual(perk.pupilDilate, 0.8, accuracy: 0.001)
        XCTAssertLessThan(perk.headNod, 0)
        // Asymmetric idle glances mirror each other exactly.
        let gl = resolve(.ember, "glanceL").pose
        let gr = resolve(.ember, "glanceR").pose
        XCTAssertEqual(gl.pupilX, -gr.pupilX)
        XCTAssertEqual(gl.headTurn, -gr.headTurn)
        XCTAssertEqual(gl.headTilt, -gr.headTilt)
        let a = resolve(.ember, "idleA").pose
        let b = resolve(.ember, "idleB").pose
        XCTAssertEqual(a.headTurn, -b.headTurn, "the run-cycle look-away mirrors")
    }

    // MARK: - Quirks are species signatures (doc §5.7)

    func testQuirkSignaturesPerSpecies() {
        // Ember: the tail-coil firework hop with the ear flick.
        let ember = resolve(.ember, "quirk").pose
        XCTAssertEqual(ember.hop, 70, "the fox hops")
        XCTAssertGreaterThanOrEqual(ember.tailLift, 0.9)
        XCTAssertEqual(ember.earL, -0.5)
        XCTAssertEqual(ember.earR, 1, "ears flick asymmetrically")
        XCTAssertTrue(resolve(.ember, "quirk").props.sunnyBurst)
        // Willow: the shibe head-cock + smile (the tilt eases with settle).
        let young = resolve(.willow, "quirk", modify: { $0.frameAge = 1 }).pose
        let settled = resolve(.willow, "quirk", modify: { $0.frameAge = 3 }).pose
        XCTAssertEqual(young.headTilt, 0.34, accuracy: 0.001)
        XCTAssertEqual(settled.headTilt, 0.24, accuracy: 0.001)
        XCTAssertEqual(settled.mouth, .ws)
        // Compass: butt-wiggle with airplane ears.
        let compass = resolve(.compass, "quirk").pose
        XCTAssertEqual(compass.bodyScaleX, 1.07, accuracy: 0.001)
        XCTAssertEqual(compass.earL, 1)
        XCTAssertEqual(compass.earR, -0.35)
        XCTAssertEqual(compass.wag, 1)
        // Prism: the ear-twitch inspection (asymmetric once the settle lands).
        let prism = resolve(.prism, "quirk", modify: { $0.frameAge = 3 }).pose
        XCTAssertEqual(prism.earL, 1)
        XCTAssertLessThan(prism.earR, 1, "the twitch is asymmetric (per family)")
        // Nimbus: the wing flip + the chirp, with accent notes as props.
        let nimbus = resolve(.nimbus, "quirk")
        XCTAssertEqual(nimbus.pose.wing, 0.85, accuracy: 0.001)
        XCTAssertEqual(nimbus.pose.mouth, .o)
        XCTAssertTrue(nimbus.props.songNotes)
        // Lumen: the shimmer — wings lift, the glow swells.
        let lumen = resolve(.lumen, "quirk").pose
        XCTAssertEqual(lumen.wing, 0.8, accuracy: 0.001)
        XCTAssertEqual(lumen.catchGlow, 1)
    }

    // MARK: - Greeting, petting, songburst, boop

    func testGreetingIsPupilsUpWithWeatherTells() {
        let greet = resolve(.ember, "idle", modify: { $0.greeting = true }).pose
        XCTAssertEqual(greet.pupilY, -1, "the companion looks UP at the user")
        XCTAssertEqual(greet.pupilX, 0)
        XCTAssertEqual(greet.pupilDilate, 0.75, accuracy: 0.001)
        XCTAssertLessThan(greet.headNod, 0, "head lifts")
        // Weather tells: rain carries the leaf, cold the frost, sun the burst.
        var rainy = PuppetDrive(archetype: .ember, frameID: "idle")
        rainy.greeting = true
        rainy.condition = .rain
        XCTAssertTrue(PuppetPoser.resolve(rainy).props.umbrellaLeaf)
        var frosty = rainy
        frosty.condition = .cold
        XCTAssertTrue(PuppetPoser.resolve(frosty).props.frostSparkle)
        let frostyPose = PuppetPoser.resolve(frosty).pose
        XCTAssertGreaterThan(frostyPose.bodyScaleX, 1.0, "cold hunches a touch")
        var sunny = rainy
        sunny.condition = .sunny
        XCTAssertTrue(PuppetPoser.resolve(sunny).props.sunnyBurst)
    }

    func testSlowBlinkRitualLeansTowardThePettedSide() {
        var drive = PuppetDrive(archetype: .willow, frameID: "idle")
        drive.slowBlink = true
        drive.lastGazeDir = -1
        let pose = PuppetPoser.resolve(drive).pose
        XCTAssertEqual(pose.lean, -0.045, accuracy: 0.001, "leans left")
        XCTAssertEqual(pose.headTurn, -0.3, accuracy: 0.001)
        XCTAssertEqual(pose.headOffsetX, -14, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(pose.wag, 0.5, "the tail flutters")
        XCTAssertEqual(pose.mouth, .smile)
        XCTAssertGreaterThanOrEqual(pose.cheekGlow, 0.55)
    }

    func testSongburstIsBeakOpenChatter() {
        var drive = PuppetDrive(archetype: .nimbus, frameID: "idle")
        drive.songburst = true
        let out = PuppetPoser.resolve(drive)
        XCTAssertEqual(out.pose.mouth, .o)
        XCTAssertEqual(out.pose.cheekGlow, 1)
        XCTAssertTrue(out.props.songNotes)
    }

    func testBoopChannelsPaintFaceAndSquash() {
        var drive = PuppetDrive(archetype: .compass, frameID: "idle")
        drive.blushing = true
        let blush = PuppetPoser.resolve(drive).pose
        XCTAssertGreaterThanOrEqual(blush.cheekGlow, 0.85)
        var pulse = drive
        pulse.boopPulse = true
        let squashed = PuppetPoser.resolve(pulse).pose
        XCTAssertLessThanOrEqual(squashed.bodyScaleY, 0.88)
        XCTAssertGreaterThanOrEqual(squashed.bodyScaleX, 1.10)
        XCTAssertEqual(squashed.mouth, .ws)
        XCTAssertEqual(squashed.cheekGlow, 1)
    }

    // MARK: - v1.1 base asymmetry (doc §5.12.1)

    func testNeutralStanceIsNeverPerfectlySymmetric() {
        for archetype in Archetype.allCases {
            let pose = resolve(archetype, "idle").pose
            XCTAssertFalse(pose.headTilt == 0 && pose.earL == pose.earR,
                "\(archetype.rawValue): the neutral stance carries a base asymmetry (the anti-stiff rule)")
            XCTAssertGreaterThanOrEqual(abs(pose.headTilt), 0.03,
                "\(archetype.rawValue): default head tilt is 3-5 degrees or more")
        }
        // breathe shares the neutral stance (the ambient layer breathes).
        for archetype in Archetype.allCases {
            XCTAssertEqual(resolve(archetype, "idle").pose, resolve(archetype, "breathe").pose)
        }
    }

    // MARK: - Rest + accessibility

    func testRestPosePinsEverything() {
        for archetype in Archetype.allCases {
            let rest = resolve(archetype, "idle", modify: { $0.resting = true }).pose
            XCTAssertEqual(rest.lidOpen, 0.16, accuracy: 0.001)
            XCTAssertEqual(rest.lidSoft, 0.75, accuracy: 0.001)
            XCTAssertEqual(rest.earL, -0.5)
            XCTAssertEqual(rest.mouth, .rest)
            XCTAssertLessThan(rest.headTilt, 0)
            // Rest ignores act channels wholesale: nothing moves in Always On.
            var anything = PuppetDrive(archetype: archetype, frameID: "happy")
            anything.resting = true
            anything.blushing = true
            anything.slowBlink = true
            anything.songburst = true
            XCTAssertEqual(PuppetPoser.resolve(anything).pose, rest,
                           "\(archetype.rawValue): rest pins the pose against every input")
        }
    }

    func testReduceMotionL2PinsBodyKeepsFace() {
        var drive = PuppetDrive(archetype: .ember, frameID: "happy")
        drive.motionFloor = .lidsOnly
        let pose = PuppetPoser.resolve(drive).pose
        XCTAssertEqual(pose.bodyScaleX, 1)
        XCTAssertEqual(pose.bodyScaleY, 1)
        XCTAssertEqual(pose.hop, 0)
        XCTAssertEqual(pose.earL, 0)
        XCTAssertEqual(pose.wag, 0)
        XCTAssertEqual(pose.wing, 0)
        XCTAssertEqual(pose.mouth, .ws, "the face keeps expressing")
        XCTAssertEqual(pose.lidOpen, 0.18, accuracy: 0.001)
        XCTAssertEqual(pose.cheekGlow, 1)
    }

    func testMoodBiases() {
        var playful = PuppetDrive(archetype: .willow, frameID: "idle")
        playful.mood = .playful
        XCTAssertGreaterThanOrEqual(PuppetPoser.resolve(playful).pose.wag, 0.3)
        var lonely = PuppetDrive(archetype: .willow, frameID: "idle")
        lonely.mood = .lonely
        XCTAssertLessThanOrEqual(PuppetPoser.resolve(lonely).pose.pupilY, -0.35,
                                 "lonely looks up at you")
        var curious = PuppetDrive(archetype: .willow, frameID: "idle")
        curious.mood = .curious
        XCTAssertGreaterThanOrEqual(PuppetPoser.resolve(curious).pose.pupilDilate, 0.7)
    }

    // MARK: - Props mapping (memory made visible)

    func testInteriorityRidesProps() {
        // Family-gated (v43 semantics): sprout is Willow's, the week grid
        // Compass's, the trinket Prism's — other families never carry them.
        var drive = PuppetDrive(archetype: .willow, frameID: "idle")
        var interiority = InteriorityTuning()
        interiority.sproutGrowth = 0.6
        drive.interiority = interiority
        let props = PuppetPoser.resolve(drive).props
        XCTAssertTrue(props.sprout, "willow's sprout at growth >= 0.6")
        // Ember with the same tuning carries nothing.
        var foreign = drive
        foreign.archetype = .ember
        XCTAssertFalse(PuppetPoser.resolve(foreign).props.sprout, "sprout is willow-only")

        var weekDrive = PuppetDrive(archetype: .compass, frameID: "idle")
        var week = InteriorityTuning()
        week.streakDays = 5
        weekDrive.interiority = week
        let weekProps = PuppetPoser.resolve(weekDrive).props
        XCTAssertEqual(weekProps.weekTotal, 7)
        XCTAssertEqual(weekProps.weekLit, 5)
        // Streak clamps at 7 lit.
        weekDrive.interiority.streakDays = 12
        XCTAssertEqual(PuppetPoser.resolve(weekDrive).props.weekLit, 7)
        // Defaults: nothing rides (and no cross-family leakage).
        let def = PuppetPoser.resolve(PuppetDrive(archetype: .ember, frameID: "idle")).props
        XCTAssertFalse(def.sprout)
        XCTAssertEqual(def.weekLit, 0)
        XCTAssertFalse(def.trinket)
    }

    func testMoteMapsStageGridToFractions() {
        var drive = PuppetDrive(archetype: .ember, frameID: "idle")
        drive.moteX = 10
        drive.moteY = 9
        let props = PuppetPoser.resolve(drive).props
        XCTAssertEqual(props.moteX ?? 0, 10.5 / 20.0, accuracy: 1e-9, "20-wide grid fraction")
        XCTAssertEqual(props.moteY ?? 0, 9.5 / 18.0, accuracy: 1e-9, "18-tall grid fraction")
    }

    func testMementoAlphaAndSteadyStates() {
        var deposit = PuppetDrive(archetype: .ember, frameID: "idle")
        deposit.mementoAlpha = 0.5
        XCTAssertEqual(PuppetPoser.resolve(deposit).props.mementoAlpha, 0.5, accuracy: 1e-9)
        var steady = PuppetDrive(archetype: .ember, frameID: "idle")
        steady.mementoSteady = true
        XCTAssertEqual(PuppetPoser.resolve(steady).props.mementoAlpha, 1, accuracy: 1e-9)
        XCTAssertEqual(PuppetPoser.resolve(PuppetDrive(archetype: .ember, frameID: "idle")).props.mementoAlpha, 0)
    }

    // MARK: - Determinism (the truth layer is golden-pinnable)

    func testResolverIsDeterministicAndFamilySeparating() {
        for frame in directorFrames {
            for archetype in Archetype.allCases {
                let a = resolve(archetype, frame)
                let b = resolve(archetype, frame)
                XCTAssertEqual(a.pose, b.pose, "\(archetype)/\(frame): same drive -> same pose")
                XCTAssertEqual(a.pose.hashValue64(), b.pose.hashValue64())
            }
        }
        // The quirk separates species: ember's firework != lumen's shimmer.
        XCTAssertNotEqual(resolve(.ember, "quirk").pose, resolve(.lumen, "quirk").pose)
        // The fingerprint quantizes at 1/256 — tiny float drift is invisible.
        var drift = resolve(.ember, "idle").pose
        drift.lidOpen += 0.0001
        XCTAssertEqual(drift.fingerprint(), resolve(.ember, "idle").pose.fingerprint(),
                      "fingerprint survives sub-threshold drift")
    }
}
