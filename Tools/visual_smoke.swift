import Foundation
import CoreGraphics
import ImageIO

// Visual smoke analyzer (host-side, macOS).
//
// Asserts that each archetype's simulator screenshot contains the avatar:
//   1. coverage — enough non-black pixels to be a rendered scene,
//   2. region   — bright pixels in the avatar band (center ~70%, face in
//      the upper area, §9) — excludes the status-bar time (top right) and
//      the name text (bottom),
//   3. centroid — the avatar body is horizontally centered,
//   4. palette  — the bright-pixel average matches the archetype's palette
//      family (catches "rendered white / wrong colors").
//
// Exit 0 = all five archetypes pass; exit 1 = failure (printed per line).
// Catches the class of bug where the engine tests are green but the avatar
// is off-screen or invisible (post-A4 verification found exactly that).

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func analyze(path: String) -> (coverage: Double, regionBright: Int, centroidX: Double, avg: (Double, Double, Double)) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        return (0, 0, 0, (0, 0, 0))
    }
    let w = img.width, h = img.height
    guard w > 0, h > 0,
          let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        return (0, 0, 0, (0, 0, 0))
    }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return (0, 0, 0, (0, 0, 0)) }
    let bytes = data.assumingMemoryBound(to: UInt8.self)

    var nonBlack = 0
    var brightR = 0.0, brightG = 0.0, brightB = 0.0, brightCount = 0.0
    var regionBright = 0
    var regionSumX = 0.0
    // Avatar band: excludes status-bar time (top right) and name text (bottom).
    let regionX0 = Int(Double(w) * 0.15), regionX1 = Int(Double(w) * 0.68)
    let regionY0 = Int(Double(h) * 0.05), regionY1 = Int(Double(h) * 0.65)
    for y in 0..<h {
        for x in 0..<w {
            let o = (y * w + x) * 4
            let r = Double(bytes[o]), g = Double(bytes[o + 1]), b = Double(bytes[o + 2])
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            if lum > 8 { nonBlack += 1 }
            if lum > 60 {
                brightR += r; brightG += g; brightB += b; brightCount += 1
                if x >= regionX0 && x < regionX1 && y >= regionY0 && y < regionY1 {
                    regionBright += 1
                    regionSumX += Double(x)
                }
            }
        }
    }
    let coverage = Double(nonBlack) / Double(w * h)
    let avg: (Double, Double, Double) = brightCount > 0
        ? (brightR / brightCount, brightG / brightCount, brightB / brightCount)
        : (0, 0, 0)
    let centroidX = regionBright > 0 ? regionSumX / Double(regionBright) / Double(w) : 0
    return (coverage, regionBright, centroidX, avg)
}

let paletteChecks: [(name: String, desc: String, check: (Double, Double, Double) -> Bool)] = [
    ("ember", "warm (R>B)", { r, g, b in r > b }),
    ("willow", "green (G>B)", { r, g, b in g > b }),
    ("compass", "cool (B>R)", { r, g, b in b > r }),
    ("prism", "magenta (B>G)", { r, g, b in b > g }),
    ("nimbus", "lavender (B>G)", { r, g, b in b > g }),
]

var failed = false
print("archetype | coverage | regionBright | centroidX | brightAvg          | result")
for entry in paletteChecks {
    let s = analyze(path: "\(dir)/smoke-\(entry.name).png")
    var reasons: [String] = []
    if s.coverage < 0.03 {
        reasons.append("coverage \(String(format: "%.1f", s.coverage * 100))% < 3% (screen nearly black?)")
    }
    if s.regionBright < 1500 {
        reasons.append("region bright px \(s.regionBright) < 1500 (avatar missing from its band?)")
    }
    if !(0.25...0.75).contains(s.centroidX) {
        reasons.append("centroidX \(String(format: "%.2f", s.centroidX)) outside 0.25...0.75 (avatar not centered?)")
    }
    if !entry.check(s.avg.0, s.avg.1, s.avg.2) {
        reasons.append("palette \(entry.desc) violated: (\(Int(s.avg.0)),\(Int(s.avg.1)),\(Int(s.avg.2)))")
    }
    let ok = reasons.isEmpty
    if !ok { failed = true }
    let line = "\(entry.name) | \(String(format: "%.1f%%", s.coverage * 100)) | \(s.regionBright) | \(String(format: "%.2f", s.centroidX)) | (\(Int(s.avg.0)),\(Int(s.avg.1)),\(Int(s.avg.2))) | \(ok ? "PASS" : reasons.joined(separator: "; "))"
    print(line)
}

if failed {
    print("VISUAL SMOKE TEST: FAIL")
    exit(1)
}
print("VISUAL SMOKE TEST: PASS")
