import Foundation

/// A0 spike motion: a deterministic procedural wiggle over the shared skeleton.
/// Not the L0-L2 engine (that lands in A2); it exists so both renderers draw
/// the same animated greybox for the frame-time measurement.
nonisolated struct GreyboxMotion: Sendable {
    let skeleton: Skeleton
    let seed: UInt64

    /// Amplitudes drawn once from the seed so runs are comparable but organic.
    private let swayAmp: Float
    private let bobAmp: Float
    private let armAmp: Float
    private let appendageAmp: Float
    private let breatheAmp: Float

    init(skeleton: Skeleton, seed: UInt64) {
        self.skeleton = skeleton
        self.seed = seed
        var rng = SeededRandom(seed)
        swayAmp = 0.02 + rng.nextFloat() * 0.02
        bobAmp = 1.5 + rng.nextFloat() * 1.0
        armAmp = 0.06 + rng.nextFloat() * 0.04
        appendageAmp = 0.12 + rng.nextFloat() * 0.06
        breatheAmp = 0.03 + rng.nextFloat() * 0.02
    }

    /// Mutates `pose` in place for `frame`. Pure function of (seed, frame).
    func update(pose: inout AvatarPose, frame: Int) {
        pose.resetToNeutral()
        let t = Float(frame) / 30.0

        guard
            let hips = skeleton.boneIndex("hips"),
            let spineLower = skeleton.boneIndex("spineLower"),
            let spineUpper = skeleton.boneIndex("spineUpper"),
            let chest = skeleton.boneIndex("chest"),
            let neck = skeleton.boneIndex("neck"),
            let head = skeleton.boneIndex("head"),
            let jaw = skeleton.boneIndex("jaw"),
            let upperArmL = skeleton.boneIndex("upperArmL"),
            let upperArmR = skeleton.boneIndex("upperArmR"),
            let forearmL = skeleton.boneIndex("forearmL"),
            let forearmR = skeleton.boneIndex("forearmR"),
            let appendageA = skeleton.boneIndex("appendageA"),
            let appendageA2 = skeleton.boneIndex("appendageA2"),
            let appendageB = skeleton.boneIndex("appendageB"),
            let appendageB2 = skeleton.boneIndex("appendageB2"),
            let lidL = skeleton.boneIndex("lidL"),
            let lidR = skeleton.boneIndex("lidR"),
            let pupilL = skeleton.boneIndex("pupilL"),
            let pupilR = skeleton.boneIndex("pupilR")
        else { return }

        // L1-like: breathing + sway + bob.
        pose.rotations[hips] = sin(t * 0.6) * swayAmp
        pose.rotations[spineLower] = sin(t * 0.6 + 0.4) * swayAmp * 0.7
        pose.rotations[spineUpper] = sin(t * 0.6 + 0.8) * swayAmp * 0.5
        let breathe = (sin(t * 2.0 * .pi * 0.33) + 1) * 0.5
        pose.scalesX[chest] = 1 + breathe * breatheAmp
        pose.scalesY[chest] = 1 - breathe * breatheAmp * 0.5
        pose.offsetsY[hips] = sin(t * 1.7) * bobAmp

        // Head look-around with micro-tilt.
        pose.rotations[neck] = sin(t * 0.9 + 1.2) * 0.03
        pose.rotations[head] = sin(t * 0.45) * 0.18
        pose.rotations[jaw] = sin(t * 3.1) * 0.03

        // Arm swing (mirrored, slightly out of phase).
        pose.rotations[upperArmL] = sin(t * 1.1) * armAmp
        pose.rotations[upperArmR] = sin(t * 1.1 + 0.5) * armAmp
        pose.rotations[forearmL] = sin(t * 1.3 + 1.0) * armAmp * 1.5
        pose.rotations[forearmR] = sin(t * 1.3 + 1.4) * armAmp * 1.5

        // Appendage follow-through (lagged springs, crude for spike).
        pose.rotations[appendageA] = sin(t * 2.2 + 0.3) * appendageAmp
        pose.rotations[appendageA2] = sin(t * 2.2 + 0.9) * appendageAmp * 1.4
        pose.rotations[appendageB] = sin(t * 1.9 + 0.7) * appendageAmp
        pose.rotations[appendageB2] = sin(t * 1.9 + 1.4) * appendageAmp * 1.2

        // Gaze wander + deterministic blink on a 90-frame cycle.
        let wander = sin(t * 0.7) * 3.0
        pose.offsetsX[pupilL] = wander
        pose.offsetsX[pupilR] = wander
        let blinkPhase = frame % 90
        let lidClose: Float = (blinkPhase == 0 || blinkPhase == 1) ? 5.0 : 0.0
        pose.offsetsY[lidL] = lidClose
        pose.offsetsY[lidR] = lidClose
    }
}
