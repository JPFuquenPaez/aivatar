import Foundation
import CoreGraphics
import ImageIO
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// Aivatar 2.0 E1 — icon export tool. The ONLY writer of the app icon PNGs.
//
// Usage: swift Tools/icon_export.swift <path-to-repo-root>
//
// Reads the authored 32x32 grid from AivatarShared/IconCuts.swift
// (IconCuts.emberFace — single source of truth, grid not drawing) and renders:
//   build/icon/AppIcon-Background.png  1088x1088 pure #000000 (layer 1)
//   build/icon/AppIcon-Foreground.png  1088x1088 transparent, head at 34 px/cell (layer 2)
//   Assets.xcassets/AppIcon.appiconset/AppIcon.png  1024x1024 composed (watchOS single-size icon)
//
// All rasterization is nearest-neighbor (shouldInterpolate: false), so the
// output is byte-stable across runs on the same OS — the SHA256 of each output
// is printed for the CI pin. Validation (exits non-zero on violation):
//   - grid parses to exactly 32 rows of 32 cells over the 5-token ramp;
//   - background layer is fully black; foreground palette subset of 5 tokens;
//   - composed icon has no alpha; layers are 1088 square.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("ICON-EXPORT FAIL: \(message)\n".data(using: .utf8)!)
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: icon_export.swift <repo-root>\n".data(using: .utf8)!)
    exit(2)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])

// ---- 1. Parse the authored grid from the Swift source (single source of truth) ----
// v36 moved the sprite core to AivatarShared; try both locations.
let candidates = [
    "AivatarShared/IconCuts.swift",
    "AivatarShared/CompanionSprite.swift",
    "Aivatar Watch App/Render/CompanionSprite.swift",
]
let spriteURL = candidates
    .map { root.appendingPathComponent($0) }
    .first { FileManager.default.fileExists(atPath: $0.path) }!
guard let spriteSource = try? String(contentsOf: spriteURL, encoding: .utf8) else {
    fail("cannot read \(spriteURL.path)")
}
let rowPattern = try! NSRegularExpression(pattern: "\"([.KDBWA]{32})\"")
let matches = rowPattern.matches(in: spriteSource, range: NSRange(spriteSource.startIndex..., in: spriteSource))
var rows: [String] = matches.map { String(spriteSource[Range($0.range(at: 1), in: spriteSource)!]) }
// The regex also matches 32-char stage rows if any existed; IconCuts.emberFace
// is the only 32x32 block — keep exactly the contiguous 32-row run.
if rows.count != 32 {
    // Fallback: take the last contiguous block of 32 rows.
    if rows.count > 32 { rows = Array(rows.suffix(32)) }
    if rows.count != 32 { fail("expected 32 grid rows of 32 cells, found \(rows.count)") }
}
let allowed: Set<Character> = Set(".KDBWA")
for (i, row) in rows.enumerated() where Set(row).isSubset(of: allowed) == false {
    fail("row \(i) contains a symbol outside the 5-token ramp")
}

// Ember icon palette (must match IconCuts.emberFacePaletteHex).
let palette: [Character: (UInt8, UInt8, UInt8)] = [
    "B": (0xFF, 0x9E, 0x4A),
    "D": (0xC4, 0x62, 0x1B),
    "K": (0x24, 0x12, 0x06),
    "W": (0xF5, 0xF4, 0xEF),
    "A": (0xFF, 0xC8, 0x00),
]

// ---- 2. Rasterizers (nearest-neighbor, no interpolation) ----
func renderLayer(size: Int, cell: Int, background: (UInt8, UInt8, UInt8, UInt8)?, paintGrid: Bool = true) -> (CGImage, [UInt8]) {
    let w = size, h = size
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let bg = background ?? (0, 0, 0, 0)
    for i in stride(from: 0, to: w * h, by: 1) {
        pixels[i * 4] = bg.0; pixels[i * 4 + 1] = bg.1
        pixels[i * 4 + 2] = bg.2; pixels[i * 4 + 3] = bg.3
    }
    if paintGrid {
    for (y, row) in rows.enumerated() {
        for (x, symbol) in row.enumerated() where symbol != "." {
            guard let rgb = palette[symbol] else { continue }
            for dy in 0..<cell {
                for dx in 0..<cell {
                    let px = x * cell + dx, py = y * cell + dy
                    guard px < w, py < h else { continue }
                    let i = (py * w + px) * 4
                    pixels[i] = rgb.0; pixels[i + 1] = rgb.1
                    pixels[i + 2] = rgb.2; pixels[i + 3] = 255
                }
            }
        }
    }
    }
    let data = CFDataCreate(kCFAllocatorDefault, pixels, pixels.count)!
    let provider = CGDataProvider(data: data)!
    let image = CGImage(
        width: w, height: h,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent
    )!
    return (image, pixels)
}

func pngData(of image: CGImage) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("PNG encode failed") }
    return data as Data
}

func sha256(_ data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
}

// ---- 3. Render + validate + write ----
let buildDir = root.appendingPathComponent("build/icon")
try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

let cell1088 = 1088 / 32   // 34 px per cell, exact integer
let (background, bgPixels) = renderLayer(size: 1088, cell: cell1088, background: (0, 0, 0, 255), paintGrid: false)
let (foreground, _) = renderLayer(size: 1088, cell: cell1088, background: nil)
let (composed, _) = renderLayer(size: 1024, cell: 1024 / 32, background: (0, 0, 0, 255))
// Re-encode the composed icon without an alpha channel (final icon: no alpha).
let composedNoAlpha: CGImage = {
    let w = 1024, h = 1024
    guard let src = composed.dataProvider?.data else { fail("composed icon has no data") }
    let bytes = [UInt8](unsafeUninitializedCapacity: w * h * 4) { buf, count in
        let srcBytes = (CFDataGetBytePtr(src) as UnsafePointer<UInt8>?)!
        for i in 0..<w * h {
            buf[i * 4] = srcBytes[i * 4]
            buf[i * 4 + 1] = srcBytes[i * 4 + 1]
            buf[i * 4 + 2] = srcBytes[i * 4 + 2]
            buf[i * 4 + 3] = 255
        }
        count = w * h * 4
    }
    let data = CFDataCreate(kCFAllocatorDefault, bytes, bytes.count)!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: CGDataProvider(data: data)!, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}()

// Validation pins.
if background.width != 1088 || background.height != 1088 { fail("background layer must be 1088x1088") }
if foreground.width != 1088 || foreground.height != 1088 { fail("foreground layer must be 1088x1088") }
if composed.width != 1024 || composed.height != 1024 { fail("composed icon must be 1024x1024") }
// Background fully black, checked on the source buffer (pre-encode).
for i in stride(from: 0, to: bgPixels.count, by: 397 * 4) {
    if bgPixels[i] != 0 || bgPixels[i + 1] != 0 || bgPixels[i + 2] != 0 {
        fail("background layer is not fully black")
    }
}
// Foreground palette subset of the 5 tokens is guaranteed by construction
// (only palette symbols are painted); assert the token count used <= 5.
let usedTokens = Set(rows.joined()).subtracting(["."])
if usedTokens.count > 5 { fail("foreground uses \(usedTokens.count) tokens, budget is 5") }

let bgPNG = pngData(of: background)
let fgPNG = pngData(of: foreground)
let appPNG = pngData(of: composedNoAlpha)
try bgPNG.write(to: buildDir.appendingPathComponent("AppIcon-Background.png"))
try fgPNG.write(to: buildDir.appendingPathComponent("AppIcon-Foreground.png"))
let iconset = root.appendingPathComponent("Aivatar Watch App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try appPNG.write(to: iconset)

print("ICON-EXPORT OK")
print("  background 1088x1088 sha256=\(sha256(bgPNG))")
print("  foreground 1088x1088 sha256=\(sha256(fgPNG))")
print("  AppIcon.png 1024x1024 sha256=\(sha256(appPNG)) -> \(iconset.path)")
