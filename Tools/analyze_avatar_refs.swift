import Foundation
import CoreGraphics
import ImageIO

// Avatar reference analyzer (host-side, macOS).
// Extracts design tokens from the v3 concept renders: an ASCII color map
// (one character per cell classifying the dominant hue family) plus the
// dominant color clusters with representative hex values and bboxes.
//
//   env -u SDKROOT xcrun --sdk macosx swift Tools/analyze_avatar_refs.swift <jpg> [jpg...]

func load(_ path: String) -> (bytes: [UInt8], w: Int, h: Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return nil }
    let bytes = [UInt8](UnsafeBufferPointer(
        start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
    return (bytes, w, h)
}

// Cell classification: character per hue family.
func classify(_ r: Double, _ g: Double, _ b: Double) -> Character {
    let mx = max(r, g, b), mn = min(r, g, b)
    let lum = 0.299 * r + 0.587 * g + 0.114 * b
    let sat = mx - mn
    if lum < 14 { return "." }                       // background black
    if lum > 235 && sat < 25 { return "#" }           // near-white (eyes catchlight, shine)
    if sat < 22 { return lum > 140 ? "W" : "D" }      // white / dark gray
    if b > r + 30 && b > g + 20 { return "B" }        // blue
    if g > r + 25 && g > b + 25 { return "G" }       // green
    if r > g + 40 && g > b + 20 { return "O" }       // orange
    if r > g + 60 && b > g + 30 { return "P" }       // magenta/pink
    if g > 130 && b > 130 && r < g - 20 { return "C" }// cyan
    if r > 150 && g > 130 && b < 100 { return "Y" }  // yellow
    if r > 130 && b > 120 && g < r - 10 && g < b + 20 { return "L" } // lavender
    return "w"                                        // other warm/light
}

for (index, path) in CommandLine.arguments.dropFirst().enumerated() {
    print("=== [\(index)] \((path as NSString).lastPathComponent) ===")
    guard let (bytes, w, h) = load(path) else { print("  failed to load"); continue }

    // ASCII map: 64 cols x 36 rows.
    let cols = 64, rows = 36
    var map: [Character] = []
    for ry in 0..<rows {
        for rx in 0..<cols {
            let x0 = rx * w / cols, y0 = ry * h / rows
            // Sample the cell's center-ish 2x2 and classify by mean.
            var rs = 0.0, gs = 0.0, bs = 0.0
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                let x = min(x0 + w / cols / 2 + dx, w - 1)
                let y = min(y0 + h / rows / 2 + dy, h - 1)
                let o = (y * w + x) * 4
                rs += Double(bytes[o]); gs += Double(bytes[o + 1]); bs += Double(bytes[o + 2])
            }
            map.append(classify(rs / 4, gs / 4, bs / 4))
        }
    }
    for ry in 0..<rows {
        let line = String(map[(ry * cols)..<(ry * cols + cols)])
        print(line)
    }

    // Dominant clusters (quantized 32/channel, excluding background).
    var counts: [UInt32: (n: Int, rSum: Double, gSum: Double, bSum: Double,
                          minX: Int, maxX: Int, minY: Int, maxY: Int)] = [:]
    for y in 0..<h {
        for x in 0..<w {
            let o = (y * w + x) * 4
            let r = Double(bytes[o]), g = Double(bytes[o + 1]), b = Double(bytes[o + 2])
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            if lum < 16 { continue }
            let key = (UInt32(r / 32) << 10) | (UInt32(g / 32) << 5) | UInt32(b / 32)
            var c = counts[key] ?? (0, 0, 0, 0, x, x, y, y)
            c.n += 1; c.rSum += r; c.gSum += g; c.bSum += b
            c.minX = min(c.minX, x); c.maxX = max(c.maxX, x)
            c.minY = min(c.minY, y); c.maxY = max(c.maxY, y)
            counts[key] = c
        }
    }
    let top = counts.values.sorted { $0.n > $1.n }.prefix(12)
    for c in top {
        let r = Int(c.rSum / Double(c.n)), g = Int(c.gSum / Double(c.n)), b = Int(c.bSum / Double(c.n))
        print(String(format: "  #%02X%02X%02X  %5.1f%%  bbox x[%d..%d] y[%d..%d]",
                     r, g, b, 100.0 * Double(c.n) / Double(w * h),
                     c.minX, c.maxX, c.minY, c.maxY))
    }
}
