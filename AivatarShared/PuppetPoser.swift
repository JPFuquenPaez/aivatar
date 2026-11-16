import Foundation
import CoreGraphics

/// PuppetDrive (v3): the director's live state, flattened into shared data so
/// the pure resolver compiles everywhere (watch stage, phone shell, widget
/// icon, postcard composition, tests). The watch's SpriteDirector and the
/// shared PhoneCompanionAnimator each map themselves into this struct;
/// PuppetPoser consumes only this. Memory is an input, never wall-clock.
nonisolated struct PuppetDrive: Sendable {
    var archetype: Archetype
    var frameID: String
    /// Ticks the frame has been showing (act envelopes ease within a run).
    var frameAge: Int = 0
    var tick: Int = 0
    /// Mood (interaction-derived; biases tails and glances).
    var mood: PuppetMood = .calm
    var bondLevel: Int = 1
    var condition: ConditionClass = .unknown
    /// Rest / Always On: the stage renders the static rest pose.
    var resting = false
    /// The wrist-raise greeting sequence plays (pupils up at the user).
    var greeting = false
    /// The slow-blink ritual (long-press "petting"): lids close to watch.
    var slowBlink = false
    /// Nimbus's songburst (sustained voice came in).
    var songburst = false
    /// Boop blush flush (E7).
    var blushing = false
    /// The boop just landed (the squash-and-glow pulse's first tick).
    var boopPulse = false
    /// Cold breath vapor (E9.2).
    var vapor = false
    /// The confidant memento deposit's alpha (0...1) while it appears.
    var mementoAlpha: Double = 0
    var mementoSteady = false
    /// The self-play mote (grid cells, 20x18 stage space), if active.
    var moteX: Int? = nil
    var moteY: Int? = nil
    var interiority: InteriorityTuning = .default
    /// The companion's last gaze direction (-1 left, +1 right).
    var lastGazeDir = 0
    /// Reduce Motion discipline: L2 pins the body and keeps the face.
    var motionFloor: PuppetMotionFloor = .full
    /// Prism's weather hue rotation in degrees (capped in the director).
    var hueShiftDeg: Double = 0

    nonisolated enum PuppetMood: Sendable, Equatable {
        case calm, curious, bored, lonely, playful
    }

    nonisolated enum PuppetMotionFloor: Sendable, Equatable {
        case full
        case lidsOnly
    }
}

/// PuppetPoser (v3): the pure map from the director's semantic frame to the
/// puppet's pose target. The director vocabulary is untouched — every frame
/// id resolves, PER ARCHETYPE, into part channels with the v3 face grammar
/// (lids, pupils, cheeks, mouth) carrying the expression and the body
/// carrying squash-and-stretch personality. Same inputs, same pose, always:
/// deterministic, golden-pinned by tests. Motion the renderer adds between
/// targets (springs, ambient breathing) never enters this layer.
nonisolated enum PuppetPoser {

    nonisolated static func resolve(_ drive: PuppetDrive) -> (pose: PuppetPose, props: PuppetProps) {
        var pose = PuppetPose()
        var props = PuppetProps()

        // Props ride every frame (memory-made-visible + transient tells).
        // Each artifact belongs to ONE family (v43 semantics): sprout is
        // Willow's, the week grid Compass's, the trinket Prism's.
        let interiority = drive.interiority
        props.sprout = drive.archetype == .willow && interiority.sproutGrowth >= 0.6
        if drive.archetype == .compass, interiority.streakDays > 0 {
            props.weekTotal = 7
            props.weekLit = min(interiority.streakDays, 7)
        }
        props.trinket = drive.archetype == .prism && interiority.trinketPresent
        if let _ = drive.moteX, drive.moteY != nil {
            props.moteX = (Double(drive.moteX!) + 0.5) / 20.0
            props.moteY = (Double(drive.moteY!) + 0.5) / 18.0
        }
        props.vapor = drive.vapor && !drive.resting
        if drive.mementoAlpha > 0 {
            props.mementoAlpha = drive.mementoAlpha
        } else if drive.mementoSteady {
            props.mementoAlpha = 1
        }

        // The rest pose: heavy lids, settled ears, rest palette handled by
        // the style; never any ambient or act channels.
        if drive.resting {
            pose.lidOpen = 0.16
            pose.lidSoft = 0.75
            pose.earL = -0.5
            pose.earR = -0.5
            pose.headTilt = -0.08
            pose.mouth = .rest
            return (pose, props)
        }

        // Base posture per frame id (the cat's grammar, translated).
        switch drive.frameID {
        case "blink":
            pose.lidOpen = 0
        case "sleepy":
            pose.lidOpen = 0.22
            pose.lidSoft = 0.6
            pose.earL = -0.45
            pose.earR = -0.45
            pose.headTilt = -0.07
            pose.mouth = .rest
        case "happy":
            pose.lidOpen = 0.18
            pose.mouth = .ws
            pose.cheekGlow = 1
            pose.earL = 0.9
            pose.earR = 0.9
            pose.bodyScaleY = 0.94
            pose.bodyScaleX = 1.05
            pose.tailLift = 0.38
            pose.wag = 0.9
            if drive.archetype == .nimbus { pose.wing = 0.55 }
        case "glanceL":
            pose.pupilX = -1
            pose.headTurn = -0.4
            pose.headTilt = -0.05
        case "glanceR":
            pose.pupilX = 1
            pose.headTurn = 0.4
            pose.headTilt = 0.05
        case "perk":
            pose.earL = 1
            pose.earR = 1
            pose.headNod = -0.25
            pose.pupilDilate = 0.8
            pose.tailLift = 0.25
        case "quirk":
            applyQuirk(drive, &pose, &props)
        case "yawn":
            pose.lidOpen = 0.3
            pose.mouth = .yawn
            pose.headTilt = 0.14
            pose.earL = -0.55
            pose.earR = -0.55
        case "idleA":
            pose.headTurn = -0.18
            pose.pupilX = -0.45
        case "idleB":
            pose.headTurn = 0.18
            pose.pupilX = 0.45
        default:
            break // idle / breathe: the neutral stance; ambient carries life
        }

        // E7 boop: the flush and the first-tick squash-and-glow pulse.
        if drive.blushing {
            pose.cheekGlow = max(pose.cheekGlow, 0.85)
        }
        if drive.boopPulse {
            pose.bodyScaleY = min(pose.bodyScaleY, 0.88)
            pose.bodyScaleX = max(pose.bodyScaleX, 1.10)
            pose.cheekGlow = 1
            pose.mouth = .ws
            pose.headNod = 0.15
        }

        // The greeting: every wrist-raise begins with the companion noticing
        // you — pupils snap up, then the happy blink (the 600 ms sequence is
        // the director queue; the pose reads "looking at the user").
        if drive.greeting {
            pose.pupilY = -1
            pose.pupilX = 0
            pose.pupilDilate = 0.75
            pose.headNod = -0.3
            pose.headTurn = CGFloat(drive.lastGazeDir) * 0.12
            switch drive.condition {
            case .rain:
                props.umbrellaLeaf = true
                pose.earL = 0.4; pose.earR = 0.4
            case .cold:
                props.frostSparkle = true
                pose.bodyScaleX = 1.03
                pose.bodyScaleY = 0.97
            case .sunny, .hot:
                props.sunnyBurst = true
            default:
                break
            }
        }

        // The slow-blink ritual (long-press petting): lids close slowly and
        // stay, the head leans toward the touched side, the tail flutters.
        if drive.slowBlink {
            pose.lean = CGFloat(drive.lastGazeDir) * 0.045
            pose.headTurn = CGFloat(drive.lastGazeDir) * 0.3
            pose.headOffsetX = CGFloat(drive.lastGazeDir) * 14
            pose.cheekGlow = max(pose.cheekGlow, 0.55)
            pose.wag = max(pose.wag, 0.5)
            pose.mouth = .smile
            pose.earL = min(pose.earL, 0.35)
            pose.earR = min(pose.earR, 0.35)
        }

        // Nimbus's songburst: beak-open happy chatter with accent notes.
        if drive.songburst {
            props.songNotes = true
            pose.mouth = .o
            pose.headTilt = 0.1
            pose.cheekGlow = 1
        }

        // Mood biases (cute-aggression literature's independent signal):
        // playful wags; lonely looks up at you; curious dilates.
        switch drive.mood {
        case .playful:
            pose.wag = max(pose.wag, 0.3)
        case .lonely:
            pose.pupilY = min(pose.pupilY, -0.35)
        case .curious:
            pose.pupilDilate = max(pose.pupilDilate, 0.7)
        default:
            break
        }

        // Reduce Motion L2: the body pins; the face keeps living.
        if drive.motionFloor == .lidsOnly {
            pose.bodyScaleX = 1
            pose.bodyScaleY = 1
            pose.bodyOffsetX = 0
            pose.bodyOffsetY = 0
            pose.hop = 0
            pose.lean = 0
            pose.headOffsetX = 0
            pose.headOffsetY = 0
            pose.earL = 0
            pose.earR = 0
            pose.tailLift = 0
            pose.tailAngle = 0
            pose.wag = 0
            pose.wing = 0
        }
        return (pose, props)
    }

    /// The species' signature quirk (doc §5.7): the one move each companion
    /// owns. Personality, not randomness — each is a small authored story.
    private nonisolated static func applyQuirk(_ drive: PuppetDrive,
                                               _ pose: inout PuppetPose,
                                               _ props: inout PuppetProps) {
        // Small anticipation ramp within the hold so the move "lands".
        let settle = CGFloat(min(max(drive.frameAge - 1, 0), 2)) / 2.0
        switch drive.archetype {
        case .ember:
            // Tail-coil firework hop: the wind-up coils, then the pop.
            pose.hop = 70
            pose.bodyScaleY = 0.92
            pose.bodyScaleX = 1.08
            pose.tailLift = 0.9
            pose.wag = 0.6
            pose.earL = -0.5   // ears flick back on the launch
            pose.earR = 1
            pose.pupilDilate = 0.85
            props.sunnyBurst = true
        case .willow:
            // The shibe head-cock: the meme made live, plus the smile.
            pose.headTilt = 0.34 - 0.1 * settle
            pose.mouth = .ws
            pose.cheekGlow = 0.7
            pose.earL = 0.75
            pose.earR = 0.45
        case .compass:
            // Butt-wiggle: the corgi loaf telegraphs a pounce it never makes.
            pose.bodyScaleX = 1.07
            pose.bodyScaleY = 0.95
            pose.bodyOffsetX = 8 * settle
            pose.earL = 1        // airplane ears, asymmetric
            pose.earR = -0.35
            pose.tailLift = 0.55
            pose.wag = 1
            pose.mouth = .ws
        case .prism:
            // Ear-twitch inspection + the kneading press.
            pose.earL = 1
            pose.earR = 1 - 1.6 * settle
            pose.bodyScaleY = 0.97
            pose.bodyScaleX = 1.04
            pose.pupilDilate = 0.8
            pose.headTurn = 0.25
        case .nimbus:
            // The wing-flip loop + a chirp.
            pose.wing = 0.85
            pose.mouth = .o
            pose.headTilt = -0.12
            pose.tailLift = 0.4
            props.songNotes = true
        case .lumen:
            // The shimmer: wings lift, the glow swells (the night tell).
            pose.wing = 0.8
            pose.catchGlow = 1
            pose.pupilDilate = 0.8
            pose.mouth = .smile
        }
        _ = settle
    }

}
