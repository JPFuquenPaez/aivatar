import SwiftUI
import os

/// A0 spike: the greybox rig rendered through SwiftUI Canvas +
/// TimelineView(.animation) capped at 30 FPS (§8 primary candidate).
struct CanvasGreyboxSpikeView: View {
    let seed: UInt64
    let frameBudget: Int

    @State private var context: CanvasSpikeContext?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                guard let context else { return }
                context.draw(in: ctx, size: size, date: timeline.date)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            context = CanvasSpikeContext(seed: seed, frameBudget: frameBudget)
            spikeLogger.log("AIVATAR-SPIKE: appear phase=\(String(describing: scenePhase), privacy: .public) luminanceReduced=\(self.isLuminanceReduced, privacy: .public)")
        }
        .onChange(of: scenePhase) { phase in
            spikeLogger.log("AIVATAR-SPIKE: phase=\(String(describing: phase), privacy: .public)")
        }
        .onChange(of: isLuminanceReduced) { reduced in
            spikeLogger.log("AIVATAR-SPIKE: luminanceReduced=\(reduced, privacy: .public)")
        }
    }
}

/// Owns every pre-allocated buffer the render loop touches: pose, world
/// transforms, paths, probe. The Canvas closure only mutates these in place.
@MainActor
private final class CanvasSpikeContext {
    private let skeleton: Skeleton
    private let motion: GreyboxMotion
    private let clock: AvatarClock
    private var pose: AvatarPose
    private var world: [Transform2D]
    private let probe: FrameTimeProbe
    private let epoch = CFAbsoluteTimeGetCurrent()

    /// Slot drawing data, prebuilt once: bone index, palette color, path.
    private struct SlotDrawable {
        let boneIndex: Int
        let color: Color
        let path: Path
        let halfWidth: CGFloat
    }

    private var drawables: [SlotDrawable] = []
    private var backgroundPath = Path()
    private var drawCalls = 0

    init(seed: UInt64, frameBudget: Int) {
        let rig = try! RigDocument.load()
        skeleton = try! Skeleton(document: rig)
        clock = AvatarClock(seed: seed)
        motion = GreyboxMotion(skeleton: skeleton, seed: seed)
        pose = AvatarPose(boneCount: skeleton.boneCount)
        world = [Transform2D](repeating: .identity, count: skeleton.boneCount)
        probe = FrameTimeProbe(renderer: "canvas", capacity: frameBudget)

        let palette: [String: Color] = [
            "greyLight": Color(white: 0.85),
            "greyMid": Color(white: 0.55),
            "greyDark": Color(white: 0.15),
        ]

        let slots = rig.slots.sorted { $0.drawOrder < $1.drawOrder }
        drawables.reserveCapacity(slots.count)
        for slot in slots {
            guard let index = skeleton.boneIndex(slot.bone) else { continue }
            drawables.append(SlotDrawable(
                boneIndex: index,
                color: palette[slot.paletteRole] ?? .gray,
                path: Self.path(for: slot.shape),
                halfWidth: CGFloat(slot.shape.width / 2)
            ))
        }
    }

    private static func path(for shape: RigDocument.Shape) -> Path {
        let w = CGFloat(shape.width)
        let h = CGFloat(shape.height)
        var path = Path()
        switch shape.kind {
        case "circle":
            path.addEllipse(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        case "capsule":
            path.addRoundedRect(
                in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                cornerSize: CGSize(width: w / 2, height: w / 2),
                style: .continuous
            )
        default:
            path.addRect(CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        }
        return path
    }

    func draw(in ctx: GraphicsContext, size: CGSize, date: Date) {
        let frameStart = CFAbsoluteTimeGetCurrent()
        drawCalls &+= 1
        if drawCalls % 60 == 0 {
            spikeLogger.log("AIVATAR-SPIKE: heartbeat canvas draw=\(self.drawCalls, privacy: .public)")
        }

        // Engine: deterministic frame from wall clock, then procedural update + FK.
        let targetFrame = clock.frameIndex(at: date.timeIntervalSince1970 - epoch)
        motion.update(pose: &pose, frame: targetFrame)
        skeleton.solve(pose: pose, into: &world)

        // Fit the 205x251 authoring canvas into the view, centered.
        let scaleX = size.width / 205.0
        let scaleY = size.height / 251.0
        let fit = min(scaleX, scaleY)
        let originX = (size.width - 205.0 * fit) / 2
        let originY = (size.height - 251.0 * fit) / 2

        // Clear to pure black (OLED power strategy, §2).
        if backgroundPath.isEmpty {
            backgroundPath.addRect(CGRect(origin: .zero, size: CGSize(width: 10_000, height: 10_000)))
        }
        var bg = ctx
        bg.fill(backgroundPath, with: .color(.black))

        for slot in drawables {
            let t = world[slot.boneIndex]
            var layer = ctx
            layer.translateBy(x: originX + CGFloat(t.tx) * fit, y: originY + CGFloat(t.ty) * fit)
            layer.rotate(by: Angle(radians: Double(atan2(t.b, t.a))))
            let sx = sqrt(t.a * t.a + t.b * t.b)
            let sy = sqrt(t.c * t.c + t.d * t.d)
            layer.scaleBy(x: CGFloat(sx), y: CGFloat(sy))
            layer.fill(slot.path, with: .color(slot.color))
        }

        probe.record(cpu: CFAbsoluteTimeGetCurrent() - frameStart, timestamp: frameStart)
    }
}
