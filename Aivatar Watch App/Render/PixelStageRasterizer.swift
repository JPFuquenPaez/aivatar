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
    /// Snap candidates for ACTIVE frames (the LUT minus the stage/rest
    /// tones — see the init comment). Rest frames snap against the full `lut`.
    private let activeSnapLUT: [(Float, Float, Float)]
    private let lutColors: [Color]
    /// Pixel indices per LUT color, reused across frames (no allocation
    /// in the steady state; rebuilt contents only).
    private var pixelsByColor: [[Int]]
    /// v6 LUT bucket indices for the post-snap stage passes (halo dilation,
    /// ambient motes) — nil if the painter supplied no such tone.
    private let haloBucket: Int?
    private let moteBucket: Int?
    /// v6 test hook: the stage tones (halo, mote) as LUT colors, so palette
    /// assertions can measure the BODY tones without the contour/dust.
    let stageTonesForTesting: [(Float, Float, Float)]
    /// v6 Bayer 4x4 ordered-dither thresholds, normalized to (0, 1).
    private static let bayer4: [[Float]] = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5],
    ].map { $0.map { ($0 + 0.5) / 16 } }
    /// v6 ambient motes: fixed pseudo-random rest positions (one seeded
    /// draw at init), drifted purely as a function of the frame index, so
    /// the field is deterministic for a given frame and allocates nothing.
    private static let moteCount = 7
    private let moteBaseX: [Int]
    private let moteBaseY: [Int]

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
        // v6: the active-frame snap candidates exclude every STAGE tone —
        // restDim (the old face-mud fix), plus halo and mote, which exist
        // only for the post-snap passes and must never be picked as a paint
        // color (a body pixel dithering toward halo would smear gray).
        let stageTones: [(Float, Float, Float)] = [.restDim, .halo, .mote]
            .compactMap { painter.roleColors[$0] }
        activeSnapLUT = colors.filter { c in
            !stageTones.contains { $0.0 == c.0 && $0.1 == c.1 && $0.2 == c.2 }
        }
        lutColors = colors.map { Color(.sRGB, red: Double($0.0), green: Double($0.1), blue: Double($0.2)) }
        pixelsByColor = colors.map { _ in [] }
        // Bucket lookup over a local copy of the LUT (no self method call
        // before the remaining stored properties are initialized).
        let lutLocal = lut
        func bucket(of role: PaletteRole) -> Int? {
            guard let c = painter.roleColors[role] else { return nil }
            return lutLocal.firstIndex { $0.0 == c.0 && $0.1 == c.1 && $0.2 == c.2 }
        }
        haloBucket = bucket(of: .halo)
        moteBucket = bucket(of: .mote)
        stageTonesForTesting = [.halo, .mote].compactMap { painter.roleColors[$0] }
        var moteRng = SeededRandom(0x90_7E_5E_ED)
        moteBaseX = (0..<Self.moteCount).map { _ in Int(moteRng.nextFloat() * Float(Self.gridWidth)) }
        moteBaseY = (0..<Self.moteCount).map { _ in Int(moteRng.nextFloat() * Float(Self.gridHeight)) }

        // Rig space is y-down with the origin at the canvas center; flip
        // for y-up CG so buffer row 0 is the visual top (same convention
        // as the golden rasterizer).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
    }

    /// Rasterizes the painter's current command buffer into the grid and
    /// snaps pixels to the LUT. Call after painter.paint(...). `rest`
    /// selects the snap candidates (full LUT in rest mode, stage-tone-free
    /// in active mode). `frame` drives the v6 ambient motes (deterministic
    /// function of the frame index); the live renderer passes the engine
    /// clock's frame, tests may rely on the default 0.
    func rasterize(painter: AvatarSpritePainter, rest: Bool = false, frame: Int = 0) {
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
        // v6 stage passes, after the snap so they are written as exact LUT
        // tones: the 1-px silhouette halo, then the drifting ambient motes.
        // Active mode only — the rest LOD keeps the stage sunk near-black
        // (OLED power + the dim-sleep aesthetic), no contour, no dust.
        if !rest {
            applyHalo()
            applyMotes(frame: frame)
        }
    }

    /// Snaps every lit grid pixel to a snap-candidate color (background
    /// stays pure black). v6: pixels that fall BETWEEN two LUT tones —
    /// gradient ramps and antialiased edges — are resolved by Bayer 4x4
    /// ordered dithering between the two nearest candidates instead of a
    /// hard nearest pick, the classic hi-bit texture (flat areas, where
    /// the nearest candidate is exact, never dither). Every written pixel
    /// is still exactly one LUT color, so the snap invariant holds.
    private func snapToLUT(rest: Bool) {
        let candidates = rest ? lut : activeSnapLUT
        guard let data = context.data else { return }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let width = Self.gridWidth
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
            // Unpremultiply, then find the TWO nearest candidates by RGB
            // distance (single pass, no allocation).
            let inv = 255.0 / Double(a)
            let r = min(255.0, Double(bytes[o]) * inv)
            let g = min(255.0, Double(bytes[o + 1]) * inv)
            let b = min(255.0, Double(bytes[o + 2]) * inv)
            var bestColor = candidates[0]
            var bestDist = Double.greatestFiniteMagnitude
            var secondColor = candidates[0]
            var secondDist = Double.greatestFiniteMagnitude
            for color in candidates {
                let dr = r - Double(color.0) * 255
                let dg = g - Double(color.1) * 255
                let db = b - Double(color.2) * 255
                let d = dr * dr + dg * dg + db * db
                if d < bestDist {
                    secondColor = bestColor; secondDist = bestDist
                    bestColor = color; bestDist = d
                } else if d < secondDist {
                    secondColor = color; secondDist = d
                }
            }
            var chosen = bestColor
            if secondDist > bestDist + 1 {
                // How far between the tones the pixel sits: 0 = exact
                // match (flat — never dithers), -> 1 = equidistant.
                let t = bestDist / secondDist
                let threshold = Double(Self.bayer4[(i / width) % 4][i % 4])
                if t > threshold { chosen = secondColor }
            }
            bytes[o] = UInt8(chosen.0 * 255)
            bytes[o + 1] = UInt8(chosen.1 * 255)
            bytes[o + 2] = UInt8(chosen.2 * 255)
            bytes[o + 3] = 255
            if let bucket = lut.firstIndex(where: { $0.0 == chosen.0 && $0.1 == chosen.1 && $0.2 == chosen.2 }) {
                pixelsByColor[bucket].append(i)
            }
        }
    }

    /// v6 halo: a 1-px dilation of the silhouette into the background,
    /// filled with the dim `halo` LUT tone — the pixel-mascot sticker
    /// contour (on the OLED black stage the outline must be LIGHT to
    /// read). The ring is Bayer-dithered at ~45% density so it reads as a
    /// dashed hi-bit contour, not a solid gray outline, and stays well
    /// under the body tones in pixel count. Collected against the snapped
    /// state first, then written, so the pass dilates exactly one pixel
    /// and never chains.
    private func applyHalo() {
        guard let data = context.data, let haloBucket else { return }
        let haloColor = lut[haloBucket]
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let width = Self.gridWidth
        let height = Self.gridHeight
        let count = width * height
        var haloPixels: [Int] = []
        haloPixels.reserveCapacity(160)
        func lit(_ i: Int) -> Bool {
            let o = i * 4
            return Int(bytes[o]) + Int(bytes[o + 1]) + Int(bytes[o + 2]) > 24
        }
        for i in 0..<count {
            let o = i * 4
            guard Int(bytes[o]) + Int(bytes[o + 1]) + Int(bytes[o + 2]) <= 24 else { continue }
            let x = i % width, y = i / width
            let neighborLit = (x > 0 && lit(i - 1)) || (x < width - 1 && lit(i + 1))
                || (y > 0 && lit(i - width)) || (y < height - 1 && lit(i + width))
            guard neighborLit else { continue }
            if Self.bayer4[y % 4][x % 4] <= 0.45 { haloPixels.append(i) }
        }
        for i in haloPixels {
            let o = i * 4
            bytes[o] = UInt8(haloColor.0 * 255)
            bytes[o + 1] = UInt8(haloColor.1 * 255)
            bytes[o + 2] = UInt8(haloColor.2 * 255)
            bytes[o + 3] = 255
        }
        pixelsByColor[haloBucket].append(contentsOf: haloPixels)
    }

    /// v6 ambient motes: a sparse field of dim accent-colored dust drifting
    /// slowly upward and twinkling, so the stage itself feels alive between
    /// gestures (tamagotchi-stage best practice). Positions are a pure
    /// function of `frame` (no RNG on the frame path, no allocation beyond
    /// the bucket append); motes land only on background pixels.
    private func applyMotes(frame: Int) {
        guard let data = context.data, let moteBucket else { return }
        let moteColor = lut[moteBucket]
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let width = Self.gridWidth
        let height = Self.gridHeight
        let f = Float(frame)
        for m in 0..<Self.moteCount {
            let phase = Float(m) * 2.399 // golden-angle spread
            let twinkle = 0.5 + 0.5 * sin(f * 0.045 + phase)
            guard twinkle > 0.62 else { continue }
            let speed = 0.11 + 0.05 * Float(m % 3)
            var y = (Float(moteBaseY[m]) - f * speed).truncatingRemainder(dividingBy: Float(height))
            if y < 0 { y += Float(height) }
            let x = moteBaseX[m]
            let i = Int(y) * width + x
            let o = i * 4
            guard Int(bytes[o]) + Int(bytes[o + 1]) + Int(bytes[o + 2]) <= 24 else { continue }
            bytes[o] = UInt8(moteColor.0 * 255)
            bytes[o + 1] = UInt8(moteColor.1 * 255)
            bytes[o + 2] = UInt8(moteColor.2 * 255)
            bytes[o + 3] = 255
            pixelsByColor[moteBucket].append(i)
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
