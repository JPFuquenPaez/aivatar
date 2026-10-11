// Renders the Aivatar app icon (1024x1024, opaque) from a procedural
// reproduction of the source logo JPG. Host-side build tool — run with:
//
//   env -u SDKROOT xcrun --sdk macosx swift Tools/render_app_icon.swift [output.png]
//
// Source logo (1024x768 JPG) was measured by pixel analysis; all coordinates
// below are in the source's display frame (y down from the image top; the
// analysis scripts verified CGBitmapContext row 0 = image top).
//
// Silhouette: three overlapping ellipses — a big middle puff sitting higher,
// smaller left/right puffs lower — with soft feathered seams ("smoothed and
// seamless"), two near-white vertical capsule eyes, on a near-black navy bg.
//
//   Lobe     cx   cy      rx   ry    vertical gradient (light top -> dark bottom)
//   left    375  420      83   88    #D4AFE6 / #B697D7@50% / #7965BE   (lightest)
//   middle  511  374.5   127  134.5   #D2B0E5 / #957DC9@50% / #574CAC  (steepest)
//   right   660  419      70   87     #7F71BE / #5E53B1@50% / #5C51AE  (darkest)
//   eyes    (451, 403.5) and (570.5, 403.5), 10x24, #FCFCF7
//   background #100F18
//
// Blend model: the source's overlap regions mix both lobes' colors roughly
// 50/50 even deep inside both ellipses, which no opaque-stack of three
// gradients can reproduce exactly (the source reads as a mesh-gradient
// render). We approximate with feathered ellipses; seams get a soft blend
// from the Gaussian feather alone.
//
// Background: the source logo sits on near-black (#100F18), but the watchOS
// home screen is also near-black with circular-masked icons — a near-black
// icon is effectively invisible there (the post-launch assessment found
// exactly that: the app was on the honeycomb but read as an empty gap).
// Per the watchOS HIG (colorful, opaque, readable-on-black), the icon now
// uses a full-bleed brand-violet vertical gradient (#4B3A8F top ->
// #2B1F58 bottom, Nimbus family) with the cloud drawn OPAQUE on top
// (lobeAlpha 1.0: over a light background the 0.9-alpha under-blend is
// unnecessary and interior colors stay exact).
//
// Icon geometry: cloud scaled 1.5034x (439 -> 660 px, ~64% of canvas),
// recentered at (512,512) to read inside the system's circular mask.
// All drawing coordinates are top-down; the context CTM is flipped once.

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// Full-bleed background gradient (brand violet; NOT the logo's near-black —
/// see header). Top is lighter so the icon's edge ring reads on the black
/// watchOS home screen.
let bgTopHex: UInt32 = 0x4B3A8F
let bgBottomHex: UInt32 = 0x2B1F58
let lobeAlpha: CGFloat = 1.0
let featherSigma: CGFloat = 9.0

func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
    (CGFloat((hex >> 16) & 0xFF), CGFloat((hex >> 8) & 0xFF), CGFloat(hex & 0xFF))
}
func color(_ hex: UInt32) -> CGColor {
    let c = rgb(hex)
    return CGColor(colorSpace: srgb, components: [c.0 / 255, c.1 / 255, c.2 / 255, 1])!
}
// Pre-compensate a stop so that drawing at lobeAlpha over the bg reproduces
// the measured color: C_paint = (C_measured - (1-a)*bg) / a. With a = 1.0
// (opaque lobes over the violet gradient) this is the identity.
let compBG = rgb(bgBottomHex)
func compensated(_ hex: UInt32) -> CGColor {
    let m = rgb(hex), b = compBG
    let a = lobeAlpha
    func f(_ v: CGFloat, _ bv: CGFloat) -> CGFloat { min(255, (v - (1 - a) * bv) / a) }
    return CGColor(colorSpace: srgb, components: [f(m.0, b.0) / 255, f(m.1, b.1) / 255, f(m.2, b.2) / 255, 1])!
}

let scale: CGFloat = 660.0 / 439.0
func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: 512 + (x - 511) * scale, y: 512 + (y - 374.5) * scale)
}

struct Lobe {
    let center: CGPoint
    let rx: CGFloat
    let ry: CGFloat
    let stops: [(CGFloat, UInt32)]   // (location 0=top .. 1=bottom, measured color)
}

// Draw order back -> front (right, middle, left).
let lobes: [Lobe] = [
    Lobe(center: map(660, 419), rx: 70 * scale, ry: 87 * scale,
         stops: [(0, 0x7F71BE), (0.5, 0x5E53B1), (1, 0x5C51AE)]),
    Lobe(center: map(511, 374.5), rx: 127 * scale, ry: 134.5 * scale,
         stops: [(0, 0xD2B0E5), (0.22, 0xC8A7E0), (0.5, 0x957DC9), (0.78, 0x8872C3), (1, 0x574CAC)]),
    Lobe(center: map(375, 420), rx: 83 * scale, ry: 88 * scale,
         stops: [(0, 0xD4AFE6), (0.5, 0xB697D7), (1, 0x7965BE)]),
]

let eyeCenters = [map(451, 403.5), map(570.5, 403.5)]
let eyeWidth: CGFloat = 10 * scale
let eyeHeight: CGFloat = 24 * scale
let eyeHex: UInt32 = 0xFCFCF7

func makeContext() -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Single flip: top-down coordinates everywhere below.
    ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(size)))
    return ctx
}

// Fills a lobe ellipse with its vertical gradient (light top -> dark bottom).
func gradientFilledEllipse(_ lobe: Lobe, in ctx: CGContext) {
    let bbox = CGRect(x: lobe.center.x - lobe.rx, y: lobe.center.y - lobe.ry,
                      width: lobe.rx * 2, height: lobe.ry * 2)
    ctx.saveGState()
    ctx.addEllipse(in: bbox)
    ctx.clip()
    let colors = lobe.stops.map { compensated($0.1) } as CFArray
    let locations = lobe.stops.map { $0.0 } as [CGFloat]
    let gradient = CGGradient(colorsSpace: srgb, colors: colors, locations: locations)!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: bbox.midX, y: bbox.minY),
                           end: CGPoint(x: bbox.midX, y: bbox.maxY),
                           options: [])
    ctx.restoreGState()
}

// Feathered lobe layer: hard gradient ellipse -> Gaussian blur (premultiplied
// alpha keeps rim colors correct). No alpha gain: the soft rim alone blends
// the seams; interior solidity comes from the opaque gradient fill.
func featheredLobe(_ lobe: Lobe) -> CGImage? {
    let layer = makeContext()
    gradientFilledEllipse(lobe, in: layer)
    guard let hard = layer.makeImage() else { return nil }

    let blur = CIFilter(name: "CIGaussianBlur")!
    blur.setValue(CIImage(cgImage: hard), forKey: kCIInputImageKey)
    blur.setValue(featherSigma, forKey: "inputRadius")
    guard let out = blur.outputImage?.clamped(to: rect).cropped(to: rect) else { return nil }
    return CIContext().createCGImage(out, from: rect)
}

// MARK: - Compose

let out = makeContext()
// Full-bleed brand-violet vertical gradient (see header: near-black would
// be invisible in the watchOS home screen's circular mask on black).
let bgGradient = CGGradient(
    colorsSpace: srgb,
    colors: [color(bgTopHex), color(bgBottomHex)] as CFArray,
    locations: [0, 1]
)!
out.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 512, y: 0),
    end: CGPoint(x: 512, y: CGFloat(size)),
    options: []
)

for lobe in lobes {
    guard let img = featheredLobe(lobe) else { fatalError("lobe render failed") }
    out.saveGState()
    out.setAlpha(lobeAlpha)
    // Unflip for the image draw: image compositing is not CTM-relative in the
    // same way as path drawing; a second flip makes the layer land upright.
    out.translateBy(x: 0, y: CGFloat(size))
    out.scaleBy(x: 1, y: -1)
    out.draw(img, in: rect)
    out.restoreGState()
}

// Eyes: crisp vertical capsules, fully opaque.
out.setFillColor(color(eyeHex))
for center in eyeCenters {
    let capsule = CGRect(x: center.x - eyeWidth / 2, y: center.y - eyeHeight / 2,
                         width: eyeWidth, height: eyeHeight)
    out.addPath(CGPath(roundedRect: capsule, cornerWidth: eyeWidth / 2,
                       cornerHeight: eyeWidth / 2, transform: nil))
    out.fillPath()
}

guard let composed = out.makeImage() else { fatalError("composition failed") }

// Final flatten: fully opaque RGB (watchOS app icons must not carry alpha).
let finalCtx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                         bytesPerRow: size * 4, space: srgb,
                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
finalCtx.draw(composed, in: CGRect(x: 0, y: 0, width: size, height: size))
guard let finalImage = finalCtx.makeImage() else { fatalError("final flatten failed") }

let outputURL = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Aivatar Watch App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

let dest = CGImageDestinationCreateWithURL(outputURL as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, finalImage,
                           [kCGImagePropertyProfileName: "sRGB IEC61966-2.1"] as CFDictionary)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed") }

// MARK: - Verification report

print("wrote \(outputURL.path)")
print("size: \(finalImage.width)x\(finalImage.height), alphaInfo: \(finalImage.alphaInfo)")

let data = finalCtx.data!.assumingMemoryBound(to: UInt8.self)
func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let o = y * size * 4 + x * 4
    return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
}
// Probes at source-measured display points (expected = measured source color).
let probes: [(String, (Int, Int), UInt32)] = [
    ("mid-top(511,250)", (511, 250), 0xD2B0E5),
    ("mid-center(511,375)", (511, 375), 0x957DC9),
    ("mid-bottom(511,495)", (511, 495), 0x574CAC),
    ("left-top(375,345)", (375, 345), 0xD4AFE6),
    ("left-center(375,420)", (375, 420), 0xB697D7),
    ("left-bottom(375,495)", (375, 495), 0x7965BE),
    ("right-top(660,345)", (660, 345), 0x7F71BE),
    ("right-center(660,419)", (660, 419), 0x5E53B1),
    ("eyeL(451,403)", (451, 403), 0xFCFDF7),
    ("eyeR(570,403)", (570, 403), 0xFBFCFB),
    ("overlap-LM(420,410)", (420, 410), 0xA88AD2),   // seam: approx (see header)
    ("overlap-MR(610,410)", (610, 410), 0x8774C3),   // seam: approx (see header)
]
var maxDrift = 0
for (label, src, expected) in probes {
    let p = map(CGFloat(src.0), CGFloat(src.1))
    let px = pixel(Int(p.x), Int(p.y))
    let e = rgb(expected)
    let drift = Int(max(abs(px.0 - Int(e.0)), max(abs(px.1 - Int(e.1)), abs(px.2 - Int(e.2)))))
    maxDrift = max(maxDrift, drift)
    print(String(format: "\(label.padding(toLength: 22, withPad: " ", startingAt: 0)) #%02X%02X%02X  expected #%06X  drift=%d",
                 px.0, px.1, px.2, expected, drift))
}

// Silhouette: expect ~660x404 centered on (512,512). On the violet gradient
// the cloud is detected by luminance (darkest cloud lobe ~95, brightest
// background ~73), not by a per-channel floor.
var minX = size, maxX = 0, minY = size, maxY = 0
for y in stride(from: 0, to: size, by: 2) {
    for x in stride(from: 0, to: size, by: 2) {
        let c = pixel(x, y)
        let lum = 0.299 * Double(c.0) + 0.587 * Double(c.1) + 0.114 * Double(c.2)
        if lum > 85 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
print("cloud bbox: x[\(minX),\(maxX)] y[\(minY),\(maxY)] -> \(maxX-minX+1)x\(maxY-minY+1), center=(\((minX+maxX)/2),\((minY+maxY)/2))")
print("max interior drift vs source samples: \(maxDrift)")

// Home-screen visibility probe — the check this background exists for:
// sample just inside the circular mask edge (r=490) at 8 angles; every
// sample must be clearly brighter than the black watchOS home screen
// (luminance > 25/255) or the icon reads as an empty gap in the honeycomb.
// (The v1 icon — cloud on the logo's #100F18 near-black — measured ~16/255
// here and was the "app icon missing on the watch" bug report.)
var minEdgeLum = 255
for i in 0..<8 {
    let a = Double(i) / 8.0 * 2.0 * Double.pi
    let x = 512 + Int(490 * cos(a)), y = 512 + Int(490 * sin(a))
    let p = pixel(x, y)
    let lum = 0.299 * Double(p.0) + 0.587 * Double(p.1) + 0.114 * Double(p.2)
    minEdgeLum = min(minEdgeLum, Int(lum))
    print(String(format: "edge %d (%4d,%4d) #%02X%02X%02X  lum=%d", i, x, y, p.0, p.1, p.2, Int(lum)))
}
print("edge ring min luminance: \(minEdgeLum)  (must be > 25 to read on the black home screen)")
if minEdgeLum <= 25 {
    print("FAIL: icon edge is invisible on the black watchOS home screen")
    exit(1)
}
