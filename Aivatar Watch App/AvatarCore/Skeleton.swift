import Foundation

/// Runtime skeleton: the shared bone hierarchy from `rig.json` plus a
/// parents-first ordering so forward kinematics is a single linear pass.
nonisolated struct Skeleton: Sendable {
    let document: RigDocument

    /// Bones reordered so every parent precedes its children.
    let bones: [RigDocument.Bone]
    /// Index into `bones` for the parent (-1 = root).
    let parentIndices: [Int]
    /// Bone name -> index into `bones`.
    let indexByName: [String: Int]

    init(document: RigDocument) throws {
        self.document = document

        var bones: [RigDocument.Bone] = []
        bones.reserveCapacity(document.bones.count)
        var parentIndices: [Int] = []
        parentIndices.reserveCapacity(document.bones.count)
        var placed: [String: Int] = [:]
        placed.reserveCapacity(document.bones.count)

        var pending = document.bones
        var madeProgress = true
        while !pending.isEmpty {
            madeProgress = false
            var remaining: [RigDocument.Bone] = []
            remaining.reserveCapacity(pending.count)
            for bone in pending {
                if let parent = bone.parent {
                    if let parentIndex = placed[parent] {
                        parentIndices.append(parentIndex)
                        placed[bone.name] = bones.count
                        bones.append(bone)
                        madeProgress = true
                    } else {
                        remaining.append(bone)
                    }
                } else {
                    parentIndices.append(-1)
                    placed[bone.name] = bones.count
                    bones.append(bone)
                    madeProgress = true
                }
            }
            guard madeProgress else {
                throw RigError.parentOrderUnsatisfiable
            }
            pending = remaining
        }

        self.bones = bones
        self.parentIndices = parentIndices
        self.indexByName = placed

        for slot in document.slots where placed[slot.bone] == nil {
            throw RigError.unknownBone(slot.bone)
        }
    }

    var boneCount: Int { bones.count }

    func boneIndex(_ name: String) -> Int? {
        indexByName[name]
    }

    /// Forward kinematics. Writes world transforms for every bone into `world`
    /// (pre-allocated by the caller; no allocation here).
    ///
    /// The pose's per-bone deltas are added to the bone rest pose; face bones
    /// (brows, lids, pupils, mouth, jaw) are sprite-driven in the renderer but
    /// still live in the FK pass so head motion carries them correctly.
    func solve(pose: AvatarPose, into world: inout [Transform2D]) {
        for i in 0..<bones.count {
            let bone = bones[i]
            let local = Transform2D.local(
                offsetX: bone.x + pose.offsetsX[i],
                offsetY: bone.y + pose.offsetsY[i],
                rotation: bone.rotation + pose.rotations[i],
                scaleX: pose.scalesX[i],
                scaleY: pose.scalesY[i]
            )
            let parentIndex = parentIndices[i]
            if parentIndex < 0 {
                world[i] = local
            } else {
                world[i] = world[parentIndex].appended(local)
            }
        }
    }
}
