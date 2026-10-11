import Foundation

/// The 10 facial expression channels (§6). Every channel is reachable by name
/// for Phase B reaction scripting; weights are blended, never hard-swapped.
nonisolated enum ExpressionChannel: Int, Sendable, CaseIterable, Codable {
    case joy, sad, surprise, alert, sleepy, focus, warm, wry, startle, rest

    static let count = ExpressionChannel.allCases.count
}

/// Per-frame pose value produced by the engine and consumed by the renderer.
/// A plain value type over pre-allocated buffers: the engine mutates it in
/// place every frame; nothing here allocates per frame after `init`.
nonisolated struct AvatarPose: Sendable, Equatable {
    let boneCount: Int

    /// Local rotation delta per bone, radians.
    var rotations: [Float]
    /// Local translation delta per bone (added to the rest offset), points.
    var offsetsX: [Float]
    var offsetsY: [Float]
    /// Local scale per bone (squash & stretch, §7).
    var scalesX: [Float]
    var scalesY: [Float]
    /// Expression channel weights, 0...1, indexed by `ExpressionChannel`.
    var expressionWeights: [Float]

    init(boneCount: Int) {
        self.boneCount = boneCount
        rotations = [Float](repeating: 0, count: boneCount)
        offsetsX = [Float](repeating: 0, count: boneCount)
        offsetsY = [Float](repeating: 0, count: boneCount)
        scalesX = [Float](repeating: 1, count: boneCount)
        scalesY = [Float](repeating: 1, count: boneCount)
        expressionWeights = [Float](repeating: 0, count: ExpressionChannel.count)
    }

    mutating func resetToNeutral() {
        for i in 0..<boneCount {
            rotations[i] = 0
            offsetsX[i] = 0
            offsetsY[i] = 0
            scalesX[i] = 1
            scalesY[i] = 1
        }
        for i in 0..<expressionWeights.count {
            expressionWeights[i] = 0
        }
    }

    func expression(_ channel: ExpressionChannel) -> Float {
        expressionWeights[channel.rawValue]
    }
}
