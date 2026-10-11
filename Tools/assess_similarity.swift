// Pairwise similarity of the five archetype screenshots: silhouette IoU,
// per-pixel RGB disagreement, dominant colors. Assessment tool (scratch).
//
// Usage: env -u SDKROOT xcrun --sdk macosx swift Tools/assess_similarity.swift <dir>
// where dir contains ember.png willow.png compass.png prism.png nimbus.png

import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
let dir = args.count > 1 ? args[1] : "/tmp/assess"
let names = ["ember", "willow", "compass", "prism", "nimbus"]
var imgs: [String: (w: Int, h: Int, data: [UInt8])] = [:]
for n in names {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: "\(dir)/\(n).png") as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fatalError("missing \(dir)/\(n).png")
    }
    let w = img.width, h = img.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
    imgs[n] = (w, h, Array(UnsafeBufferPointer(start: d, count: w * h * 4)))
}
// Central 60% crop (avatar region of the watch screenshot)
func crop(_ n: String) -> (w: Int, h: Int, data: [UInt8]) {
    let (w, h, d) = imgs[n]!
    let x0 = w * 2 / 10, x1 = w * 8 / 10, y0 = h * 2 / 10, y1 = h * 8 / 10
    var out: [UInt8] = []
    for y in y0..<y1 { for x in x0..<x1 {
        let o = (y * w + x) * 4
        out.append(d[o]); out.append(d[o + 1]); out.append(d[o + 2])
    } }
    return (x1 - x0, y1 - y0, out)
}
var crops: [String: (w: Int, h: Int, data: [UInt8])] = [:]
for n in names { crops[n] = crop(n) }

func lumPx(_ d: [UInt8], _ o: Int) -> Double {
    (0.299 * Double(d[o]) + 0.587 * Double(d[o + 1]) + 0.114 * Double(d[o + 2])) / 255.0
}
func sil(_ n: String) -> Set<Int> {
    let c = crops[n]!
    var s = Set<Int>()
    for i in 0..<(c.w * c.h) where lumPx(c.data, i * 3) > 0.10 { s.insert(i) }
    return s
}
let sils = names.map { sil($0) }
print("== Silhouette size (lit pixels, central 60% crop) ==")
for (i, n) in names.enumerated() {
    let c = crops[n]!
    print("\(n): \(sils[i].count) px (\(String(format: "%.1f", 100.0 * Double(sils[i].count) / Double(c.w * c.h)))% of crop)")
}
print("\n== Pairwise silhouette IoU (1.0 = identical shape) ==")
for i in 0..<5 { for j in (i + 1)..<5 {
    let u = sils[i].union(sils[j]).count, n = sils[i].intersection(sils[j]).count
    print("\(names[i]) vs \(names[j]): \(String(format: "%.3f", Double(n) / Double(u)))")
}}
print("\n== Pairwise per-pixel disagreement (fraction of lit-union px where RGB dist > 40) ==")
for i in 0..<5 { for j in (i + 1)..<5 {
    let a = crops[names[i]]!, b = crops[names[j]]!
    var diff = 0, n = 0
    for k in 0..<(a.w * a.h) {
        let la = lumPx(a.data, k * 3), lb = lumPx(b.data, k * 3)
        if la > 0.10 || lb > 0.10 {
            n += 1
            let d = abs(Int(a.data[k * 3]) - Int(b.data[k * 3]))
                + abs(Int(a.data[k * 3 + 1]) - Int(b.data[k * 3 + 1]))
                + abs(Int(a.data[k * 3 + 2]) - Int(b.data[k * 3 + 2]))
            if d > 40 { diff += 1 }
        }
    }
    print("\(names[i]) vs \(names[j]): \(String(format: "%.1f", 100.0 * Double(diff) / Double(n)))%")
}}
print("\n== Dominant colors (32-level bins, top 6, lit pixels) ==")
for n in names {
    let c = crops[n]!
    var hist: [UInt32: Int] = [:]
    for k in 0..<(c.w * c.h) where lumPx(c.data, k * 3) > 0.10 {
        let key = UInt32(c.data[k * 3] / 32) << 10 | UInt32(c.data[k * 3 + 1] / 32) << 5 | UInt32(c.data[k * 3 + 2] / 32)
        hist[key, default: 0] += 1
    }
    guard !hist.isEmpty else { print("\(n): (no lit pixels)"); continue }
    let tot = hist.values.reduce(0, +)
    let top = hist.sorted { $0.value > $1.value }.prefix(6)
    print("\(n): " + top.map { (k, v) in
        String(format: "#%02X%02X%02X %.0f%%", (k >> 10) * 32 + 16, ((k >> 5) & 31) * 32 + 16, (k & 31) * 32 + 16,
               100.0 * Double(v) / Double(tot))
    }.joined(separator: "  "))
}
