import XCTest
@testable import Aivatar_Watch_App

/// A0/A2 engine determinism tests: same seed -> same behavior (§7 hard
/// requirement for CI visual regression).
final class AvatarCoreDeterminismTests: XCTestCase {
    private func makeSkeleton() throws -> Skeleton {
        try Skeleton(document: RigDocument.load(bundle: .main))
    }

    // MARK: SeededRandom

    func testSeededRandomIsDeterministicPerSeed() {
        var a = SeededRandom(0xBEEF)
        var b = SeededRandom(0xBEEF)
        for _ in 0..<1000 {
            XCTAssertEqual(a.nextUInt64(), b.nextUInt64())
        }
    }

    func testSeededRandomDiffersAcrossSeeds() {
        var a = SeededRandom(1)
        var b = SeededRandom(2)
        var differences = 0
        for _ in 0..<100 {
            if a.nextUInt64() != b.nextUInt64() { differences += 1 }
        }
        XCTAssertGreaterThan(differences, 90)
    }

    func testSeededRandomFloatBounds() {
        var rng = SeededRandom(42)
        for _ in 0..<1000 {
            let f = rng.nextFloat()
            XCTAssertGreaterThanOrEqual(f, 0)
            XCTAssertLessThan(f, 1)
        }
    }

    // MARK: Transform2D

    func testRotationCompositionIsExactAtQuarterTurns() {
        let quarter = Transform2D.rotation(.pi / 2)
        let half = quarter.appended(quarter)
        let up = Transform2D.rotation(.pi)
        XCTAssertEqual(half.a, up.a, accuracy: 0.0001)
        XCTAssertEqual(half.b, up.b, accuracy: 0.0001)
        XCTAssertEqual(half.d, up.d, accuracy: 0.0001)
    }

    func testApplyingTranslationThenRotation() {
        // Translation applied first, then a quarter-turn (clockwise, screen space):
        // (0,0) -> (10,0) -> (0,10).
        let t = Transform2D.rotation(.pi / 2).appended(.translation(x: 10, y: 0))
        let p = t.applying(x: 0, y: 0)
        XCTAssertEqual(p.x, 0, accuracy: 0.0001)
        XCTAssertEqual(p.y, 10, accuracy: 0.0001)
    }

    // MARK: AvatarClock

    func testClockFrameIndexQuantization() {
        let clock = AvatarClock(seed: 1, frameRate: 30)
        XCTAssertEqual(clock.frameIndex(at: 0.0), 0)
        XCTAssertEqual(clock.frameIndex(at: 1.0 / 30.0), 1)
        XCTAssertEqual(clock.frameIndex(at: 1.0 / 30.0 - 0.001), 0)
        XCTAssertEqual(clock.frameIndex(at: 2.0), 60)
    }

    func testClockAdvanceIsMonotonic() {
        var clock = AvatarClock(seed: 1)
        XCTAssertFalse(clock.advance(to: 0))
        XCTAssertTrue(clock.advance(to: 5))
        XCTAssertEqual(clock.frame, 1)
        XCTAssertTrue(clock.advance(to: 5))
        XCTAssertEqual(clock.frame, 2)
    }

    // MARK: Skeleton

    func testRigLoadsAndSkeletonOrdersParentsFirst() throws {
        let skeleton = try makeSkeleton()
        XCTAssertEqual(skeleton.boneCount, skeleton.document.bones.count)
        XCTAssertEqual(skeleton.document.formatVersion, 1)
        XCTAssertNotNil(skeleton.boneIndex("root"))
        XCTAssertNotNil(skeleton.boneIndex("appendageB2"))
        for (i, bone) in skeleton.bones.enumerated() where bone.parent != nil {
            let parentIndex = skeleton.parentIndices[i]
            XCTAssertLessThan(parentIndex, i, "parent of \(bone.name) must be solved first")
        }
    }

    func testEverySlotBindsToABone() throws {
        let skeleton = try makeSkeleton()
        for slot in skeleton.document.slots {
            XCTAssertNotNil(skeleton.boneIndex(slot.bone), "slot \(slot.name) -> unknown bone \(slot.bone)")
        }
    }

    // MARK: Greybox motion + FK determinism

    func testSameSeedSamePose() throws {
        let skeleton = try makeSkeleton()
        let motionA = GreyboxMotion(skeleton: skeleton, seed: 777)
        let motionB = GreyboxMotion(skeleton: skeleton, seed: 777)

        var poseA = AvatarPose(boneCount: skeleton.boneCount)
        var poseB = AvatarPose(boneCount: skeleton.boneCount)

        for frame in stride(from: 0, to: 900, by: 7) {
            motionA.update(pose: &poseA, frame: frame)
            motionB.update(pose: &poseB, frame: frame)
            XCTAssertEqual(poseA, poseB)
        }
    }

    func testFKIsDeterministicAndHierarchical() throws {
        let skeleton = try makeSkeleton()
        let motion = GreyboxMotion(skeleton: skeleton, seed: 5)
        var pose = AvatarPose(boneCount: skeleton.boneCount)
        motion.update(pose: &pose, frame: 123)

        var world1 = [Transform2D](repeating: .identity, count: skeleton.boneCount)
        var world2 = [Transform2D](repeating: .identity, count: skeleton.boneCount)
        skeleton.solve(pose: pose, into: &world1)
        skeleton.solve(pose: pose, into: &world2)
        XCTAssertEqual(world1, world2)

        // Hips motion must propagate to the head (deep child of the chain):
        // the animated solve must differ from the neutral-pose solve.
        let head = skeleton.boneIndex("head")!
        var neutral = AvatarPose(boneCount: skeleton.boneCount)
        var worldNeutral = [Transform2D](repeating: .identity, count: skeleton.boneCount)
        skeleton.solve(pose: neutral, into: &worldNeutral)
        XCTAssertNotEqual(world1[head].tx, worldNeutral[head].tx, accuracy: 0.01)
    }
}
