import Foundation

/// L0 — Posture (§7).
///
/// Base pose + posture lean on the spine chain, blended toward "upright" vs
/// "relaxed" targets from the trait vector: conscientiousness pulls the chain
/// upright, neuroticism (sensitivity) pulls it softly inward, extraversion
/// opens the shoulders. Statelessly writes absolute values every frame.
nonisolated struct PostureLayer: Sendable {
    private let spineLean: Float
    private let headCarry: Float
    private let shoulderOpen: Float
    private let uprightness: Float
    /// Gentle constant head tilt: high agreeableness with low extraversion
    /// reads as soft/attentive (Willow's "slight head tilt", §5).
    private let headTilt: Float

    init(profile: PersonalityProfile) {
        let t = profile.traitVector
        uprightness = 0.4 + t.conscientiousness * 0.6 - t.neuroticism * 0.25
        spineLean = (1 - uprightness) * 0.09
        headCarry = (1 - uprightness) * 0.05
        shoulderOpen = 0.05 + t.extraversion * 0.10
        headTilt = max(0, t.agreeableness - t.extraversion) * 0.12
    }

    /// Writes the posture baseline into `pose` (absolute, not additive).
    func apply(to pose: inout AvatarPose, bones: BoneMap) {
        let lean = spineLean
        pose.rotations[bones.spineLower] = lean * 0.6
        pose.rotations[bones.spineUpper] = lean
        pose.rotations[bones.neck] = -lean * 0.4
        pose.rotations[bones.head] = -lean * 0.3 + headCarry + headTilt
        pose.rotations[bones.shoulderL] = -shoulderOpen
        pose.rotations[bones.shoulderR] = shoulderOpen
        pose.offsetsX[bones.hips] = 0
    }
}
