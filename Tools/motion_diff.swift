import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Motion diff (host-side, macOS): fraction of pixels that changed between
// two simulator screenshots. Verifies the avatar visibly moves between
// blinks — the "is it alive?" check. The post-polish assessment found the
// L1 amplitudes left only ~2% of pixels moving per second; this tool keeps
// that regression measurable.
//
//   env -u SDKROOT xcrun --sdk macosx swift Tools/motion_diff.swift a.png b.png [threshold]

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

let args = CommandLine.arguments
guard args.count >= 3,
      let a = load(args[1]), let b = load(args[2]) else {
    print("usage: motion_diff.swift a.png b.png [threshold=6]")
    exit(1)
}
guard a.w == b.w, a.h == b.h else {
    print("FAIL: image dimensions differ (\(a.w)x\(a.h) vs \(b.w)x\(b.h))")
    exit(1)
}
let threshold = args.count > 3 ? (Double(args[3]) ?? 6) : 6

var changed = 0
var changedSum = 0.0
let total = a.w * a.h
for i in 0..<total {
    let o = i * 4
    let dA = abs(Double(a.bytes[o]) - Double(b.bytes[o]))
        + abs(Double(a.bytes[o + 1]) - Double(b.bytes[o + 1]))
        + abs(Double(a.bytes[o + 2]) - Double(b.bytes[o + 2]))
    if dA > threshold {
        changed += 1
        changedSum += dA
    }
}
let pct = 100.0 * Double(changed) / Double(total)
print(String(format: "changed %d/%d pixels (%.1f%%), mean delta %.1f over changed pixels",
             changed, total, pct, changedSum / Double(max(changed, 1))))
