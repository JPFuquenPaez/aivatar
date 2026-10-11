import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
    .filter { $0.hasSuffix(".png") }
    .sorted() ?? []
for name in files {
    let url = URL(fileURLWithPath: "\(dir)/\(name)")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        print("\(name): FAILED to load")
        continue
    }
    let w = img.width, h = img.height
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { continue }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { continue }
    let bytes = data.assumingMemoryBound(to: UInt8.self)

    var nonBlack = 0
    var sumR = 0.0, sumG = 0.0, sumB = 0.0
    var brightR = 0.0, brightG = 0.0, brightB = 0.0, brightCount = 0.0
    var minX = w, maxX = 0, minY = h, maxY = 0
    let total = w * h
    for y in 0..<h {
        for x in 0..<w {
            let o = (y * w + x) * 4
            let r = Double(bytes[o]), g = Double(bytes[o + 1]), b = Double(bytes[o + 2])
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            if lum > 8 {
                nonBlack += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
            sumR += r; sumG += g; sumB += b
            if lum > 60 {
                brightR += r; brightG += g; brightB += b; brightCount += 1
            }
        }
    }
    let pct = Double(nonBlack) / Double(total) * 100
    let mean = (sumR / Double(total), sumG / Double(total), sumB / Double(total))
    let bbox = "bbox x[\(minX)..\(maxX)] y[\(minY)..\(maxY)]"
    if brightCount > 0 {
        let bright = (brightR / brightCount, brightG / brightCount, brightB / brightCount)
        print("\(name): \(w)x\(h), nonBlack=\(String(format: "%.1f", pct))%, mean=(\(String(format: "%.1f", mean.0)),\(String(format: "%.1f", mean.1)),\(String(format: "%.1f", mean.2))), brightAvg=(\(Int(bright.0)),\(Int(bright.1)),\(Int(bright.2))) from \(Int(brightCount)) px, \(bbox)")
    } else {
        print("\(name): \(w)x\(h), nonBlack=\(String(format: "%.1f", pct))%, mean=(\(String(format: "%.1f", mean.0)),\(String(format: "%.1f", mean.1)),\(String(format: "%.1f", mean.2))), NO BRIGHT PIXELS, \(bbox)")
    }

    // Coarse luminance map (16 x 20 cells): . = <4, - = <16, + = <48,
    // # = <128, @ = >=128. Shows whether a humanoid silhouette is present.
    let cells = 20
    let cellH = h / cells
    let cellW = w / 16
    var map = ""
    for cy in 0..<cells {
        for cx in 0..<16 {
            var maxLum = 0.0
            for y in (cy * cellH)..<min((cy + 1) * cellH, h) {
                for x in (cx * cellW)..<min((cx + 1) * cellW, w) {
                    let o = (y * w + x) * 4
                    let lum = 0.299 * Double(bytes[o]) + 0.587 * Double(bytes[o + 1]) + 0.114 * Double(bytes[o + 2])
                    maxLum = max(maxLum, lum)
                }
            }
            map += maxLum < 4 ? "." : maxLum < 16 ? "-" : maxLum < 48 ? "+" : maxLum < 128 ? "#" : "@"
        }
        map += "\n"
    }
    print(map)
}
