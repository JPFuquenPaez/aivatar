// Fine luminance map for a single screenshot — higher resolution than
// analyze_screenshot.swift's overview map, with a focus region. Used to
// verify silhouette changes (e.g. the Nimbus brand-cloud head).
//
// Usage: env -u SDKROOT xcrun --sdk macosx swift Tools/fine_luminance_map.swift <image.png> [y0 y1] [cols]
// y0/y1 default to the full frame; cols defaults to 64.

import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
guard args.count >= 2,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fatalError("usage: fine_luminance_map.swift <image.png> [y0 y1] [cols]")
}
let y0 = args.count > 3 ? Int(args[2]) ?? 0 : 0
let y1 = args.count > 3 ? Int(args[3]) ?? img.height : img.height
let cols = args.count > 4 ? Int(args[4]) ?? 64 : 64

let w = img.width, h = img.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
let d = ctx.data!.assumingMemoryBound(to: UInt8.self)

func lum(_ x: Int, _ y: Int) -> Double {
    let o = (y * w + x) * 4
    return (0.299 * Double(d[o]) + 0.587 * Double(d[o + 1]) + 0.114 * Double(d[o + 2])) / 255.0
}

let chars: [Character] = [" ", ".", ":", "-", "=", "+", "*", "#", "%", "@"]
let rows = max(4, (cols * (y1 - y0)) / (w * 2)) // keep ~2:1 char aspect
for r in 0..<rows {
    var line = ""
    for c in 0..<cols {
        let x0 = c * w / cols, x1 = (c + 1) * w / cols
        let ya = y0 + (y1 - y0) * r / rows
        let yb = y0 + (y1 - y0) * (r + 1) / rows
        var s = 0.0, n = 0
        for y in stride(from: ya, to: max(ya + 1, yb), by: 4) {
            for x in stride(from: x0, to: max(x0 + 1, x1), by: 4) { s += lum(x, y); n += 1 }
        }
        let v = s / Double(n)
        line.append(chars[min(chars.count - 1, Int(v * Double(chars.count) * 1.5))])
    }
    print(line)
}
