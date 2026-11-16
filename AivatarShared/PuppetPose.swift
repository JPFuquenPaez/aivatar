import Foundation
import CoreGraphics

/// PuppetPose (v3): the truth layer the director's semantic states resolve
/// into — a Codable snapshot of every part channel (doc §5.5: "the truth
/// layer is the parameter set... golden tests pin parameter snapshots").
/// All values are in author space or normalized -1...1; the renderer owns
/// display-time spring interpolation BETWEEN these targets.
nonisolated struct PuppetPose: Codable, Sendable, Equatable {
    // Root / body
    var bodyScaleX: CGFloat = 1
    var bodyScaleY: CGFloat = 1
    var bodyOffsetX: CGFloat = 0
    var bodyOffsetY: CGFloat = 0
    /// Whole-figure lean (radians, + = clockwise).
    var lean: CGFloat = 0
    /// A vertical lift of the whole figure (positive = up; author units).
    var hop: CGFloat = 0

    // Head
    var headTilt: CGFloat = 0        // radians, + = clockwise
    var headTurn: CGFloat = 0        // -1 ... 1 (left ... right)
    var headNod: CGFloat = 0         // -1 (up) ... 1 (down chin tuck)
    var headOffsetX: CGFloat = 0
    var headOffsetY: CGFloat = 0

    // Face
    /// Lid open amount (1 = fully open, 0 = closed).
    var lidOpen: CGFloat = 1
    /// Droopy heavy lids (sleep) layered on lidOpen.
    var lidSoft: CGFloat = 0
    var pupilX: CGFloat = 0          // -1 ... 1 within the glance window
    var pupilY: CGFloat = 0          // -1 (up at the user) ... 1 (down)
    var pupilDilate: CGFloat = 0.55
    var catchGlow: CGFloat = 0        // catchlight/sparkle intensity boost
    var cheekGlow: CGFloat = 0       // blush opacity multiplier 0...1
    var mouth: MouthState = .rest

    // Ears / tail / wings
    var earL: CGFloat = 0            // -1 droop ... 1 perk
    var earR: CGFloat = 0
    var tailLift: CGFloat = 0        // radians raise
    var tailAngle: CGFloat = 0       // radians swing offset
    var wag: CGFloat = 0             // 0...1 flutter intensity (ambient adds sway)
    var wing: CGFloat = 0            // 0...1 flap/lift

    nonisolated enum MouthState: String, Codable, Sendable, Equatable {
        case rest     // tiny line, content
        case ws       // the contentment W
        case o        // the surprise O / bird beak-open chatter
        case yawn     // big open
        case smile    // gentle raised curve
    }

    /// A quantized fingerprint of the pose — the draw-skip key and the
    /// golden hash input. Channels quantize at 1/256 so a spring mid-step
    /// never spuriously pins, and the face vocabulary (mouth) joins solid.
    nonisolated func fingerprint() -> String {
        func q(_ v: CGFloat) -> Int { Int((v * 256).rounded()) }
        let parts: [String] = [
            q(bodyScaleX), q(bodyScaleY), q(bodyOffsetX), q(bodyOffsetY),
            q(lean), q(hop), q(headTilt), q(headTurn), q(headNod),
            q(headOffsetX), q(headOffsetY), q(lidOpen), q(lidSoft),
            q(pupilX), q(pupilY), q(pupilDilate), q(catchGlow), q(cheekGlow),
            q(earL), q(earR),
        ].map { String($0) } + [
            mouth.rawValue,
            String(q(tailLift)), String(q(tailAngle)), String(q(wag)), String(q(wing)),
        ]
        return parts.joined(separator: ".")
    }

    /// FNV-1a of the fingerprint — the deterministic golden pin for a pose.
    nonisolated func hashValue64() -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in fingerprint().utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return h
    }
}

/// PuppetProps (v3): everything that rides AROUND the puppet rather than
/// deforming it — memory-made-visible traces (the interiority grammar),
/// transient tells (vapor, motes, songburst notes), and the greeting's
/// weather ceremony. Pure, Equatable, Cod-free (never persisted).
nonisolated struct PuppetProps: Sendable, Equatable {
    /// Willow's tended sprout on the head (sproutGrowth >= 0.6).
    var sprout = false
    /// Compass's audit week: lit days in accent, pending in ink.
    var weekLit = 0
    var weekTotal = 0
    /// Prism's found trinket beside the body.
    var trinket = false
    /// The confidant memento disc (alpha 0...1 while depositing; steady 1).
    var mementoAlpha: Double = 0
    /// Cold-breath vapor puff above the face.
    var vapor = false
    /// The self-play mote the companion chases (normalized stage space).
    var moteX: Double? = nil
    var moteY: Double? = nil
    /// Nimbus's songburst accent notes.
    var songNotes = false
    /// Greeting weather ceremony.
    var umbrellaLeaf = false
    var frostSparkle = false
    var sunnyBurst = false

    nonisolated var isEmpty: Bool {
        self == PuppetProps()
    }
}

/// Which style a surface renders the puppet in (doc §5.8): the watch stage
/// stays flat (OLED discipline), the iPhone card and postcard fronts go
/// claymorphic (gradients + soft shadow — the same character, richer
/// render), and complications use the simplified head-only icon cut.
nonisolated enum PuppetStyle: Sendable, Equatable {
    case flat
    case clay
    case icon
    /// Flat at the rest-LOD dim tokens (Always On).
    case rest
}
