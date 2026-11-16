import Foundation
import CoreGraphics
import SwiftUI

/// PuppetDrawing (v3): the character renderer. Pure path math in author
/// space (1000 x 1000, y-down, feet at y≈880) drawn through a tiny surface
/// protocol with two backends — SwiftUI Canvas (the live stage) and
/// CGContext (icons, postcards, tests). Deterministic: same (spec, pose,
/// props, style, time) → same geometry, byte-stable under CG.
///
/// Design contracts enforced here:
/// - baby schema (CompanionToy): head diameter ≈ 55% of the figure height,
///   eyes ≈ 30% of the head width, at/below the head midline;
/// - no sharp corners: every part rounds at >= 10% of its smaller
///   dimension (ears are swell-tipped triangles, never spikes);
/// - silhouette first: one exaggerated identity shape per animal drives the
///   outline (fox brush, shiba ruff, corgi ears, sphynx bat ears,
///   mockingbird swept wing, moth wings);
/// - the face is the focal point: lightest values on the face/belly, dark
///   glossy pupils carry the catchlight, and nothing but lids ever covers
///   the eyes;
/// - 2-tone depth only (shadeHex where shapes overlap) — gradients exist
///   ONLY in the claymorphic style (phone/postcard), never on the OLED
///   stage.
nonisolated enum PuppetDrawing {

    // MARK: - Surface protocol + backends

    /// The two-backend painter. All geometry arrives in author space.
    protocol Surface {
        func fill(_ path: CGPath, _ color: RGBA)
        func linear(_ path: CGPath, colors: [RGBA], from: CGPoint, to: CGPoint)
    }

    /// SwiftUI Canvas backend: the live stage.
    /// `device` maps author space to the canvas (y-down to y-down).
    struct CanvasSurface: Surface {
        let ctx: GraphicsContext
        let device: CGAffineTransform

        nonisolated init(ctx: GraphicsContext, device: CGAffineTransform = .identity) {
            self.ctx = ctx
            self.device = device
        }

        nonisolated func fill(_ path: CGPath, _ color: RGBA) {
            let c = Color(.sRGB, red: max(0, min(1, color.r)),
                          green: max(0, min(1, color.g)),
                          blue: max(0, min(1, color.b)),
                          opacity: max(0, min(1, color.a)))
            ctx.fill(Path(path.applying(device)), with: .color(c))
        }

        nonisolated func linear(_ path: CGPath, colors: [RGBA], from: CGPoint, to: CGPoint) {
            let stops = colors.map { color in
                Color(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: color.a)
            }
            ctx.fill(Path(path.applying(device)), with: .linearGradient(
                Gradient(colors: stops),
                startPoint: from.applying(device), endPoint: to.applying(device)))
        }
    }

    /// CoreGraphics backend (icons, postcards, tests). `device` maps author
    /// space into the bitmap (y-down author -> y-up CG: callers compose the
    /// y-flip with their layout).
    struct CGSurface: Surface {
        let cg: CGContext
        let device: CGAffineTransform

        nonisolated init(cg: CGContext, device: CGAffineTransform) {
            self.cg = cg
            self.device = device
        }

        nonisolated func fill(_ path: CGPath, _ color: RGBA) {
            cg.setFillColor(red: CGFloat(color.r), green: CGFloat(color.g),
                            blue: CGFloat(color.b), alpha: CGFloat(color.a))
            cg.addPath(path.applying(device))
            cg.fillPath()
        }

        nonisolated func linear(_ path: CGPath, colors: [RGBA], from: CGPoint, to: CGPoint) {
            let comps: [CGFloat] = colors.flatMap { [$0.r, $0.g, $0.b, $0.a] }
            guard let grad = CGGradient(
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                colorComponents: comps,
                locations: nil, count: colors.count) else { return }
            cg.saveGState()
            cg.addPath(path.applying(device))
            cg.clip()
            cg.drawLinearGradient(
                grad,
                start: from.applying(device),
                end: to.applying(device),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            cg.restoreGState()
        }

        /// The author(y-down)-to-CG(y-up) flip for a bitmap of `height`.
        /// (Row-vector semantics: scale first, THEN add the height offset.)
        nonisolated static func flip(height: CGFloat) -> CGAffineTransform {
            CGAffineTransform(scaleX: 1, y: -1)
                .concatenating(CGAffineTransform(translationX: 0, y: height))
        }
    }

    // MARK: - Layout

    /// The stage layout: author space fitted into a canvas box.
    nonisolated struct Layout {
        let scale: CGFloat
        let originX: CGFloat
        let originY: CGFloat

        /// Fits the 1000-wide author figure into the canvas, content center
        /// at 46% height (the v13 glance zone), feet near the lower band.
        nonisolated static func fit(canvas: CGSize, scaleFactor: CGFloat = 0.92) -> Layout {
            let w = canvas.width > 0 ? canvas.width : 1
            let h = canvas.height > 0 ? canvas.height : 1
            let scale = w / 1000 * scaleFactor
            return Layout(scale: scale,
                           originX: (w - 1000 * scale) / 2,
                           originY: h * 0.46 - 500 * scale)
        }

        nonisolated func point(x: CGFloat, y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        /// Author (y-down) to canvas (y-down) affine: scale, then offset.
        nonisolated var deviceTransform: CGAffineTransform {
            CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: originX, y: originY))
        }
    }

    /// The head's hit circle for the boop gesture, in canvas points.
    nonisolated static func headHitCircle(archetype: Archetype, canvas: CGSize) -> (center: CGPoint, radius: CGFloat) {
        let spec = CompanionToys.spec(for: archetype)
        let layout = Layout.fit(canvas: canvas)
        let center = layout.point(x: 500, y: 400)
        let radius = (spec.headDiameter / 2 + spec.earHeight * 0.15) * layout.scale
        return (center, radius)
    }

    // MARK: - Tint (palette resolution per draw)

    /// The per-draw tint mode: weather hue rotation (Prism), the rest-LOD
    /// dim, and the icon-cut event flash — one resolver, no drift.
    nonisolated struct ToyTint {
        let spec: ToySpec
        let hueShift: Double
        let rest: Bool
        let event: Bool

        nonisolated init(spec: ToySpec, hueShift: Double = 0,
                         rest: Bool = false, event: Bool = false) {
            self.spec = spec
            self.hueShift = hueShift
            self.rest = rest
            self.event = event
        }

        /// Resolves a family token: hue-rotated, event-flashed, rest-dimmed.
        nonisolated func color(_ hex: String, alpha: Double = 1) -> RGBA {
            var base = hex
            if abs(hueShift) >= 0.5 {
                base = ColorHex.hueRotated(base, degrees: hueShift)
            }
            var out = RGBA(base, alpha: alpha)
            if event, base == spec.bodyHex {
                out = RGBA(spec.accentHex, alpha: alpha)
            }
            if rest {
                out = out.restDimmed
            }
            return out
        }

        /// Body-color fill helper honoring the style's clay gradient.
        nonisolated func styleFill<S: Surface>(
            _ surface: S, path: CGPath, hex: String, style: PuppetStyle,
            gradientFrom: CGPoint, gradientTo: CGPoint
        ) {
            switch style {
            case .clay:
                var top = color(hex)
                top.a = 1
                var bottom = color(hex)
                bottom.a = 0.80
                surface.linear(path, colors: [top, bottom],
                               from: gradientFrom, to: gradientTo)
            case .flat, .icon:
                surface.fill(path, color(hex))
            case .rest:
                surface.fill(path, color(hex).restDimmed)
            }
        }
    }

    // MARK: - Entry points

    /// Draws the full puppet. `time` (seconds) drives only display-rate
    /// flutter phases (wag / wings), never scheduling.
    nonisolated static func draw<S: Surface>(
        _ surface: S, spec: ToySpec, pose: PuppetPose, props: PuppetProps,
        style: PuppetStyle, time: Double,
        growthScale: CGFloat = 1, accessory: PuppetAccessory? = nil,
        hueShift: Double = 0
    ) {
        let tint = ToyTint(spec: spec, hueShift: hueShift,
                           rest: style == .rest, event: false)
        let root = rootTransform(pose: pose, growth: growthScale)
        let faceShift = pose.headTurn * 34
        let headShiftX = pose.headTurn * 14 + pose.headOffsetX
        let headShiftY = pose.headOffsetY + pose.headNod * 18

        drawShadow(surface, spec: spec, pose: pose, root: root, style: style)

        if spec.tailKind != .none {
            drawTail(surface, spec: spec, pose: pose, root: root,
                     phase: time, tint: tint, style: style)
        }
        if spec.wingKind != .none {
            drawWings(surface, spec: spec, pose: pose, root: root,
                      phase: time, tint: tint, style: style)
        }
        drawBody(surface, spec: spec, pose: pose, root: root, tint: tint, style: style)
        drawFeet(surface, spec: spec, root: root, tint: tint, style: style)
        if let accessory {
            drawAccessory(surface, accessory: accessory, spec: spec, root: root, tint: tint)
        }
        drawHead(surface, spec: spec, pose: pose, root: root, tint: tint, style: style,
                 shiftX: headShiftX, shiftY: headShiftY, faceShift: faceShift)
        drawProps(surface, spec: spec, props: props, root: root,
                  shiftX: headShiftX, shiftY: headShiftY, tint: tint)
    }

    /// Simplified head-only cut for complications and hero discs.
    nonisolated static func drawHeadOnly<S: Surface>(
        _ surface: S, spec: ToySpec, pose: PuppetPose,
        state: IconCutState, time: Double, canvas: CGSize
    ) {
        let tint = ToyTint(spec: spec,
                           rest: state == .asleep,
                           event: state == .event)
        var headPose = pose
        switch state {
        case .awake:
            headPose.mouth = .smile
        case .asleep:
            headPose.lidOpen = 0
            headPose.mouth = .rest
            headPose.earL = -0.4
            headPose.earR = -0.4
        case .event:
            headPose.lidOpen = 0.16
            headPose.mouth = .ws
            headPose.cheekGlow = 1
            headPose.earL = 1
            headPose.earR = 1
        }
        // Layout: the head (plus ears) fills the canvas; author root is the
        // scale around the head center (500, 400).
        let headD = spec.headDiameter
        let earH = max(spec.earHeight, spec.antennae ? 150 : 0)
        let fitW = headD + spec.earWidth * 2.2
        let fitH = headD + earH * 1.9 + 60
        let scale = min(canvas.width / fitW, canvas.height / fitH)
        let root = rootHeadOnly(scale: scale, canvas: canvas)
        drawHead(surface, spec: spec, pose: headPose, root: root, tint: tint,
                 style: state == .asleep ? .rest : .flat,
                 shiftX: 0, shiftY: 0, faceShift: 0)
        // The greeting-phase ear flutter still animates subtly in icons.
        _ = time
    }

    nonisolated static func rootHeadOnly(scale: CGFloat, canvas: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: canvas.width / 2 - 500 * scale,
                           y: canvas.height * 0.52 - 400 * scale)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }

    nonisolated enum IconCutState: Sendable, Equatable {
        case awake, asleep, event
    }

    // MARK: - Transforms

    /// The whole-figure transform: hop, lean about the feet, squash pivoted
    /// at the ground — the feet stay planted while the body squishes.
    nonisolated static func rootTransform(pose: PuppetPose, growth: CGFloat) -> CGAffineTransform {
        // Row-vector chains apply left to right: pivot about the feet
        // (untranslate, rotate, squash-scale, translate back), then lift.
        let feetY: CGFloat = 850
        return CGAffineTransform(translationX: -500, y: -feetY)
            .concatenating(CGAffineTransform(rotationAngle: pose.lean))
            .concatenating(CGAffineTransform(scaleX: pose.bodyScaleX * growth,
                                             y: pose.bodyScaleY * growth))
            .concatenating(CGAffineTransform(translationX: 500, y: feetY))
            .concatenating(CGAffineTransform(translationX: 0, y: -pose.hop))
    }

    /// The head group transform (tilt about the head center + offsets).
    nonisolated static func headTransform(pose: PuppetPose, shiftX: CGFloat, shiftY: CGFloat) -> CGAffineTransform {
        let cx = 500 + shiftX
        let cy = 400 + shiftY
        // Pivot about the head center: untranslate, tilt, translate back.
        return CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(rotationAngle: pose.headTilt))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
    }

    // MARK: - Parts

    private nonisolated static func drawShadow<S: Surface>(
        _ surface: S, spec: ToySpec, pose: PuppetPose,
        root: CGAffineTransform, style: PuppetStyle
    ) {
        guard style != .rest else { return }
        let sway = 1 + Double(pose.hop) / 240 + Double(pose.bodyScaleX - 1) * 0.5
                 + Double(1 - pose.bodyScaleY) * 0.5
        let alpha = style == .clay ? 0.30 : max(0, 0.22 - Double(pose.hop) / 900)
        surface.fill(ellipse(500, 872, 520 * CGFloat(sway), 34).applying(root),
                     RGBA(r: 0, g: 0, b: 0, a: alpha))
    }

    private nonisolated static func drawBody<S: Surface>(
        _ surface: S, spec: ToySpec, pose: PuppetPose,
        root: CGAffineTransform, tint: ToyTint, style: PuppetStyle
    ) {
        let bean = roundedBean(cx: 500, cy: 700, w: 560, h: 300).applying(root)
        tint.styleFill(surface, path: bean, hex: spec.bodyHex, style: style,
                       gradientFrom: CGPoint(x: 500, y: 540), gradientTo: CGPoint(x: 500, y: 860))
        let belly = ellipse(500, 722, 380, 208).applying(root)
        surface.fill(belly, tint.color(spec.bellyHex))

        if spec.saddle, spec.archetype == .compass {
            let saddle = roundedBean(cx: 560, cy: 634, w: 430, h: 148).applying(root)
            surface.fill(saddle, tint.color(spec.shadeHex))
        }
        if spec.wrinkleRows, spec.archetype == .prism {
            for (i, dy) in [0, 34, 68].enumerated() {
                let row = ellipse(500, 650 + CGFloat(dy), 300 - CGFloat(i) * 22, 12).applying(root)
                surface.fill(row, tint.color(spec.shadeHex, alpha: 0.5))
            }
        }
    }

    private nonisolated static func drawFeet<S: Surface>(
        _ surface: S, spec: ToySpec, root: CGAffineTransform,
        tint: ToyTint, style: PuppetStyle
    ) {
        for x: CGFloat in [398, 602] {
            let foot = ellipse(x, 842, 118, 58).applying(root)
            tint.styleFill(surface, path: foot, hex: spec.shadeHex, style: style,
                           gradientFrom: CGPoint(x: x, y: 815), gradientTo: CGPoint(x: x, y: 880))
        }
    }

    private nonisolated static func drawTail<S: Surface>(
        _ surface: S, spec: ToySpec, pose: PuppetPose,
        root: CGAffineTransform, phase: Double,
        tint: ToyTint, style: PuppetStyle
    ) {
        let flutter = pose.wag * CGFloat(0.5 * sin(2.0 * .pi * 2.2 * phase + 0.4))
        let angle = pose.tailAngle + pose.tailLift * 0.9 + flutter
        let base = CGPoint(x: 500, y: 742)
        let tilt = CGAffineTransform(translationX: -base.x, y: -base.y)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: base.x, y: base.y))
        let world = tilt.concatenating(root)
        switch spec.tailKind {
        case .none:
            break
        case .brush:
            let stemC = CGPoint(x: 780, y: 660)
            let stemTilt = CGAffineTransform(translationX: -stemC.x, y: -stemC.y)
                .concatenating(CGAffineTransform(rotationAngle: -0.5))
                .concatenating(CGAffineTransform(translationX: stemC.x, y: stemC.y))
            let stem = roundedBean(cx: 770, cy: 656, w: 300, h: 150)
                .applying(stemTilt)
                .applying(world)
            tint.styleFill(surface, path: stem, hex: spec.bodyHex, style: style,
                           gradientFrom: CGPoint(x: 780, y: 600), gradientTo: CGPoint(x: 780, y: 740))
            surface.fill(ellipse(892, 566, 118, 108).applying(world),
                         tint.color(spec.bellyHex))
        case .curl:
            surface.fill(ellipse(702, 646, 150, 140).applying(world),
                         tint.color(spec.shadeHex))
            surface.fill(ellipse(702, 646, 84, 76).applying(world),
                         tint.color(spec.bellyHex))
        case .nub:
            let pop = 1 + pose.wag * 0.3
            surface.fill(ellipse(702, 690, 92 * pop, 88).applying(world),
                         tint.color(spec.shadeHex))
        case .slim:
            let slimC = CGPoint(x: 726, y: 714)
            let slimTilt = CGAffineTransform(translationX: -slimC.x, y: -slimC.y)
                .concatenating(CGAffineTransform(rotationAngle: -0.35))
                .concatenating(CGAffineTransform(translationX: slimC.x, y: slimC.y))
            let slim = roundedBean(cx: 716, cy: 714, w: 240, h: 68)
                .applying(slimTilt)
                .applying(world)
            surface.fill(slim, tint.color(spec.shadeHex))
        case .fan:
            for (dx, dy) in [(0.0, 0.0), (0.16, 0.42), (-0.12, 0.78)] {
                let feather = ellipse(716 + CGFloat(dx) * 80, 700 + CGFloat(dy) * 76, 74, 52)
                    .applying(world)
                surface.fill(feather, tint.color(spec.shadeHex))
            }
        }
    }

    private nonisolated static func drawWings<S: Surface>(
        _ surface: S, spec: ToySpec, pose: PuppetPose,
        root: CGAffineTransform, phase: Double,
        tint: ToyTint, style: PuppetStyle
    ) {
        let flap = pose.wing + CGFloat(PuppetAmbient.flutter(at: phase)) * 0.25
        switch spec.wingKind {
        case .none:
            break
        case .oneSwept:
            let base = CGPoint(x: 430, y: 690)
            let tilt = CGAffineTransform(translationX: -base.x, y: -base.y)
                .concatenating(CGAffineTransform(rotationAngle: -0.55 - Double(flap) * 0.5))
                .concatenating(CGAffineTransform(translationX: base.x, y: base.y))
            let world = tilt.concatenating(root)
            let wing = roundedBean(cx: 322, cy: 620, w: 260, h: 128).applying(world)
            tint.styleFill(surface, path: wing, hex: spec.shadeHex, style: style,
                           gradientFrom: CGPoint(x: 322, y: 560), gradientTo: CGPoint(x: 322, y: 690))
            surface.fill(ellipse(244, 564, 84, 56).applying(world),
                         tint.color(spec.accentHex, alpha: 0.75))
        case .mothPair:
            let glow = max(pose.catchGlow, CGFloat(PuppetAmbient.flutter(at: phase)))
            for side in [-1.0, 1.0] {
                let bx = 500 + CGFloat(side) * 244
                let base = CGPoint(x: 500 + CGFloat(side) * 150, y: 520)
                let tilt = CGAffineTransform(translationX: -base.x, y: -base.y)
                    .concatenating(CGAffineTransform(rotationAngle: CGFloat(side) * Double(flap) * 0.45))
                    .concatenating(CGAffineTransform(translationX: base.x, y: base.y))
                let world = tilt.concatenating(root)
                surface.fill(ellipse(bx, 452, 300, 238).applying(world),
                             tint.color(spec.shadeHex))
                surface.fill(ellipse(bx + CGFloat(side) * 36, 588, 190, 150).applying(world),
                             tint.color(spec.shadeHex, alpha: 0.85))
                surface.fill(ellipse(bx - CGFloat(side) * 26, 442, 118, 88).applying(world),
                             tint.color(spec.accentHex, alpha: 0.28 + 0.30 * glow))
            }
        }
    }

    private nonisolated static func drawHead<S: Surface>(
        _ surface: S, spec: ToySpec, pose: PuppetPose,
        root: CGAffineTransform, tint: ToyTint, style: PuppetStyle,
        shiftX: CGFloat, shiftY: CGFloat, faceShift: CGFloat
    ) {
        let group = headTransform(pose: pose, shiftX: shiftX, shiftY: shiftY)
        let total = group.concatenating(root)
        let headCx = 500 + shiftX
        let headCy = 400 + shiftY
        let headD = spec.headDiameter

        if spec.earHeight > 0 {
            drawEars(surface, spec: spec, pose: pose, tint: tint, total: total,
                     headCx: headCx, headCy: headCy, headD: headD)
        }
        if spec.antennae {
            drawAntennae(surface, spec: spec, pose: pose, tint: tint, total: total,
                         headCx: headCx, headCy: headCy, headD: headD)
        }

        let head = circle(headCx, headCy, headD / 2).applying(total)
        tint.styleFill(surface, path: head, hex: spec.bodyHex, style: style,
                       gradientFrom: CGPoint(x: headCx, y: headCy - headD / 2),
                       gradientTo: CGPoint(x: headCx, y: headCy + headD / 2))

        if spec.muzzle, spec.archetype == .ember {
            let muzzle = ellipse(headCx + faceShift * 0.5, headCy + headD * 0.28,
                                 headD * 0.58, headD * 0.42).applying(total)
            surface.fill(muzzle, tint.color(spec.bellyHex))
        }
        if spec.ruff, spec.archetype == .willow {
            for side in [-1.0, 1.0] {
                surface.fill(
                    circle(headCx + CGFloat(side) * headD * 0.42,
                           headCy + headD * 0.12, headD * 0.20).applying(total),
                    tint.color(spec.shadeHex))
            }
        }

        // --- The face — the avatar.
        let eyeD = headD * spec.eyeRatio
        let eyeR = eyeD / 2
        let eyeY = headCy + headD * 0.10
        let window = eyeR * 0.34
        for side in [-1.0, 1.0] {
            let ex = headCx + CGFloat(side) * headD * 0.30 + faceShift
            surface.fill(circle(ex, eyeY, eyeR).applying(total),
                         tint.color(spec.pupilHex))
            let px = ex + CGFloat(pose.pupilX) * window
            let py = eyeY + CGFloat(pose.pupilY) * window * 0.8
            let pr = eyeR * (0.52 + 0.30 * pose.pupilDilate)
            surface.fill(circle(px, py, pr).applying(total),
                         tint.color(spec.pupilHex))
            // The catchlight: the single most alive pixel — pupil-locked.
            surface.fill(circle(px - pr * 0.34, py - pr * 0.34,
                                pr * (0.30 + 0.14 * pose.catchGlow)).applying(total),
                         RGBA(r: 1, g: 1, b: 1, a: 0.95))
            // Lids close from the top, skin-colored cap over the eye disc.
            let coverage = Double(max(0, 1 - pose.lidOpen)) + Double(pose.lidSoft) * 0.45
            if coverage > 0.03 {
                surface.fill(circleCap(center: CGPoint(x: ex, y: eyeY), r: eyeR,
                                       coverage: min(coverage, 1)).applying(total),
                             tint.color(spec.bodyHex))
                if coverage > 0.55 {
                    surface.fill(
                        ellipse(ex, eyeY - eyeR + CGFloat(coverage) * eyeR,
                                eyeR * 2.02, CGFloat(coverage) * eyeR * 1.3).applying(total),
                        tint.color(spec.inkHex, alpha: 0.30))
                }
            }
        }

        // Cheeks (the caretaking accent; the flush rides cheekGlow).
        let blushAlpha = 0.10 + 0.36 * Double(pose.cheekGlow)
        for side in [-1.0, 1.0] {
            surface.fill(
                ellipse(headCx + CGFloat(side) * headD * 0.40 + faceShift * 0.7,
                        headCy + headD * 0.25, headD * 0.15, headD * 0.09).applying(total),
                tint.color(spec.accentHex, alpha: blushAlpha))
        }

        drawMouth(surface, spec: spec, pose: pose, tint: tint, total: total,
                  faceShift: faceShift, headCx: headCx, headCy: headCy, headD: headD)
    }

    private nonisolated static func drawEars<S: Surface>(
        _ surface: S, spec: ToySpec, pose: PuppetPose, tint: ToyTint,
        total: CGAffineTransform, headCx: CGFloat, headCy: CGFloat, headD: CGFloat
    ) {
        let ears: [(side: Double, perk: CGFloat)] = [(-1, pose.earL), (1, pose.earR)]
        for ear in ears {
            let side = CGFloat(ear.side)
            let baseX = headCx + side * headD * 0.30
            let baseY = headCy - headD * 0.42
            let rot = CGAffineTransform(translationX: -baseX, y: -baseY)
                .concatenating(CGAffineTransform(rotationAngle:
                    side * spec.earSplay * (1 - Double(ear.perk) * 0.55)))
                .concatenating(CGAffineTransform(scaleX: 1 + ear.perk * 0.06,
                                                y: 1 + ear.perk * 0.16))
                .concatenating(CGAffineTransform(translationX: baseX, y: baseY))
            let w = spec.earWidth
            let h = spec.earHeight
            let tipY = baseY - h
            var outline = CGMutablePath()
            outline.move(to: CGPoint(x: baseX - w / 2, y: baseY + h * 0.12))
            outline.addQuadCurve(to: CGPoint(x: baseX, y: tipY),
                                 control: CGPoint(x: baseX - w * 0.52, y: baseY - h * 0.78))
            outline.addQuadCurve(to: CGPoint(x: baseX + w / 2, y: baseY + h * 0.12),
                                 control: CGPoint(x: baseX + w * 0.52, y: baseY - h * 0.78))
            outline.addQuadCurve(to: CGPoint(x: baseX - w / 2, y: baseY + h * 0.12),
                                 control: CGPoint(x: baseX, y: baseY + h * 0.30))
            // Stroked with round joins = the swell-tip "no sharp corners" rule.
            let earPath = outline
                .copy(strokingWithWidth: max(w * 0.18, 20), lineCap: .round, lineJoin: .round, miterLimit: 10)
                .applying(rot).applying(total)
            surface.fill(earPath, tint.color(spec.bodyHex))

            var inner = CGMutablePath()
            inner.move(to: CGPoint(x: baseX - w * 0.24, y: baseY - h * 0.04))
            inner.addQuadCurve(to: CGPoint(x: baseX, y: tipY + h * 0.16),
                              control: CGPoint(x: baseX - w * 0.28, y: baseY - h * 0.55))
            inner.addQuadCurve(to: CGPoint(x: baseX + w * 0.24, y: baseY - h * 0.04),
                              control: CGPoint(x: baseX + w * 0.28, y: baseY - h * 0.55))
            let innerPath = inner
                .copy(strokingWithWidth: 12, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .applying(rot).applying(total)
            surface.fill(innerPath, tint.color(spec.shadeHex, alpha: 0.75))
        }
    }

    private nonisolated static func drawAntennae<S: Surface>(
        _ surface: S, spec: ToySpec, pose: PuppetPose, tint: ToyTint,
        total: CGAffineTransform, headCx: CGFloat, headCy: CGFloat, headD: CGFloat
    ) {
        for side in [-1.0, 1.0] {
            let bx = headCx + CGFloat(side) * 92
            let baseY = headCy - headD / 2 + 34
            let bend = CGFloat(side) * (0.24 + Double(pose.earL) * 0.10 - Double(side) * Double(pose.pupilX) * 0.08)
            let rot = CGAffineTransform(translationX: -bx, y: -baseY)
                .concatenating(CGAffineTransform(rotationAngle: bend))
                .concatenating(CGAffineTransform(translationX: bx, y: baseY))
            var stem = CGMutablePath()
            stem.move(to: CGPoint(x: bx, y: baseY))
            stem.addQuadCurve(to: CGPoint(x: bx + CGFloat(side) * 88, y: baseY - 96),
                              control: CGPoint(x: bx + CGFloat(side) * 30, y: baseY - 78))
            let stemPath = stem.copy(strokingWithWidth: 9, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .applying(rot).applying(total)
            surface.fill(stemPath, tint.color(spec.inkHex))
            // The glow tips (lumen's night identity; perk brightens them).
            for (dx, dy, r, alpha) in [(88.0, -96.0, 17.0, 0.55), (84.0, -84.0, 10.0, 0.9)] {
                surface.fill(
                    circle(bx + CGFloat(side) * CGFloat(dx), baseY + CGFloat(dy), CGFloat(r))
                        .applying(rot).applying(total),
                    tint.color(spec.accentHex, alpha: alpha + 0.35 * Double(pose.catchGlow)))
            }
        }
    }

    private nonisolated static func drawMouth<S: Surface>(
        _ surface: S, spec: ToySpec, pose: PuppetPose, tint: ToyTint,
        total: CGAffineTransform, faceShift: CGFloat,
        headCx: CGFloat, headCy: CGFloat, headD: CGFloat
    ) {
        let mx = headCx + faceShift
        let my = headCy + headD * 0.34
        let ink = tint.color(spec.inkHex)
        let mouthPath: CGPath
        switch pose.mouth {
        case .rest:
            let bar = CGMutablePath()
            bar.addRoundedRect(
                in: CGRect(x: mx - 24, y: my - 4, width: 48, height: 8),
                cornerWidth: 4, cornerHeight: 4)
            mouthPath = bar
        case .smile:
            let curve = CGMutablePath()
            curve.move(to: CGPoint(x: mx - 32, y: my - 2))
            curve.addQuadCurve(to: CGPoint(x: mx + 32, y: my - 2),
                               control: CGPoint(x: mx, y: my + 20))
            mouthPath = fillableStroke(curve, width: 11)
        case .ws:
            let w = CGMutablePath()
            w.move(to: CGPoint(x: mx - 34, y: my - 4))
            w.addQuadCurve(to: CGPoint(x: mx - 8, y: my - 4),
                           control: CGPoint(x: mx - 21, y: my + 13))
            w.addQuadCurve(to: CGPoint(x: mx + 14, y: my - 4),
                           control: CGPoint(x: mx + 2, y: my + 13))
            w.addQuadCurve(to: CGPoint(x: mx + 38, y: my - 4),
                           control: CGPoint(x: mx + 26, y: my + 12))
            mouthPath = fillableStroke(w, width: 10)
        case .o:
            let r = headD * 0.055
            let disc = CGMutablePath()
            disc.addEllipse(in: CGRect(x: mx - r, y: my - r * 1.15, width: r * 2, height: r * 2.3))
            mouthPath = disc
        case .yawn:
            let r = headD * 0.12
            let disc = CGMutablePath()
            disc.addEllipse(in: CGRect(x: mx - r, y: my - r * 1.2, width: r * 2, height: r * 2.4))
            mouthPath = disc
        }
        surface.fill(mouthPath.applying(total), ink)
        if pose.mouth == .yawn, !spec.beak {
            surface.fill(ellipse(mx, my + headD * 0.10, headD * 0.07, headD * 0.045).applying(total),
                         tint.color(spec.accentHex, alpha: 0.85))
        }
        if spec.beak, spec.archetype == .nimbus {
            // The accent beak bump sits just under the mouth anchor.
            let beak = ellipse(mx, my + headD * 0.02, headD * 0.16, headD * 0.10).applying(total)
            surface.fill(beak, tint.color(spec.accentHex))
        }
    }

    private nonisolated static func drawAccessory<S: Surface>(
        _ surface: S, accessory: PuppetAccessory, spec: ToySpec,
        root: CGAffineTransform, tint: ToyTint
    ) {
        let accent = tint.color(spec.accentHex)
        switch accessory {
        case .bandana:
            var bib = CGMutablePath()
            bib.move(to: CGPoint(x: 424, y: 648))
            bib.addLine(to: CGPoint(x: 576, y: 648))
            bib.addQuadCurve(to: CGPoint(x: 500, y: 742), control: CGPoint(x: 556, y: 718))
            bib.addQuadCurve(to: CGPoint(x: 424, y: 648), control: CGPoint(x: 446, y: 718))
            bib.closeSubpath()
            surface.fill(bib.applying(root), accent)
        case .collar:
            surface.fill(ellipse(500, 650, 192, 48).applying(root), accent)
        case .charm:
            surface.fill(ellipse(500, 650, 192, 48).applying(root), accent)
            drawLeaf(surface, at: CGPoint(x: 500, y: 696), size: 26, transform: root,
                     color: RGBA("76C893"))
        case .bell:
            surface.fill(ellipse(500, 650, 192, 48).applying(root), accent)
            surface.fill(circle(500, 696, 22).applying(root), RGBA("FFE066"))
            surface.fill(ellipse(500, 696, 20, 8).applying(root),
                         tint.color(spec.inkHex, alpha: 0.5))
        }
    }

    private nonisolated static func drawLeaf<S: Surface>(
        _ surface: S, at point: CGPoint, size: CGFloat,
        transform: CGAffineTransform, color: RGBA
    ) {
        var leaf = CGMutablePath()
        leaf.move(to: CGPoint(x: point.x, y: point.y - size))
        leaf.addQuadCurve(to: CGPoint(x: point.x + size, y: point.y),
                          control: CGPoint(x: point.x + size * 0.60, y: point.y - size * 0.74))
        leaf.addQuadCurve(to: CGPoint(x: point.x, y: point.y + size),
                          control: CGPoint(x: point.x + size * 0.60, y: point.y + size * 0.74))
        leaf.addQuadCurve(to: CGPoint(x: point.x - size, y: point.y),
                          control: CGPoint(x: point.x - size * 0.60, y: point.y + size * 0.74))
        leaf.addQuadCurve(to: CGPoint(x: point.x, y: point.y - size),
                          control: CGPoint(x: point.x - size * 0.60, y: point.y - size * 0.74))
        leaf.closeSubpath()
        surface.fill(leaf.applying(transform), color)
    }

    private nonisolated static func drawProps<S: Surface>(
        _ surface: S, spec: ToySpec, props: PuppetProps,
        root: CGAffineTransform, shiftX: CGFloat, shiftY: CGFloat, tint: ToyTint
    ) {
        let headTop = 400 - spec.headDiameter / 2 + shiftY
        // Willow's tended sprout, riding the head.
        if props.sprout {
            let sx = 500 + shiftX
            let sy = headTop - 22
            var stem = CGMutablePath()
            stem.move(to: CGPoint(x: sx, y: sy))
            stem.addQuadCurve(to: CGPoint(x: sx, y: sy - 44), control: CGPoint(x: sx + 8, y: sy - 22))
            let stemPath = stem.copy(strokingWithWidth: 9, lineCap: .round, lineJoin: .round, miterLimit: 10)
            surface.fill(stemPath.applying(root), RGBA("76C893"))
            drawLeaf(surface, at: CGPoint(x: sx, y: sy - 54), size: 20, transform: root,
                     color: RGBA("76C893"))
        }
        // Compass's week audit on the ground.
        if props.weekTotal > 0 {
            for i in 0..<min(props.weekTotal, 7) {
                let x = 500 - 168 + CGFloat(i) * 56
                let lit = i < props.weekLit
                surface.fill(circle(x, 846, 15).applying(root),
                             tint.color(spec.accentHex, alpha: lit ? 0.95 : 0.26))
            }
        }
        // Prism's trinket.
        if props.trinket {
            var gem = CGMutablePath()
            gem.move(to: CGPoint(x: 730, y: 610))
            gem.addLine(to: CGPoint(x: 754, y: 640))
            gem.addLine(to: CGPoint(x: 730, y: 670))
            gem.addLine(to: CGPoint(x: 706, y: 640))
            gem.closeSubpath()
            surface.fill(gem.applying(root), tint.color(spec.accentHex, alpha: 0.9))
        }
        // The confidant memento.
        if props.mementoAlpha > 0 {
            let a = CGFloat(min(max(props.mementoAlpha, 0), 1))
            surface.fill(circle(752, 828, 34).applying(root),
                         tint.color(spec.accentHex, alpha: 0.18 * a))
            surface.fill(circle(752, 828, 20).applying(root),
                         tint.color(spec.accentHex, alpha: 0.9 * a))
        }
        // Cold vapor above the face.
        if props.vapor {
            let puffs: [(Double, Double, Double, Double)] = [
                (0, 96, 30, 0.30), (36, 128, 22, 0.22), (-32, 112, 18, 0.20)]
            for (dx, dy, r, alpha) in puffs {
                let puff = ellipse(500 + CGFloat(dx) + shiftX,
                                   headTop - CGFloat(dy), r * 2.4, r * 1.6)
                    .applying(root)
                surface.fill(puff, RGBA(r: 0.72, g: 0.76, b: 0.82, a: alpha))
            }
        }
        // The self-play mote (stage space — never deforms).
        if let mx = props.moteX, let my = props.moteY {
            let sparkle = sparklePath(CGFloat(mx) * 1000, CGFloat(my) * 1000, size: 16)
            surface.fill(sparkle, tint.color(spec.accentHex, alpha: 0.85))
        }
        // Nimbus's songburst.
        if props.songNotes {
            for (dx, dy) in [(-96.0, 96.0), (-140.0, 168.0)] {
                let x = 500 + CGFloat(dx) + shiftX
                let y = headTop + CGFloat(dy)
                surface.fill(circle(x, y, 16), tint.color(spec.accentHex, alpha: 0.95))
                var stem = CGMutablePath()
                stem.move(to: CGPoint(x: x + 14, y: y))
                stem.addLine(to: CGPoint(x: x + 14, y: y - 46))
                let stemPath = stem.copy(strokingWithWidth: 8, lineCap: .round, lineJoin: .round, miterLimit: 10)
                surface.fill(stemPath, tint.color(spec.accentHex, alpha: 0.95))
            }
        }
        // The greeting weather ceremonies.
        if props.umbrellaLeaf {
            drawLeaf(surface, at: CGPoint(x: 500 + shiftX, y: headTop - 148),
                     size: 84, transform: root, color: RGBA("76C893"))
        }
        if props.frostSparkle {
            for (dx, dy) in [(-188.0, 118.0), (192.0, 148.0), (-128.0, 182.0)] {
                surface.fill(
                    sparklePath(500 + CGFloat(dx) + shiftX, headTop + CGFloat(dy), size: 20),
                    RGBA(r: 0.85, g: 0.93, b: 1.0, a: 0.75))
            }
        }
        if props.sunnyBurst {
            for (dx, dy) in [(-210.0, 120.0), (216.0, 120.0)] {
                surface.fill(
                    sparklePath(500 + CGFloat(dx) + shiftX, headTop + CGFloat(dy), size: 18),
                    tint.color(spec.accentHex, alpha: 0.8))
            }
            surface.fill(
                sparklePath(500 + shiftX, headTop + spec.headDiameter + 26, size: 16),
                tint.color(spec.accentHex, alpha: 0.8))
        }
    }

    // MARK: - Path helpers

    nonisolated static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2), transform: nil)
    }

    nonisolated static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), transform: nil)
    }

    /// The squashed bean body (continuous rounded rect at half-height poles).
    nonisolated static func roundedBean(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
               cornerWidth: min(w, h) / 4, cornerHeight: h / 2, transform: nil)
    }

    /// A four-point diamond sparkle.
    nonisolated static func sparklePath(_ cx: CGFloat, _ cy: CGFloat, size: CGFloat) -> CGPath {
        var p = CGMutablePath()
        p.move(to: CGPoint(x: cx, y: cy - size))
        p.addQuadCurve(to: CGPoint(x: cx + size, y: cy),
                       control: CGPoint(x: cx + size * 0.14, y: cy - size * 0.14))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy + size),
                       control: CGPoint(x: cx + size * 0.14, y: cy + size * 0.14))
        p.addQuadCurve(to: CGPoint(x: cx - size, y: cy),
                       control: CGPoint(x: cx - size * 0.14, y: cy + size * 0.14))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy - size),
                       control: CGPoint(x: cx - size * 0.14, y: cy - size * 0.14))
        p.closeSubpath()
        return p
    }

    /// The lid cap: the part of a circle covered `coverage` (0...1) from
    /// its top — analytic chord intersection, no clipping needed.
    nonisolated static func circleCap(center: CGPoint, r: CGFloat, coverage: Double) -> CGPath {
        let c = min(max(coverage, 0), 1)
        guard c > 0.02 else { return CGMutablePath() }
        if c >= 0.995 {
            return circle(center.x, center.y, r * 1.02)
        }
        let dy = r * CGFloat(1 - 2 * c)
        let half = sqrt(max(0, r * r - dy * dy))
        let lineY = center.y + dy
        let left = CGPoint(x: center.x - half, y: lineY)
        let right = CGPoint(x: center.x + half, y: lineY)
        var p = CGMutablePath()
        p.move(to: left)
        // The covered region is the small arc side (the top of the eye as
        // the lids close downward): angles run through the top semicircle.
        let start = atan2(left.y - center.y, left.x - center.x)
        let end = atan2(right.y - center.y, right.x - center.x)
        p.addArc(center: center, radius: r, startAngle: start, endAngle: end,
                 clockwise: false)
        p.closeSubpath()
        return p
    }

    /// Fattens a stroke outline into a fillable path (round caps/joins —
    /// the no-sharp-corners rule applies to linework too).
    nonisolated static func fillableStroke(_ path: CGPath, width: CGFloat) -> CGPath {
        path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }
}

/// CGPath transform application via the stable C copy API (the Swift overlay
/// member moved across SDKs; this extension is the one source for it).
nonisolated extension CGPath {
    nonisolated func applying(_ transform: CGAffineTransform) -> CGPath {
        var t = transform
        return copy(using: &t) ?? self
    }
}
