import SwiftUI
import WatchKit
import CoreGraphics

/// Owns everything the render loop touches: the engine, the sprite painter,
/// the cached rest-pose world transforms and the TimelineView epoch. Built
/// once per stage appearance; the Canvas closures only mutate in place.
@MainActor
final class AvatarRenderContext {
    let engine: AvatarEngine
    let painter: AvatarSpritePainter
    let epoch = Date()

    /// Static world transforms for the rest pose, solved once on first use.
    private(set) var restWorld: [Transform2D] = []
    private(set) var restPose: AvatarPose?

    init(engine: AvatarEngine) {
        self.engine = engine
        painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
    }

    func solveRestIfNeeded() {
        guard restPose == nil else { return }
        var pose = engine.restPose
        var world = [Transform2D](repeating: .identity, count: engine.skeleton.boneCount)
        engine.skeleton.solve(pose: pose, into: &world)
        restWorld = world
        restPose = pose
    }
}

/// CanvasAvatarRenderer (§8): immediate-mode SwiftUI Canvas under
/// TimelineView(.animation) capped at 30 FPS. Pure-black clear, sprite
/// commands drawn back-to-front, no shadows/blurs/masks on the hot path.
///
/// When `isLuminanceReduced` is true the TimelineView is not composed at all
/// (zero animation ticks, §11) and the static rest pose is drawn once with the
/// dimmed rest palette (§6 rest LOD).
struct CanvasAvatarRenderer: View {
    let context: AvatarRenderContext

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    /// Reduce Motion Level 2: the in-app user setting (§8) — static pose +
    /// gentle blink. Strongest level wins over the system setting.
    @AppStorage("reduceMotionL2") private var reduceMotionL2 = false

    var body: some View {
        Group {
            if isLuminanceReduced {
                Canvas { ctx, size in
                    drawStaticRest(ctx: ctx, size: size)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { ctx, size in
                        draw(ctx: ctx, size: size, date: timeline.date)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: isLuminanceReduced) { reduced in
            context.engine.setResting(reduced)
            if !reduced {
                // Wrist raise: wake-up crossfade + haptic (§8 wake, §9).
                HapticsChannel.shared.wake()
            }
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize, date: Date) {
        let engine = context.engine
        engine.update(atElapsed: date.timeIntervalSince(context.epoch))
        context.painter.paint(
            world: engine.currentWorld,
            pose: engine.currentPose,
            rest: false,
            accentPhase: engine.activeGesturePhase
        )
        paintCommands(ctx: ctx, size: size)
    }

    private func drawStaticRest(ctx: GraphicsContext, size: CGSize) {
        context.solveRestIfNeeded()
        context.painter.paint(world: context.restWorld, pose: context.restPose!, rest: true)
        paintCommands(ctx: ctx, size: size)
    }

    /// Fit the 205x251 rig canvas into the view, clear to pure black, draw
    /// commands back-to-front (§8 renderer design).
    private func paintCommands(ctx: GraphicsContext, size: CGSize) {
        let painter = context.painter
        let fit = min(size.width / 205.0, size.height / 251.0)
        let originX = (size.width - 205.0 * fit) / 2
        let originY = (size.height - 251.0 * fit) / 2

        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

        for i in 0..<painter.commandCount {
            let command = painter.commands[i]
            var layer = ctx
            layer.translateBy(
                x: originX + CGFloat(command.tx) * fit,
                y: originY + CGFloat(command.ty) * fit
            )
            layer.rotate(by: Angle(radians: Double(command.rotation)))
            layer.scaleBy(x: CGFloat(command.scaleX), y: CGFloat(command.scaleY))
            let color = Color(.sRGB,
                               red: Double(command.r),
                               green: Double(command.g),
                               blue: Double(command.b),
                               opacity: Double(command.a))
            layer.fill(Path(painter.shapes[command.shapeIndex].paths[command.pathIndex]), with: .color(color))
        }
    }
}
