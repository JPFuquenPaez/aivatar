import Foundation
import CoreGraphics

/// PuppetSpring (v3): the display-time physics between director-issued pose
/// targets (doc §5.5). One critically-damped-to-slightly-underdamped spring
/// per channel class — overshoot in the 5-10% band is the juice (squash and
/// stretch replace the banned continuous image rotations), and the response
/// budget is the 12-principles timing pinned in code:
///
///   pupils               response 0.12 s, damping 0.88 (saccades are fast)
///   lids                 response 0.14 s, damping 0.85
///   face extras          response 0.20 s, damping 0.85
///   head (tilt/turn/nod)  response 0.28 s, damping 0.72
///   appendages (ears)    response 0.28 s, damping 0.68
///   body (squash/hop)    response 0.30 s, damping 0.60
///   tail                 response 0.35 s, damping 0.70
///   wag/flutter          response 0.40 s, damping 0.75
///
/// Pure integration of x'' = w^2 (xt - x) - 2 zeta w x' with
/// w = 2pi/response, semi-implicit Euler at a clamped dt with two substeps —
/// smooth at any display rate, deterministic per (target, dt) trace. Not the
/// golden layer: tests pin the TARGETS; this layer only interpolates between
/// them (its own shape is separately unit-tested).
nonisolated struct PuppetSpring: Sendable {
    var value: CGFloat
    var velocity: CGFloat

    nonisolated init(value: CGFloat) {
        self.value = value
        velocity = 0
    }

    nonisolated mutating func step(target: CGFloat, response: Double, damping: Double, dt: Double) -> CGFloat {
        var clamped = dt
        if clamped.isNaN || clamped < 0 { clamped = 0 }
        if clamped > 1.0 / 30.0 { clamped = 1.0 / 30.0 }
        let sub = clamped / 2
        let omega = 2.0 * Double.pi / max(response, 0.01)
        for _ in 0..<2 {
            let accel = omega * omega * Double(target - value) - 2.0 * damping * omega * Double(velocity)
            velocity += CGFloat(accel * sub)
            value += velocity * CGFloat(sub)
        }
        return value
    }
}

/// One spring per pose channel; steps a target pose to the live pose. The
/// channel table is index-addressed (key paths stay out of static storage).
nonisolated struct PuppetSpringBank: Sendable {
    private var springs: [PuppetSpring]

    /// The channel order (fixed): the interpolation contract.
    nonisolated static let channelCount = 24

    /// Per-channel (response, damping) — a computed function, no static
    /// storage (index-matched to channelValue()).
    nonisolated private static func budget(_ index: Int) -> (response: Double, damping: Double) {
        switch index {
        case 0, 1, 2, 3, 4: return (0.30, 0.60)   // body scales/offsets/lean
        case 5: return (0.25, 0.55)               // hop (the springiest)
        case 6, 7, 8, 9, 10: return (0.28, 0.72)  // head
        case 11: return (0.14, 0.85)              // lids
        case 12: return (0.20, 0.90)             // lid droop
        case 13, 14: return (0.12, 0.88)         // pupils (saccades)
        case 15: return (0.20, 0.85)              // dilation
        case 16: return (0.24, 0.80)             // cheeks
        case 17, 18: return (0.28, 0.68)          // ears
        case 19, 20: return (0.35, 0.70)          // tail
        case 21: return (0.40, 0.75)              // wag
        case 22, 23: return (0.35, 0.70)          // wings, catchlight glow
        default: return (0.30, 0.70)
        }
    }

    nonisolated init(pose: PuppetPose = PuppetPose()) {
        var bank: [PuppetSpring] = []
        for index in 0..<Self.channelCount {
            bank.append(PuppetSpring(value: Self.channelValue(pose, index)))
        }
        springs = bank
    }

    /// Reads channel `index` from a pose (fixed order — see budgets).
    nonisolated private static func channelValue(_ pose: PuppetPose, _ index: Int) -> CGFloat {
        switch index {
        case 0: return pose.bodyScaleX
        case 1: return pose.bodyScaleY
        case 2: return pose.bodyOffsetX
        case 3: return pose.bodyOffsetY
        case 4: return pose.lean
        case 5: return pose.hop
        case 6: return pose.headTilt
        case 7: return pose.headTurn
        case 8: return pose.headNod
        case 9: return pose.headOffsetX
        case 10: return pose.headOffsetY
        case 11: return pose.lidOpen
        case 12: return pose.lidSoft
        case 13: return pose.pupilX
        case 14: return pose.pupilY
        case 15: return pose.pupilDilate
        case 16: return pose.cheekGlow
        case 17: return pose.earL
        case 18: return pose.earR
        case 19: return pose.tailLift
        case 20: return pose.tailAngle
        case 21: return pose.wag
        case 22: return pose.wing
        case 23: return pose.catchGlow
        default: return 0
        }
    }

    /// Writes channel `index` into a pose (fixed order — see budgets).
    nonisolated private static func setChannel(_ pose: inout PuppetPose, _ index: Int, _ value: CGFloat) {
        switch index {
        case 0: pose.bodyScaleX = value
        case 1: pose.bodyScaleY = value
        case 2: pose.bodyOffsetX = value
        case 3: pose.bodyOffsetY = value
        case 4: pose.lean = value
        case 5: pose.hop = value
        case 6: pose.headTilt = value
        case 7: pose.headTurn = value
        case 8: pose.headNod = value
        case 9: pose.headOffsetX = value
        case 10: pose.headOffsetY = value
        case 11: pose.lidOpen = value
        case 12: pose.lidSoft = value
        case 13: pose.pupilX = value
        case 14: pose.pupilY = value
        case 15: pose.pupilDilate = value
        case 16: pose.cheekGlow = value
        case 17: pose.earL = value
        case 18: pose.earR = value
        case 19: pose.tailLift = value
        case 20: pose.tailAngle = value
        case 21: pose.wag = value
        case 22: pose.wing = value
        case 23: pose.catchGlow = value
        default: break
        }
    }

    /// Steps every channel toward `target`; returns the live pose.
    /// Discrete inputs (the mouth vocabulary) pass through un-sprung.
    nonisolated mutating func interpolate(target: PuppetPose, dt: Double) -> PuppetPose {
        var out = target
        for index in 0..<Self.channelCount {
            let budget = Self.budget(index)
            var spring = springs[index]
            _ = spring.step(target: Self.channelValue(target, index),
                             response: budget.response,
                             damping: budget.damping, dt: dt)
            springs[index] = spring
            var value = spring.value
            // Sanity clamps: channels never blow past their grammar ranges.
            switch index {
            case 11, 12: value = min(max(value, 0), 1)        // lids
            case 13, 14: value = min(max(value, -1), 1)      // pupils
            case 15, 16, 21, 22, 23: value = min(max(value, 0), 1.2)
            case 17, 18: value = min(max(value, -1), 1)      // ears
            default: break
            }
            Self.setChannel(&out, index, value)
        }
        return out
    }

    nonisolated mutating func reset(to pose: PuppetPose) {
        for index in springs.indices {
            springs[index].value = Self.channelValue(pose, index)
            springs[index].velocity = 0
        }
    }
}

/// PuppetAmbient (v3): the continuous life floor — pure functions of live
/// time t (seconds). This is the layer the pixel clock could never afford:
/// smooth breathing and sway instead of discrete 150 ms pose steps. Under
/// Reduce Motion (lidsOnly) every body amplitude is zero — the accessibility
/// ladder keeps the face and drops the body, exactly as before.
nonisolated enum PuppetAmbient {
    /// Breathing: body scaleY 4% at a 2.2 s cycle; the head counter-bobs at
    /// 30% amplitude with a 150 ms phase lag (follow-through).
    nonisolated static func breathe(at t: Double) -> (bodyScaleY: Double, headBobY: Double) {
        let phase = sin(2.0 * .pi * t / 2.2)
        let lagged = sin(2.0 * .pi * (t - 0.15) / 2.2)
        return (1.0 + 0.04 * phase, -3.6 * lagged)
    }

    /// Lumen's wing flutter baseline.
    nonisolated static func flutter(at t: Double) -> Double {
        0.06 + 0.05 * sin(2.0 * .pi * 4.0 * t)
    }

    /// Idle tail sway: ±8° at 0.8 Hz (species tails only).
    nonisolated static func tailSway(at t: Double) -> Double {
        8.0 * .pi / 180 * sin(2.0 * .pi * 0.8 * t)
    }

    /// Pupil micro-jitter at ~0.4 Hz: deterministic pseudo-noise (sum of
    /// sines — never RNG, never wall-clock-dependent beyond t).
    nonisolated static func pupilMicro(at t: Double) -> (x: Double, y: Double) {
        let x = 0.05 * sin(2.0 * .pi * 0.413 * t) + 0.025 * sin(2.0 * .pi * 0.771 * t + 1.3)
        let y = 0.04 * sin(2.0 * .pi * 0.397 * t + 0.7) + 0.02 * sin(2.0 * .pi * 0.819 * t + 2.1)
        return (x, y)
    }

    /// Applies the ambient layer onto the live pose (between springs and
    /// drawing). `full = true` keeps every amplitude (Reduce Motion pins
    /// the body: only tiny pupil micro survives, face-only).
    nonisolated static func apply(to pose: inout PuppetPose, at t: Double, full: Bool) {
        if !full {
            pose.pupilX += CGFloat(pupilMicro(at: t).x * 0.35)
            pose.pupilY += CGFloat(pupilMicro(at: t).y * 0.35)
            return
        }
        let breath = breathe(at: t)
        pose.bodyScaleY = CGFloat(Double(pose.bodyScaleY) * breath.bodyScaleY)
        pose.headOffsetY += CGFloat(breath.headBobY)
        pose.lean += CGFloat(0.006 * sin(2.0 * .pi * t / 6.1))
        let micro = pupilMicro(at: t)
        pose.pupilX += CGFloat(micro.x)
        pose.pupilY += CGFloat(micro.y)
    }
}
