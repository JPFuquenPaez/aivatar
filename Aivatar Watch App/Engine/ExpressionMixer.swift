import Foundation

/// Expression mixer (§6): each of the 10 facial expression channels is a 1D
/// curve mixing brow position, lid openness, mouth shape and pupil size.
/// Channel weights are blended, never hard-swapped, so Phase C can crossfade
/// expressions at any weight. Pure function of the channel weights.
nonisolated enum ExpressionMixer {
    /// Result written into face-bone deltas on top of what other layers set.
    static func apply(
        expressions: [Float],
        bones: BoneMap,
        pose: inout AvatarPose
    ) {
        func w(_ c: ExpressionChannel) -> Float {
            min(max(expressions[c.rawValue], 0), 1)
        }

        let joy = w(.joy)
        let sad = w(.sad)
        let surprise = w(.surprise)
        let alert = w(.alert)
        let sleepy = w(.sleepy)
        let focus = w(.focus)
        let warm = w(.warm)
        let wry = w(.wry)
        let startle = w(.startle)
        let rest = w(.rest)

        // --- Brows: raise (joy/surprise/warm), knit (sad/focus), alert high.
        let browRaise = joy * 2.0 + surprise * 3.0 + warm * 1.5 + alert * 1.8 + startle * 2.5
        let browKnit = sad * 1.2 + focus * 1.0 + sleepy * 1.5
        let browTilt = wry * 1.2 // asymmetric: only left brow lifts
        pose.offsetsY[bones.browL] -= browRaise - browKnit - browTilt
        pose.offsetsY[bones.browR] -= browRaise - browKnit
        pose.rotations[bones.browL] += wry * 0.25
        pose.rotations[bones.browR] -= sad * 0.15

        // --- Lids: openness above the blink state; sleepy/rest close.
        // v6 happy squint: joy CLOSES the lids from the top (~3.2 units of
        // the 6-unit lid = a ^-^ arc over the pupils at pixel scale) —
        // pixel-mascot happy eyes are a squint, not a wide stare.
        let lidClose = sleepy * 4.5 + rest * 6.0 + focus * 0.8 - surprise * 1.2 - alert * 1.0 + joy * 3.2
        let lid = max(0, min(6, lidClose))
        pose.offsetsY[bones.lidL] += lid
        pose.offsetsY[bones.lidR] += lid

        // --- Pupils: dilate on startle/surprise/joy, constrict on focus.
        let pupilScale = 1 + startle * 0.5 + surprise * 0.35 + joy * 0.2 - focus * 0.25 - sleepy * 0.2
        pose.scalesX[bones.pupilL] *= pupilScale
        pose.scalesX[bones.pupilR] *= pupilScale
        pose.scalesY[bones.pupilL] *= pupilScale
        pose.scalesY[bones.pupilR] *= pupilScale

        // --- Mouth: joy lifts and widens, sad pulls down, surprise opens,
        //     rest is a small flat line, wry is asymmetric.
        let mouthLift = joy * 1.8 + warm * 1.2 - sad * 1.6 + wry * 0.8 - rest * 1.0
        let mouthOpen = surprise * 1.2 + startle * 0.8 + alert * 0.4
        pose.offsetsY[bones.mouth] -= mouthLift - mouthOpen
        pose.scalesX[bones.mouth] *= 1 + joy * 0.4 + surprise * 0.3 - rest * 0.2
        pose.scalesY[bones.mouth] *= 1 + mouthOpen * 1.5 - sad * 0.3
        pose.rotations[bones.mouth] += wry * 0.12 - sad * 0.05

        // --- Jaw slack on surprise/sleepy.
        pose.offsetsY[bones.jaw] += surprise * 1.5 + sleepy * 0.8
    }
}
