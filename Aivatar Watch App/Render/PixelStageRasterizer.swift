import SwiftUI
import CoreGraphics

/// Hi-bit pixel rasterizer (§11.3, v4 direction — v5 DEFAULT stage):
/// renders the painter's command buffer into a 64x78 logical-pixel grid —
/// one sprite pixel covers ~2.7 rig units (~3.2 screen points, no
/// smoothing) — and snaps every pixel to the archetype's vivid LUT. The
/// stage draws the grid as flat rects: nearest-neighbor by construction,
/// no image upload, no resampling. The engine, poses and tells are
/// unchanged — this changes only the presentation layer ("pixel style
/// changes the renderer, not the character").
///
/// Grid window: the rig region visible on a canonical 184x224 pt screen
/// under the vector stage composition (StageComposition zoom 1.18):
/// rig x in [-87, +87], content centered 35.5 rig units above the rig
/// origin at grid center — the pixel stage shows the same framing as the
/// vector stage did, so composition tests carry over. The v5 bump from
/// 51x63 to 64x78 keeps the same window (~174 x 214 rig units) and
/// raises the detail class a step (§11.3: "more detail" than simple
/// pixel mascots; 3-4 tone ramps and 4x3 px eyes stay legible).
nonisolated final class PixelStageRasterizer {
    static let gridWidth = 64
    static let gridHeight = 78

    /// Rig units per sprite pixel (grid covers ~174 x 212 rig units).
    private static let rigUnitsPerPixel: CGFloat = 2.72
    /// Content center (rig y, relative to the rig origin) placed at the
    /// grid center — matches StageComposition.contentCenterY.
    private static let contentCenterY: CGFloat = -35.5

    private let context: CGContext
    private let lut: [(Float, Float, Float)]
    /// Snap candidates for ACTIVE frames (the LUT minus restDim — see
    /// the init comment). Rest frames snap against the full `lut`.
    private let activeSnapLUT: [(Float, Float, Float)]
    private let lutColors: [Color]
    /// Pixel indices per LUT color, reused across frames (no allocation
    /// in the steady state; rebuilt contents only).
    private var pixelsByColor: [[Int]]

    init(painter: AvatarSpritePainter) {
        let width = Self.gridWidth
        let height = Self.gridHeight
        context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // LUT: the archetype's palette roles (the gradient tops/bottoms
        // derive from these, so snapped ramps produce the 3-4 tone hi-bit
        // body ramps by construction) plus pure white for the catchlight
        // and rim glow. Sorted for deterministic iteration and pinning.
        // The REST-DIM color is EXCLUDED from the active LUT: with it
        // present, antialiased blends between bright body tones and the
        // dark face color snapped to restDim and smeared muddy
        // dark-brown pixels across the face (the A6.1 bug).
        var colors: [(Float, Float, Float)] = []
        for (role, color) in painter.roleColors {
            if !colors.contains(where: { $0.0 == color.0 && $0.1 == color.1 && $0.2 == color.2 }) {
                colors.append(color)
            }
        }
        if !colors.contains(where: { $0.0 >= 0.999 && $0.1 >= 0.999 && $0.2 >= 0.999 }) {
            colors.append((1, 1, 1))
        }
        colors.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.2 < b.2
        }
        lut = colors
        // Active-frame snap candidates: the LUT WITHOUT the rest-dim
        // color. With restDim present, antialiased blends between bright
        // body tones and the dark face color snapped to it and smeared
        // muddy dark pixels across the face (the A6.1 bug). Rest frames
        // snap with the full LUT so restDim stays exact (the sleep pose
        // is all restDim + face).
        let restDim = painter.roleColors[.restDim] ?? (0, 0, 0)
        activeSnapLUT = colors.filter { !($0.0 == restDim.0 && $0.1 == restDim.1 && $0.2 == restDim.2) }
        lutColors = colors.map { Color(.sRGB, red: Double($0.0), green: Double($0.1), blue: Double($0.2)) }
        pixelsByColor = colors.map { _ in [] }

        // Rig space is y-down with the origin at the canvas center; flip
        // for y-up CG so buffer row 0 is the visual top (same convention
        // as the golden rasterizer).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
    }

    /// Rasterizes the painter's current command buffer into the grid and
    /// snaps pixels to the LUT. Call after painter.paint(...). `rest`
    /// selects the snap candidates (full LUT in rest mode, restDim-free
    /// in active mode).
    func rasterize(painter: AvatarSpritePainter, rest: Bool = false) {
        let ctx = context
        let k = 1 / Self.rigUnitsPerPixel
        let centerX = CGFloat(Self.gridWidth) / 2
        let centerY = CGFloat(Self.gridHeight) / 2 - Self.contentCenterY * k
        let rgb = CGColorSpaceCreateDeviceRGB()

        ctx.setFillColor(CGColor(colorSpace: rgb, components: [0, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: Self.gridWidth, height: Self.gridHeight))

        for i in 0..<painter.commandCount {
            let command = painter.commands[i]
            let shape = painter.shapes[command.shapeIndex]
            ctx.saveGState()
            ctx.translateBy(
                x: centerX + CGFloat(command.tx) * k,
                y: centerY + CGFloat(command.ty) * k
            )
            ctx.rotate(by: CGFloat(command.rotation))
            ctx.scaleBy(x: CGFloat(command.scaleX) * k, y: CGFloat(command.scaleY) * k)
            ctx.addPath(shape.paths[command.pathIndex])
            if command.useGradient {
                // Same span math as the vector path (whole-shape spans for
                // bend slices, per-path for the cloud puffs); the CG
                // rasterizer's clipped gradient fill matches the Canvas
                // implementation.
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
                    CGColor(colorSpace: rgb, components: [
                        CGFloat(command.r), CGFloat(command.g), CGFloat(command.b), 1
                    ])!,
                    CGColor(colorSpace: rgb, components: [
                        CGFloat(command.r2), CGFloat(command.g2), CGFloat(command.b2), 1
                    ])!
                ]
                let gradient = CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: [0, 1])!
                ctx.clip()
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: startY),
                    end: CGPoint(x: 0, y: endY),
                    options: []
                )
            } else {
                ctx.setFillColor(CGColor(colorSpace: rgb, components: [
                    CGFloat(command.r), CGFloat(command.g), CGFloat(command.b), CGFloat(command.a)
                ])!)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }

        snapToLUT(rest: rest)
    }

    /// Snaps every lit grid pixel to the nearest snap-candidate color
    /// (background stays pure black). Edge antialiasing from the raster
    /// becomes the classic fat-pixel boundary instead of a blur. The
    /// snapped color is then located in the FULL LUT for the draw-side
    /// buckets (restDim never appears in active frames by construction).
    private func snapToLUT(rest: Bool) {
        let candidates = rest ? lut : activeSnapLUT
        guard let data = context.data else { return }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let count = Self.gridWidth * Self.gridHeight
        for bucket in pixelsByColor.indices {
            pixelsByColor[bucket].removeAll(keepingCapacity: true)
        }
        for i in 0..<count {
            let o = i * 4
            let a = bytes[o + 3]
            // Background stays PURE BLACK (§2 OLED power strategy): the
            // raster's black clear would otherwise snap to the darkest
            // LUT color and paint the whole stage with it.
            if a < 96 || Int(bytes[o]) + Int(bytes[o + 1]) + Int(bytes[o + 2]) < 24 {
                bytes[o] = 0; bytes[o + 1] = 0; bytes[o + 2] = 0; bytes[o + 3] = 255
                continue
            }
            // Unpremultiply, then nearest-candidate by RGB distance.
            let inv = 255.0 / Double(a)
            let r = min(255.0, Double(bytes[o]) * inv)
            let g = min(255.0, Double(bytes[o + 1]) * inv)
            let b = min(255.0, Double(bytes[o + 2]) * inv)
            var bestColor = candidates[0]
            var bestDist = Double.greatestFiniteMagnitude
            for color in candidates {
                let dr = r - Double(color.0) * 255
                let dg = g - Double(color.1) * 255
                let db = b - Double(color.2) * 255
                let d = dr * dr + dg * dg + db * db
                if d < bestDist { bestDist = d; bestColor = color }
            }
            bytes[o] = UInt8(bestColor.0 * 255)
            bytes[o + 1] = UInt8(bestColor.1 * 255)
            bytes[o + 2] = UInt8(bestColor.2 * 255)
            bytes[o + 3] = 255
            if let bucket = lut.firstIndex(where: { $0.0 == bestColor.0 && $0.1 == bestColor.1 && $0.2 == bestColor.2 }) {
                pixelsByColor[bucket].append(i)
            }
        }
    }

    /// Draws the snapped grid as flat rects — every sprite pixel is a
    /// crisp rect of an exact LUT color (nearest-neighbor upscale with no
    /// resampling). Fills the canvas; the grid is 51:63 ≈ the rig aspect.
    func draw(into ctx: GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        let sx = size.width / CGFloat(Self.gridWidth)
        let sy = size.height / CGFloat(Self.gridHeight)
        for (index, pixels) in pixelsByColor.enumerated() where !pixels.isEmpty {
            var path = Path()
            for i in pixels {
                let x = CGFloat(i % Self.gridWidth)
                let y = CGFloat(i / Self.gridWidth)
                path.addRect(CGRect(x: x * sx, y: y * sy, width: sx, height: sy))
            }
            ctx.fill(path, with: .color(lutColors[index]))
        }
    }

    // MARK: - Testing

    /// The snapped grid as RGBA8 bytes (row-major, visual top row first) —
    /// the pixel-frame pin surface for golden tests. Deterministic for a
    /// given engine pose + painter state.
    func snapshotBytes() -> [UInt8] {
        guard let data = context.data else { return [] }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return [UInt8](UnsafeBufferPointer(start: bytes, count: Self.gridWidth * Self.gridHeight * 4))
    }

    var lutForTesting: [(Float, Float, Float)] { lut }
}
