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
/// Grid window (v8): the rig region visible on a canonical 184x224 pt
/// screen under the pixel stage composition — at 3.0 rig units per sprite
/// pixel the 64x78 grid covers ~192 x 234 rig units (rig x in [-96, +96],
/// rig y in [-152, +82] with the content centered 35.5 rig units above
/// the rig origin at grid center), leaving 1-2 sprite px of padding
/// around the sprite so the widest pose never clips (§6, PIXEL_DESIGN.md
/// v2). The v5 bump from 51x63 to 64x78 kept the detail class a step above
/// simple pixel mascots (3-4 tone ramps and 4x3 px eyes stay legible).
nonisolated final class PixelStageRasterizer {
    static let gridWidth = 64
    static let gridHeight = 78

    /// Rig units per sprite pixel. v8: 3.0 (was 2.72) — chunkier pixels
    /// (Derek Yu's rule: important forms get real pixel mass) AND the
    /// wider window (192 x 234 rig units) leaves 1-2 sprite px of padding
    /// around the sprite so the widest pose (a full spin) never clips the
    /// grid edge (Tools/PIXEL_DESIGN.md v2 §6).
    private static let rigUnitsPerPixel: CGFloat = 3.0
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
    /// v9 LUT bucket for the post-snap ambient-mote pass — nil if the
    /// painter supplied no mote tone. (The v6-8 silhouette halo is GONE:
    /// the icon brand rules forbid outlines/frames.)
    private let moteBucket: Int?
    /// v9 test hook: the stage tones (motes) as LUT colors, so palette and
    /// silhouette assertions measure the AVATAR without the dust.
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
        // v7 (§1, Tools/PIXEL_DESIGN.md): the authored ramp stops join the
        // LUT — gradient pixels then quantize to the authored 3-4 tone
        // cel ramps (role + lifted top + deepened bottom) instead of
        // snapping to whatever palette color happens to be nearest.
        for tone in painter.rampTonesForRasterizer {
            if !colors.contains(where: { $0.0 == tone.0 && $0.1 == tone.1 && $0.2 == tone.2 }) {
                colors.append(tone)
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
        // v9: the active-frame snap candidates exclude every STAGE tone —
        // restDim (the old face-mud fix) and mote, which exist only for the
        // post-snap passes and must never be picked as a paint color.
        let stageTones: [(Float, Float, Float)] = [.restDim, .mote]
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
        moteBucket = bucket(of: .mote)
        stageTonesForTesting = [.mote].compactMap { painter.roleColors[$0] }
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
        // v9 stage pass, after the snap so motes are written as an exact LUT
        // tone: the drifting ambient dust. Active mode only — the rest LOD
        // keeps the stage sunk near-black (OLED power + dim-sleep).
        if !rest {
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
            // v7 edge-clean dithering (§2, Tools/PIXEL_DESIGN.md): only
            // FULLY-covered interior pixels may dither between the two
            // nearest ramp tones (the classic hi-bit cel texture).
            // Antialiased shape boundaries snap clean to the nearest tone
            // — a dithered fringe reads as noise, not as pixel art.
            if a >= 250, secondDist > bestDist + 1 {
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

    /// v8 test hook: the number of ACTIVE snap candidates — the palette
    /// budget (Tools/PIXEL_DESIGN.md v2 §3 caps it at 12 colors; stage
    /// tones and restDim are excluded by construction).
    var activeSnapCandidateCountForTesting: Int { activeSnapLUT.count }
}
