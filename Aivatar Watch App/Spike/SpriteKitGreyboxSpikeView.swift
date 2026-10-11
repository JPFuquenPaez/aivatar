import SwiftUI
import SpriteKit

/// A0 spike: the same greybox rig rendered through SpriteKit + SpriteView
/// (§8 fallback / comparison candidate).
struct SpriteKitGreyboxSpikeView: View {
    let seed: UInt64
    let frameBudget: Int

    var body: some View {
        // watchOS-exposed surface: only `init(scene:)` exists. The unavailable
        // init is `init(scene:transition:isPaused:preferredFramesPerSecond:
        // options:shouldRender:)`. FPS is throttled inside the scene instead.
        SpriteView(
            scene: GreyboxSpikeScene(seed: seed, frameBudget: frameBudget, size: CGSize(width: 396, height: 484))
        )
        .ignoresSafeArea()
    }
}

/// SKScene that drives the identical AvatarCore motion + FK and dispatches the
/// results to pre-built sprite nodes. Nothing is created in `update`.
///
/// SpriteKit's SKScene API is nonisolated and its callbacks arrive on the main
/// thread, so the scene stays nonisolated to match.
nonisolated final class GreyboxSpikeScene: SKScene {
    private let frameBudget: Int
    private let skeleton: Skeleton
    private let motion: GreyboxMotion
    private let clock: AvatarClock
    private var pose: AvatarPose
    private var world: [Transform2D]
    private var probe: FrameTimeProbe?
    private var sceneLoadedAt: TimeInterval = 0

    private struct SlotNode {
        let boneIndex: Int
        let node: SKSpriteNode
    }

    private var nodes: [SlotNode] = []

    init(seed: UInt64, frameBudget: Int, size: CGSize) {
        self.frameBudget = frameBudget
        let rig = try! RigDocument.load()
        skeleton = try! Skeleton(document: rig)
        clock = AvatarClock(seed: seed)
        motion = GreyboxMotion(skeleton: skeleton, seed: seed)
        pose = AvatarPose(boneCount: skeleton.boneCount)
        world = [Transform2D](repeating: .identity, count: skeleton.boneCount)
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func sceneDidLoad() {
        super.sceneDidLoad()
        sceneLoadedAt = CFAbsoluteTimeGetCurrent()
        probe = FrameTimeProbe(renderer: "spritekit", capacity: frameBudget)

        let palette: [String: SKColor] = [
            "greyLight": SKColor(white: 0.85, alpha: 1),
            "greyMid": SKColor(white: 0.55, alpha: 1),
            "greyDark": SKColor(white: 0.15, alpha: 1),
        ]

        let slots = skeleton.document.slots.sorted { $0.drawOrder < $1.drawOrder }
        nodes.reserveCapacity(slots.count)
        for slot in slots {
            guard let index = skeleton.boneIndex(slot.bone) else { continue }
            let node = SKSpriteNode(
                color: palette[slot.paletteRole] ?? SKColor.gray,
                size: CGSize(width: CGFloat(slot.shape.width), height: CGFloat(slot.shape.height))
            )
            node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            addChild(node)
            nodes.append(SlotNode(boneIndex: index, node: node))
        }
    }

    /// SpriteView's watchOS-available init runs at the view's default 60 fps;
    /// the spike budget is 30 FPS, so the engine + dispatch work runs every
    /// other tick and the probe records the worked-frame cadence.
    private var tick = 0

    override func update(_ currentTime: TimeInterval) {
        guard let probe, tick % 2 == 0 else {
            tick &+= 1
            return
        }
        tick &+= 1
        let frameStart = CFAbsoluteTimeGetCurrent()

        let targetFrame = clock.frameIndex(at: currentTime - sceneLoadedAt)
        motion.update(pose: &pose, frame: targetFrame)
        skeleton.solve(pose: pose, into: &world)

        // SpriteView + .resizeFill keeps `size` in sync with the presented view.
        let viewSize = size
        let fit = min(viewSize.width / 205.0, viewSize.height / 251.0)
        let originX = (viewSize.width - 205.0 * fit) / 2
        let originY = (viewSize.height - 251.0 * fit) / 2

        for slot in nodes {
            let t = world[slot.boneIndex]
            let px: CGFloat = originX + CGFloat(t.tx) * fit
            let py: CGFloat = viewSize.height - (originY + CGFloat(t.ty) * fit)
            slot.node.position = CGPoint(x: px, y: py)
            slot.node.zRotation = -CGFloat(atan2(t.b, t.a))
            let sx: Float = sqrt(t.a * t.a + t.b * t.b)
            let sy: Float = sqrt(t.c * t.c + t.d * t.d)
            slot.node.xScale = CGFloat(sx)
            slot.node.yScale = CGFloat(sy)
        }

        probe.record(cpu: CFAbsoluteTimeGetCurrent() - frameStart, timestamp: frameStart)
    }
}
