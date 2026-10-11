import SwiftUI
import WatchKit
import CoreGraphics
#if DEBUG
import os
#endif

/// Stage composition (§9): the avatar occupies the center ~70% of the screen
/// with its face in the upper third. The rig canvas (205x251) is larger than
/// the drawn content — the rest pose spans rig y ~20...160, centered ~35.5
/// units above the canvas center — so fitting the full canvas shrinks the
/// avatar to ~52% of screen height with dead space below it. These constants
/// zoom past the canvas padding and center on the *content* instead.
fileprivate enum StageComposition {
    /// Zoom over the base canvas fit. 1.18 puts the ~140-unit content at
    /// ~66% of screen height on 44-46 mm devices, leaving headroom above
    /// for gesture peaks (raised wave arm ~+10 units) and the clock.
    static let zoom: CGFloat = 1.18
    /// Rest-pose content center in rig coordinates, relative to the canvas
    /// center (origin): 35.5 units above it (measured from the golden
    /// rasterizer bbox; negative y = up).
    static let contentCenterY: CGFloat = -35.5
    /// Screen height fraction where the content center lands. 0.50 keeps
    /// the face in the upper third (§9 glance zone) while leaving margin
    /// for the extremes across archetypes: Nimbus's raised middle puff
    /// (content top ~7 units above the canvas center) stays ~19 px below
    /// the screen top, and Ember's tail keeps ~20 px clearance above the
    /// name text (measured live on SE 3 44mm, Tools/avatar_bbox.swift).
    static let contentCenterYFraction: CGFloat = 0.50

    /// Maps rig space (origin at the canvas center) to screen space.
    /// Returns the fit scale and the screen position of the rig origin.
    static func solve(size: CGSize, rigWidth: CGFloat, rigHeight: CGFloat)
        -> (fit: CGFloat, originX: CGFloat, originY: CGFloat)
    {
        let fit = min(size.width / rigWidth, size.height / rigHeight) * zoom
        return (
            fit: fit,
            originX: size.width / 2,
            originY: size.height * contentCenterYFraction - contentCenterY * fit
        )
    }
}

/// Owns everything the render loop touches: the engine, the sprite painter,
/// the cached rest-pose world transforms and the TimelineView epoch. Built
/// once per stage appearance; the Canvas closures only mutate in place.
@MainActor
final class AvatarRenderContext {
    let engine: AvatarEngine
    let painter: AvatarSpritePainter
    let epoch = Date()
    /// Hi-bit pixel stage (§11.3 v4): rasterizes the command buffer to a
    /// 51x63 sprite grid snapped to the vivid archetype LUT.
    lazy var pixelRasterizer = PixelStageRasterizer(painter: painter)

    /// Cached gradient fill objects per color pair (v3 volumetric shading).
    /// The pairs are static per archetype, so the cache is warm after the
    /// first frame and the render loop allocates nothing (§7). Key: the two
    /// stop colors quantized to 8 bits per channel.
    private var gradientCache: [UInt64: Gradient] = [:]

    /// Returns the cached Gradient for a stop pair, building it on first
    /// use (one-time allocation per pair, never per frame).
    func cachedGradient(
        top: (r: Float, g: Float, b: Float),
        bottom: (r: Float, g: Float, b: Float)
    ) -> Gradient {
        func q(_ v: Float) -> UInt64 { UInt64(max(0, min(255, v * 255))) }
        let key = (q(top.r) << 40) | (q(top.g) << 32) | (q(top.b) << 24)
            | (q(bottom.r) << 16) | (q(bottom.g) << 8) | q(bottom.b)
        if let cached = gradientCache[key] { return cached }
        let gradient = Gradient(colors: [
            Color(.sRGB, red: Double(top.r), green: Double(top.g), blue: Double(top.b)),
            Color(.sRGB, red: Double(bottom.r), green: Double(bottom.g), blue: Double(bottom.b)),
        ])
        gradientCache[key] = gradient
        return gradient
    }

    #if DEBUG
    /// Throttled render-probe counter (diagnostics only).
    var debugDrawCount = 0
    #endif

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

    #if DEBUG
    /// Debug-only CPU raster of the painter command buffer, using the exact
    /// fit/origin math of the Canvas path (§8). `simctl io screenshot` does
    /// not capture SwiftUI Canvas GPU surfaces, so this overlay provides
    /// headless visual verification of layout and content. Never compiled
    /// into release builds.
    func debugImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Rig space is y-down (screen space); CG is y-up. Flip so the
        // avatar lands where the Canvas path puts it, with the rig origin
        // at the canvas center (same mapping as paintCommands).
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let size = CGSize(width: width, height: height)
        let mapping = StageComposition.solve(
            size: size, rigWidth: 205.0, rigHeight: 251.0
        )
        let fit = mapping.fit
        let centerX = mapping.originX
        let centerY = mapping.originY
        for i in 0..<painter.commandCount {
            let command = painter.commands[i]
            ctx.saveGState()
            ctx.translateBy(x: centerX + CGFloat(command.tx) * fit, y: centerY + CGFloat(command.ty) * fit)
            ctx.rotate(by: CGFloat(command.rotation))
            ctx.scaleBy(x: CGFloat(command.scaleX), y: CGFloat(command.scaleY))
            ctx.addPath(painter.shapes[command.shapeIndex].paths[command.pathIndex])
            if command.useGradient {
                // Volumetric fill, same span math as the live Canvas path.
                let shape = painter.shapes[command.shapeIndex]
                let startY: CGFloat
                let endY: CGFloat
                if shape.perPathGradient {
                    startY = -CGFloat(shape.pathHeights[command.pathIndex]) / 2
                    endY = CGFloat(shape.pathHeights[command.pathIndex]) / 2
                } else {
                    let offset = CGFloat(shape.offsetsY[command.pathIndex])
                    startY = -(CGFloat(shape.height) / 2 + offset)
                    endY = CGFloat(shape.height) / 2 - offset
                }
                let colors = [
                    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                            components: [CGFloat(command.r), CGFloat(command.g), CGFloat(command.b), 1])!,
                    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                            components: [CGFloat(command.r2), CGFloat(command.g2), CGFloat(command.b2), 1])!,
                ]
                let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: colors as CFArray,
                    locations: [0, 1]
                )!
                ctx.clip()
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: startY),
                    end: CGPoint(x: 0, y: endY),
                    options: []
                )
            } else {
                ctx.setFillColor(CGColor(
                    colorSpace: CGColorSpaceCreateDeviceRGB(),
                    components: [CGFloat(command.r), CGFloat(command.g), CGFloat(command.b), CGFloat(command.a)]
                )!)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
    #endif
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
        // Reduce Motion (§8): Level 2 (in-app) > Level 1 (system,
        // WKAccessibilityIsReduceMotionEnabled, watchOS 4+) > full. Polled
        // per frame — a cheap C call; no notification bookkeeping.
        engine.accessibilityMode = resolveAccessibilityMode()
        engine.update(atElapsed: date.timeIntervalSince(context.epoch))
        context.painter.paint(
            world: engine.currentWorld,
            pose: engine.currentPose,
            rest: false,
            accentPhase: engine.activeGesturePhase,
            tell: engine.tell,
            tellPhase: engine.tellPhase
        )
        // Vector stage (v4 reference direction: smooth-gradient low-poly).
        // The hi-bit pixel rasterizer (§11.3) remains available as an
        // alternate LOD — rasterize(painter:) + draw(into:size:).
        paintCommands(ctx: ctx, size: size)
        #if DEBUG
        context.debugDrawCount += 1
        if context.debugDrawCount % 60 == 1 {
            spikeLogger.log("AIVATAR-SPIKE: live draw #\(context.debugDrawCount) commands=\(context.painter.commandCount) frame=\(engine.clock.frame)")
        }
        #endif
    }

    private func resolveAccessibilityMode() -> MotionAccessibilityMode {
        if reduceMotionL2 { return .reduceMotionL2 }
        if WKAccessibilityIsReduceMotionEnabled() { return .reduceMotionL1 }
        return .full
    }

    private func drawStaticRest(ctx: GraphicsContext, size: CGSize) {
        context.solveRestIfNeeded()
        context.painter.paint(world: context.restWorld, pose: context.restPose!, rest: true)
        paintCommands(ctx: ctx, size: size)
    }

    /// Fit the rig content into the view (§9 composition via
    /// StageComposition), clear to pure black, draw commands back-to-front
    /// (§8 renderer design).
    private func paintCommands(ctx: GraphicsContext, size: CGSize) {
        let painter = context.painter
        let rig = context.engine.skeleton.document
        let mapping = StageComposition.solve(
            size: size, rigWidth: CGFloat(rig.width), rigHeight: CGFloat(rig.height)
        )
        let fit = mapping.fit
        let centerX = mapping.originX
        let centerY = mapping.originY

        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

        for i in 0..<painter.commandCount {
            let command = painter.commands[i]
            var layer = ctx
            layer.translateBy(
                x: centerX + CGFloat(command.tx) * fit,
                y: centerY + CGFloat(command.ty) * fit
            )
            layer.rotate(by: Angle(radians: Double(command.rotation)))
            layer.scaleBy(x: CGFloat(command.scaleX), y: CGFloat(command.scaleY))
            let path = Path(painter.shapes[command.shapeIndex].paths[command.pathIndex])
            if command.useGradient {
                // Volumetric fill (v3): the gradient spans the mass's local
                // bbox — per path for self-shaded masses (the cloud head's
                // puffs), or the WHOLE shape for bend slices (top edge at
                // h/2 + slice offset, bottom at h/2 - slice offset) so a
                // sliced capsule shades as one volume, not bands.
                let shape = painter.shapes[command.shapeIndex]
                let startY: CGFloat
                let endY: CGFloat
                if shape.perPathGradient {
                    startY = -CGFloat(shape.pathHeights[command.pathIndex]) / 2
                    endY = CGFloat(shape.pathHeights[command.pathIndex]) / 2
                } else {
                    let offset = CGFloat(shape.offsetsY[command.pathIndex])
                    startY = -(CGFloat(shape.height) / 2 + offset)
                    endY = CGFloat(shape.height) / 2 - offset
                }
                let gradient = context.cachedGradient(
                    top: (command.r, command.g, command.b),
                    bottom: (command.r2, command.g2, command.b2)
                )
                layer.fill(path, with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: startY),
                    endPoint: CGPoint(x: 0, y: endY)
                ))
            } else {
                let color = Color(.sRGB,
                                   red: Double(command.r),
                                   green: Double(command.g),
                                   blue: Double(command.b),
                                   opacity: Double(command.a))
                layer.fill(path, with: .color(color))
            }
        }
    }
}
