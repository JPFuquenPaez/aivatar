import Foundation

/// PetMotion (v42): makes the HD pets feel ALIVE instead of a stale image
/// swapping poses. Motion is CONTINUOUS and layered, and still a pure
/// function of (frameID, frameAge, tick, seed) — the 150 ms director clock
/// and the dedicated SplitMix64 stream stay the only inputs (G7), so every
/// surface (watch stage, picker, iPhone, postcard) plays the identical life.
///
/// Two layers:
/// - `ambient(tick, seed)`: slow breathing (24-tick cycle = the 3.6 s life
///   floor), a non-commensurate sway (periods 53/71 ticks, so the loop never
///   visibly repeats), head micro-drift (value noise, seeded) and a tail wag.
/// - `act(frameID, frameAge, ...)`: the director's discrete acts become
///   ENVELOPES over several ticks — a 3-tick lid close/open for blink, a
///   damped spring for the quirk (hop + wobble + tail flick), eased
///   glance-in/out, etc. — instead of single-frame snaps.
///
/// The renderer additionally puppeteers REGIONS of the image (head bobs and
/// tilts around the neck, tail wags around its base — see
/// CompanionSprite.puppetHead/puppetTail), which is what makes the animal
/// read as a creature, not a sticker.
nonisolated enum PetMotion {

    nonisolated struct Pose: Sendable, Equatable {
        /// Whole-body transform: dx/dy in cells (dy + = up), scales, rotation
        /// in radians around the bottom-center anchor (feet on the tile).
        var dx: Double = 0
        var dy: Double = 0
        var scaleX: Double = 1
        var scaleY: Double = 1
        var rotation: Double = 0
        /// Head region: tilt in radians + bob in cells (up), around the neck.
        var headTilt: Double = 0
        var headBob: Double = 0
        /// Tail region: wag in radians around its base.
        var tailWag: Double = 0
        static let identity = Pose()
    }

    // MARK: - Ambient life (pure per tick)

    /// The always-on layer: breathing + sway + head drift + tail wag.
    /// Phases come from a dedicated stream (seed XOR private constant).
    static func ambient(_ tick: Int, seed: UInt64) -> Pose {
        var p = Pose()
        let t = Double(tick)
        var r = SeededRandom(seed ^ 0xA11C_E5EED)
        let p1 = Double(r.nextFloat()) * 2 * .pi
        let p2 = Double(r.nextFloat()) * 2 * .pi
        let p3 = Double(r.nextFloat()) * 2 * .pi
        let p4 = Double(r.nextFloat()) * 2 * .pi
        // Breathing: 24-tick cycle (3.6 s), inhale lifts and swells.
        let br = sin(2 * .pi * t / 24)
        p.scaleY = 1 + 0.030 * br
        p.scaleX = 1 - 0.010 * br
        p.dy = -0.28 * br
        p.headBob = -0.10 * br
        // Sway: periods non-commensurate with the breath cycle.
        p.rotation = 0.010 * sin(2 * .pi * t / 53 + p1)
        p.dx = 0.22 * sin(2 * .pi * t / 71 + p2)
        // Head micro-life: slow turn + seeded value noise (never still).
        p.headTilt = 0.020 * sin(2 * .pi * t / 37 + p3) + 0.030 * noise(tick, 9, seed ^ 0xCAFE_11)
        // Tail wag, slightly faster than the head.
        p.tailWag = 0.085 * sin(2 * .pi * t / 17 + p4) + 0.045 * noise(tick, 7, seed ^ 0xD06_77)
        return p
    }

    /// Smooth 1-D value noise: random targets every `period` ticks,
    /// smoothstep-interpolated. Pure function of (tick, seed).
    static func noise(_ tick: Int, _ period: Int, _ seed: UInt64) -> Double {
        let k = tick / period
        let f = Double(tick - k * period) / Double(period)
        let a = hashSigned(k, seed)
        let b = hashSigned(k + 1, seed)
        let u = f * f * (3 - 2 * f)
        return a + (b - a) * u
    }

    private static func hashSigned(_ k: Int, _ seed: UInt64) -> Double {
        var r = SeededRandom(seed ^ (UInt64(bitPattern: Int64(k)) &* 0x9E3779B97F4A7C15))
        return Double(r.nextSignedFloat())
    }

    // MARK: - Act envelopes (pure per frame age)

    /// The director's discrete act as a multi-tick envelope. `frameAge` is
    /// ticks since the frame started. Acts ease in and out — no snaps.
    static func act(_ frameID: String, _ frameAge: Int) -> Pose {
        var p = Pose()
        let k = Double(frameAge)
        func ease(_ x: Double) -> Double {
            let c = min(1, max(0, x))
            return c * c * (3 - 2 * c)
        }
        switch frameID {
        case "blink":
            // 3-tick lid close and open — a pulse, not a single squash frame.
            let e = sin(.pi * min(k, 3) / 3)
            p.scaleY = 1 - 0.12 * e
            p.headTilt = 0.025 * e
        case "quirk":
            // Damped spring: hop with a little anticipation wobble, and the
            // tail answers the hop.
            let env = exp(-k / 7)
            p.dy = -1.25 * env * sin(k * 1.9)
            p.rotation = 0.05 * exp(-k / 6) * sin(k * 2.3)
            p.tailWag = 0.28 * exp(-k / 8) * sin(k * 3.1)
            p.headTilt = -0.05 * env * sin(k * 2.1)
        case "glanceL", "glanceR":
            let sgn: Double = frameID == "glanceL" ? -1 : 1
            let e = ease(k / 4) * (k < 16 ? ease((16 - k) / 6) : 0)
            p.dx = sgn * 0.8 * e
            p.headTilt = sgn * 0.045 * e   // the head leads the glance
        case "happy":
            let e = ease(k / 3)
            p.dy = -0.3 * e
            p.scaleY = 1 + 0.035 * e
            p.headTilt = 0.05 * e
        case "perk":
            let e = ease(k / 3) * (k < 12 ? ease((12 - k) / 5) : 0)
            p.dy = -0.55 * e
            p.scaleY = 1 + 0.02 * e
        case "yawn":
            let e = ease(k / 4) * (k < 14 ? ease((14 - k) / 6) : 0)
            p.scaleY = 1 + 0.06 * e
            p.dy = -0.2 * e
        case "sleepy":
            p.scaleY = 0.96
            p.dy = 0.12   // settles down
        case "breathe":
            // The held inhale adds to the ambient breath.
            p.dy = -0.35 * ease(k / 2)
        case "idleA": p.rotation = -0.008
        case "idleB": p.rotation = 0.008
        default: break
        }
        return p
    }

    /// The full pose: ambient layer + act envelope (translations add, scales
    /// multiply, rotations add).
    static func pose(frameID: String, frameAge: Int, tick: Int, seed: UInt64) -> Pose {
        let a = ambient(tick, seed: seed)
        let b = act(frameID, frameAge)
        return Pose(dx: a.dx + b.dx, dy: a.dy + b.dy,
                    scaleX: a.scaleX * b.scaleX, scaleY: a.scaleY * b.scaleY,
                    rotation: a.rotation + b.rotation,
                    headTilt: a.headTilt + b.headTilt, headBob: a.headBob,
                    tailWag: a.tailWag + b.tailWag)
    }
}
