import Foundation
import CoreGraphics
import ImageIO

// Column probe: prints mean luminance of a horizontal band around a center
// column, down the image — for verifying vertical shading ramps.
//   env -u SDKROOT xcrun --sdk macosx swift Tools/column_probe.swift <png> <x> [y0] [y1] [band] [step]

let args = CommandLine.arguments
guard args.count > 2,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fatalError("usage: column_probe.swift <png> <x> [y0=0] [y1=h] [band=6] [step=4]")
}
let w = img.width, h = img.height
let cx = Int(args[2]) ?? w / 2
let y0 = args.count > 3 ? Int(args[3]) ?? 0 : 0
let y1 = args.count > 4 ? Int(args[4]) ?? h : h
let band = args.count > 5 ? Int(args[5]) ?? 6 : 6
let step = args.count > 6 ? Int(args[6]) ?? 4 : 4

let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
let d = ctx.data!.assumingMemoryBound(to: UInt8.self)

var y = y0
while y < y1 {
    var s = 0.0
    var n = 0
    var rSum = 0.0, gSum = 0.0, bSum = 0.0
    for x in max(0, cx - band)..<min(w, cx + band) {
        let o = (y * w + x) * 4
        s += 0.299 * Double(d[o]) + 0.587 * Double(d[o + 1]) + 0.114 * Double(d[o + 2])
        rSum += Double(d[o]); gSum += Double(d[o + 1]); bSum += Double(d[o + 2])
        n += 1
    }
    let lum = s / Double(max(n, 1))
    let hex = String(format: "#%02X%02X%02X", Int(rSum / Double(max(n, 1))),
                     Int(gSum / Double(max(n, 1))), Int(bSum / Double(max(n, 1))))
    print(String(format: "y=%3d  lum=%5.1f  %@", y, lum, hex))
    y += step
}
