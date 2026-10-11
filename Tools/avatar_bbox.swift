import Foundation
import CoreGraphics
import ImageIO

// Avatar composition probe (host-side, macOS): the avatar is the only
// *saturated* content on the pure-black stage (§8) — status-bar time and
// the name/state text (§9) are white/gray. Scanning for saturated pixels
// measures the avatar's bbox, screen-fill fraction, and margins to the top
// clock and bottom text without needing a golden reference.
//
//   env -u SDKROOT xcrun --sdk macosx swift Tools/avatar_bbox.swift <png>

guard CommandLine.arguments.count > 1,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("usage: avatar_bbox.swift <png>")
    exit(1)
}
let w = img.width, h = img.height
guard let ctx = CGContext(
    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
), let data = ctx.data else { exit(1) }
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
let bytes = data.assumingMemoryBound(to: UInt8.self)

var minX = w, maxX = 0, minY = h, maxY = 0, count = 0
for y in 0..<h {
    for x in 0..<w {
        let o = (y * w + x) * 4
        let r = Int(bytes[o]), g = Int(bytes[o + 1]), b = Int(bytes[o + 2])
        let mx = max(r, g, b), mn = min(r, g, b)
        if mx > 40, mx - mn > 35 {   // saturated + non-dim = avatar sprite
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            count += 1
        }
    }
}
guard count > 0 else { print("no avatar pixels found"); exit(1) }
let bw = maxX - minX + 1, bh = maxY - minY + 1
print(String(format: "bbox x[%d..%d] y[%d..%d]  %dx%d px", minX, maxX, minY, maxY, bw, bh))
print(String(format: "height fill: %.0f%% of %d  |  width fill: %.0f%% of %d",
              100.0 * Double(bh) / Double(h), h,
              100.0 * Double(bw) / Double(w), w))
print(String(format: "vertical center at %.0f%% of screen height", 100.0 * Double(minY + maxY) / 2.0 / Double(h)))
print(String(format: "margins: top %d px, bottom %d px, left %d px, right %d px",
              minY, h - 1 - maxY, minX, w - 1 - maxX))
