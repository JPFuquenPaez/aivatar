import Foundation

/// Procedural gesture clips (§6/§7). One shared clip library across all five
/// archetypes; personality comes from pool weights, amplitude, tempo and
/// overshoot dials. Each clip is a pure function of phase u (0...1).
nonisolated enum GestureClipLibrary {
    /// Base duration of the action phase, seconds (before tempo scaling).
    private static func baseDuration(_ clip: GestureClip) -> Float {
        switch clip {
        case .wave: return 1.6
        case .bounce: return 1.2
        case .stretch: return 1.6
        case .spin: return 1.8
        case .nod: return 1.2
        case .tilt: return 1.4
        case .lookAround: return 1.8
        case .shiftWeight: return 1.6
        case .shiver: return 0.7
        case .doubleTake: return 1.5
        case .sparkle: return 1.0
        case .puff: return 1.4
        // v5b quirk clips — the unique per-archetype signatures.
        case .preen: return 1.8
        case .swayCatch: return 2.8
        case .tick: return 0.9
        case .mirror: return 2.4
        case .driftFloat: return 3.4
        }
    }

    static func durationFrames(_ clip: GestureClip, profile: PersonalityProfile) -> Int {
        let seconds = baseDuration(clip) / max(0.5, profile.motionProfile.tempoScale)
        return max(6, Int(seconds * 30))
    }

    /// Anticipation frames before large motions (§7: >= 120 ms), scaled by
    /// the v3 grammar dial: Ember winds up big, Willow blooms instead (the
    /// floor keeps the plan's 120 ms on big clips), Compass stays minimal.
    /// Startle-class clips (shiver) always get a 250 ms pre-cue — a startle
    /// without a pre-cue reads as a jump-scare (v3 audit finding 6).
    static func anticipationFrames(_ clip: GestureClip, profile: PersonalityProfile) -> Int {
        if clip == .shiver { return 8 }
        guard clip.isBig else { return 0 }
        let dial = profile.motionGrammar.map { 0.4 + 0.6 * $0.anticipation } ?? 1.0
        return max(4, Int(6 * dial))
    }

    /// Ease-in-out (12 principles: eased arcs).
    static func easeInOut(_ u: Float) -> Float {
        u * u * (3 - 2 * u)
    }

    /// Writes the clip's additive contribution. `u` is the action phase 0...1,
    /// `a` the anticipation phase 0...1 (big clips), `w` the crossfade weight.
    static func apply(
        _ clip: GestureClip,
        u: Float,
        anticipation a: Float,
        weight w: Float,
        profile: PersonalityProfile,
        bones: BoneMap,
        pose: inout AvatarPose,
        expressions: inout [Float]
    ) {
        let amp = profile.motionProfile.amplitudeScale
        let over = profile.motionProfile.overshoot

        // Anticipation: small counter-motion before the action (>= 120 ms).
        if a > 0 {
            let pre = sin(a * Float.pi) * 0.35
            switch clip {
            case .bounce: pose.offsetsY[bones.hips] += 3 * pre
            case .spin: pose.rotations[bones.hips] += -0.12 * pre
            case .stretch: pose.rotations[bones.spineUpper] -= 0.08 * pre
            case .puff: pose.scalesX[bones.chest] -= 0.06 * pre
            case .shiver:
                // Startle pre-cue (250 ms): a tiny stiffen — the body braces
                // before the flinch so it reads as sensitive, not jump-scare.
                pose.offsetsY[bones.head] -= 0.8 * pre
                pose.scalesY[bones.head] += 0.04 * pre
                expressions[ExpressionChannel.alert.rawValue] = max(
                    expressions[ExpressionChannel.alert.rawValue], pre * 0.3
                )
            default: break
            }
        }

        let e = easeInOut(u)
        let arc = sin(u * Float.pi) // one hump, 0 -> 1 -> 0

        switch clip {
        case .wave:
            // v3 species greeting (U1/U5: no pseudo-limbs — a limb emerging
            // from a limbless body is a realism inconsistency). The wave is
            // now a whole-body lean-and-bob: the body tilts toward the
            // viewer, bobs once on a springy arc, and rights itself by
            // u = 1 so the end-of-clip crossfade has no offset to unwind.
            let lean = easeInOut(min(max((u - 0.2) / 0.35, 0), 1))
                * (1 - easeInOut(min(max((u - 0.6) / 0.3, 0), 1)))
            pose.rotations[bones.spineUpper] += 0.10 * lean * w * amp
            pose.rotations[bones.head] += 0.14 * lean * w * amp
            pose.offsetsY[bones.hips] += 2.5 * sin(u * Float.pi) * w * amp
            pose.scalesX[bones.chest] += 0.06 * sin(u * Float.pi) * w
            expressions[ExpressionChannel.warm.rawValue] = max(expressions[ExpressionChannel.warm.rawValue], arc * 0.6 * w)

        case .bounce:
            // Squash & stretch on landing (§7).
            let hump = abs(sin(u * Float.pi * 2))
            pose.offsetsY[bones.hips] += 7 * hump * w * amp
            let squash = pow(abs(sin(u * Float.pi * 2 - 0.4)), 6)
            pose.scalesX[bones.hips] += 0.12 * squash * w * amp
            pose.scalesY[bones.hips] -= 0.12 * squash * w * amp
            pose.scalesX[bones.head] += 0.04 * hump * w
            pose.rotations[bones.appendageB] += arc * 0.25 * w * amp

        case .stretch:
            // Whole-body lengthen upward with overshoot settle (v3: the
            // puff masses stretch tall, no arms — U1/U5).
            let reach = e * (1 + over * arc)
            pose.rotations[bones.spineUpper] -= 0.14 * reach * w
            pose.rotations[bones.spineLower] -= 0.06 * reach * w
            pose.scalesY[bones.neck] += 0.15 * reach * w
            pose.scalesY[bones.chest] += 0.10 * reach * w
            pose.scalesX[bones.chest] -= 0.06 * reach * w
            pose.offsetsY[bones.hips] += 2 * reach * w
            expressions[ExpressionChannel.joy.rawValue] = max(expressions[ExpressionChannel.joy.rawValue], arc * 0.5 * w)

        case .spin:
            // Full 2*pi turn completes by u = 0.9; overshoot settles back to
            // exactly 2*pi (== neutral) by u = 1. The end pose is visually
            // identical to the start pose, so the wrap to 0 at clip end is
            // seamless (§11); the crossfade holds weight 1 (endsWrapped).
            let turn = 2 * Float.pi * easeInOut(min(u / 0.9, 1))
            let settle = u > 0.9 ? sin((u - 0.9) / 0.1 * Float.pi) * over : 0
            pose.rotations[bones.hips] += (turn + settle) * w
            expressions[ExpressionChannel.wry.rawValue] = max(expressions[ExpressionChannel.wry.rawValue], arc * 0.4 * w)

        case .nod:
            // Two gentle head nods (Willow's frequent small nod signature).
            pose.rotations[bones.head] += sin(u * Float.pi * 4) * 0.10 * w * amp
            pose.offsetsY[bones.head] += sin(u * Float.pi * 4) * 0.8 * w

        case .tilt:
            pose.rotations[bones.head] += 0.18 * (e - 0.5) * 2 * w * amp
            pose.rotations[bones.neck] += 0.06 * (e - 0.5) * 2 * w

        case .lookAround:
            pose.rotations[bones.head] += sin(u * Float.pi * 2) * 0.22 * w
            pose.rotations[bones.neck] += sin(u * Float.pi * 2 - 0.5) * 0.10 * w
            pose.offsetsX[bones.pupilL] += sin(u * Float.pi * 2) * 2.5 * w
            pose.offsetsX[bones.pupilR] += sin(u * Float.pi * 2) * 2.5 * w
            expressions[ExpressionChannel.focus.rawValue] = max(expressions[ExpressionChannel.focus.rawValue], 0.35 * w)

        case .shiftWeight:
            pose.offsetsX[bones.hips] += 4 * (e - 0.5) * w * amp
            pose.rotations[bones.spineLower] += 0.05 * (e - 0.5) * w
            pose.rotations[bones.appendageB] += (e - 0.5) * 0.5 * w * amp
            pose.rotations[bones.appendageB2] += (e - 0.5) * 0.7 * w * amp

        case .shiver:
            // Nimbus micro-startle: fast, small, dies out.
            let decay = 1 - u * 0.7
            pose.rotations[bones.chest] += sin(u * 60) * 0.015 * w * decay
            pose.offsetsX[bones.head] += sin(u * 60 + 1) * 0.5 * w * decay
            expressions[ExpressionChannel.startle.rawValue] = max(
                expressions[ExpressionChannel.startle.rawValue], arc * 0.5 * w * decay
            )

        case .doubleTake:
            // Prism: glance away, snap back, pause, re-glance.
            if u < 0.3 {
                pose.rotations[bones.head] += -0.30 * easeInOut(u / 0.3) * w
            } else if u < 0.45 {
                pose.rotations[bones.head] += -0.30 * (1 - easeInOut((u - 0.3) / 0.15)) * w
            } else if u > 0.7 {
                pose.rotations[bones.head] += -0.15 * easeInOut((u - 0.7) / 0.3) * w
            }
            expressions[ExpressionChannel.surprise.rawValue] = max(expressions[ExpressionChannel.surprise.rawValue], arc * 0.5 * w)

        case .sparkle:
            // Joy pulse: eyes widen, pupils dilate, mouth lifts.
            expressions[ExpressionChannel.joy.rawValue] = max(expressions[ExpressionChannel.joy.rawValue], arc * 0.9 * w)
            pose.scalesX[bones.pupilL] += 0.5 * arc * w
            pose.scalesX[bones.pupilR] += 0.5 * arc * w
            pose.offsetsY[bones.browL] -= 1.5 * arc * w
            pose.offsetsY[bones.browR] -= 1.5 * arc * w

        case .puff:
            // Chest balloons with overshoot settle.
            let swell = e * (1 + over * arc)
            pose.scalesX[bones.chest] += 0.22 * swell * w
            pose.scalesY[bones.chest] += 0.18 * swell * w
            expressions[ExpressionChannel.alert.rawValue] = max(expressions[ExpressionChannel.alert.rawValue], arc * 0.4 * w)

        // MARK: - v5b quirk clips (one per archetype, owner-only weights)

        case .preen:
            // EMBER — the preen: dips its head and gives itself two quick
            // pat pulses (head scale), then a springy hop. "Checking its
            // hair" before the curtain rises; anticipation is the stance.
            let dip = easeInOut(min(u / 0.25, 1)) * (1 - easeInOut(min(max((u - 0.35) / 0.25, 0), 1)))
            pose.rotations[bones.head] += 0.16 * dip * w * amp
            let patWindow = u > 0.10 && u < 0.70
            if patWindow {
                let pat = pow(abs(sin(u * Float.pi * 4)), 2)
                pose.scalesY[bones.head] += 0.05 * pat * w
                pose.scalesX[bones.head] += 0.03 * pat * w
            }
            if u > 0.78 {
                pose.offsetsY[bones.hips] += 3.0 * sin((u - 0.78) / 0.22 * Float.pi) * w * amp
            }
            expressions[ExpressionChannel.joy.rawValue] = max(expressions[ExpressionChannel.joy.rawValue], arc * 0.5 * w)

        case .swayCatch:
            // WILLOW — the leaf-catch: one slow full-body sway with the
            // head LAGGING the spine (vegetation, not clockwork), then a
            // quick small dip — catching a falling leaf — and a settle
            // that never fully settles (residual sway by design).
            pose.rotations[bones.spineUpper] += 0.09 * sin(u * Float.pi * 2) * w
            pose.rotations[bones.head] += 0.07 * sin(u * Float.pi * 2 - 0.9) * w
            pose.rotations[bones.appendageB] += 0.12 * sin(u * Float.pi * 2 - 1.4) * w
            if u > 0.55 && u < 0.80 {
                let catchPulse = sin((u - 0.55) / 0.25 * Float.pi)
                pose.offsetsY[bones.head] -= 1.4 * catchPulse * w
                pose.rotations[bones.neck] += 0.08 * catchPulse * w
            }
            expressions[ExpressionChannel.warm.rawValue] = max(expressions[ExpressionChannel.warm.rawValue], 0.4 * w)

        case .tick:
            // COMPASS — the tick: ONE exact metronome bob. Single hump,
            // zero overshoot, posture stays level, returns to EXACTLY
            // neutral by u = 1 (sin(pi) leaves a float residue — clamp it;
            // one pixel of imprecision destroys the tell, §1 Compass).
            let hump: Float = u >= 1 ? 0 : sin(u * Float.pi)
            pose.offsetsY[bones.hips] += 2.0 * hump * w
            pose.rotations[bones.spineUpper] -= 0.03 * hump * w
            expressions[ExpressionChannel.focus.rawValue] = max(expressions[ExpressionChannel.focus.rawValue], hump * 0.35 * w)

        case .mirror:
            // PRISM — the mirror moment: freezes, tilts slowly left to
            // study itself, holds, then a quick flip tilt right with a
            // small head-scale study pulse — it just changed a color.
            if u < 0.3 {
                pose.rotations[bones.head] -= 0.20 * easeInOut(u / 0.3) * w
            } else if u < 0.55 {
                pose.rotations[bones.head] -= 0.20 * w
            } else if u < 0.68 {
                pose.rotations[bones.head] += (-0.20 + 0.45 * easeInOut((u - 0.55) / 0.13)) * w
                pose.scalesX[bones.head] += 0.03 * sin((u - 0.55) / 0.13 * Float.pi) * w
            } else {
                pose.rotations[bones.head] += 0.25 * (1 - easeInOut((u - 0.68) / 0.32)) * w
            }
            expressions[ExpressionChannel.wry.rawValue] = max(expressions[ExpressionChannel.wry.rawValue], 0.3 * w)
            if u > 0.55 {
                expressions[ExpressionChannel.surprise.rawValue] = max(
                    expressions[ExpressionChannel.surprise.rawValue],
                    sin((u - 0.55) / 0.45 * Float.pi) * 0.5 * w
                )
            }

        case .driftFloat:
            // NIMBUS — the float wander: two-frequency drift (lateral
            // sway + faster small vertical bob) with a gentle chest
            // breathing swell. Calm weather made visible.
            pose.offsetsX[bones.hips] += 3.0 * sin(u * Float.pi * 2) * w
            pose.offsetsY[bones.hips] += 1.5 * sin(u * Float.pi * 4 + 0.7) * w
            pose.scalesX[bones.chest] += 0.03 * sin(u * Float.pi * 2) * w
            pose.rotations[bones.appendageB] += 0.10 * sin(u * Float.pi * 2 - 0.5) * w
            expressions[ExpressionChannel.warm.rawValue] = max(expressions[ExpressionChannel.warm.rawValue], 0.3 * w)
        }
    }
}
