import Foundation

/// Cached indices for every named bone the engine writes to (§6 hierarchy).
/// Built once at engine init; indices are validated to exist in the rig.
nonisolated struct BoneMap: Sendable {
    let root: Int
    let hips: Int
    let spineLower: Int
    let spineUpper: Int
    let chest: Int
    let neck: Int
    let head: Int
    let jaw: Int
    let browL: Int
    let browR: Int
    let lidL: Int
    let lidR: Int
    let pupilL: Int
    let pupilR: Int
    let mouth: Int
    let shoulderL: Int
    let shoulderR: Int
    let upperArmL: Int
    let upperArmR: Int
    let forearmL: Int
    let forearmR: Int
    let handL: Int
    let handR: Int
    let appendageA: Int
    let appendageA2: Int
    let appendageB: Int
    let appendageB2: Int

    init(skeleton: Skeleton) {
        func idx(_ name: String) -> Int {
            guard let i = skeleton.boneIndex(name) else {
                fatalError("rig.json is missing required bone \(name)")
            }
            return i
        }
        root = idx("root")
        hips = idx("hips")
        spineLower = idx("spineLower")
        spineUpper = idx("spineUpper")
        chest = idx("chest")
        neck = idx("neck")
        head = idx("head")
        jaw = idx("jaw")
        browL = idx("browL")
        browR = idx("browR")
        lidL = idx("lidL")
        lidR = idx("lidR")
        pupilL = idx("pupilL")
        pupilR = idx("pupilR")
        mouth = idx("mouth")
        shoulderL = idx("shoulderL")
        shoulderR = idx("shoulderR")
        upperArmL = idx("upperArmL")
        upperArmR = idx("upperArmR")
        forearmL = idx("forearmL")
        forearmR = idx("forearmR")
        handL = idx("handL")
        handR = idx("handR")
        appendageA = idx("appendageA")
        appendageA2 = idx("appendageA2")
        appendageB = idx("appendageB")
        appendageB2 = idx("appendageB2")
    }
}
