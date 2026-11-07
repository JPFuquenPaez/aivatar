import SwiftUI
import CoreGraphics
import ImageIO

/// Renders one static pixel icon per companion for the companion picker
/// and the complication (v13: the AUTHORED sprite's idle pose — the same
/// 20x18 grid the stage animates, so every scale shows the same companion.
/// The icon separates by its own solid color on the OLED black stage,
/// never by outlines, and pixels are never interpolated (PIXEL_DESIGN.md
/// §4). Static on purpose — a watch picker must be glanceable and
/// near-zero power; the live companion appears on the stage.
/// The complication icon's state variant (v18 F4). Asleep matches the
/// stage's rest LOD dim (body x0.22, paper x0.30); event highlights the
/// accent cells in the species' paper tone — "something happened".
nonisolated enum IconState: String, Sendable {
    case asleep, awake, event
}

nonisolated enum CompanionIcon {
    /// Device pixels per art cell (the icon is 60x54 device px).
    static let cellScale = 3

    /// Lock-guarded icon cache (built once per process), keyed by
    /// "archetype-state".
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var images: [String: CGImage] = [:]
    }
    private static let cache = Cache()

    /// SwiftUI image for the picker, pixel-crisp.
    static func image(for archetype: Archetype) -> Image? {
        guard let cg = cgImage(for: archetype) else { return nil }
        return Image(decorative: cg, scale: 1).interpolation(.none)
    }

    /// The rendered icon, built once per process and cached.
    static func cgImage(for archetype: Archetype, state: IconState = .awake) -> CGImage? {
        let key = "\(archetype.rawValue)-\(state.rawValue)"
        cache.lock.lock()
        if let cached = cache.images[key] {
            cache.lock.unlock()
            return cached
        }
        cache.lock.unlock()
        guard let rendered = render(archetype, state: state) else { return nil }
        cache.lock.lock()
        cache.images[key] = rendered
        cache.lock.unlock()
        return rendered
    }

    /// The raw RGBA8 pixels of the icon (grid-sized), test-visible.
    static func snapshotBytes(for archetype: Archetype, state: IconState = .awake) -> [UInt8] {
        let sprite = AuthoredSprites.sprite(for: archetype)
        let grid = sprite.symbols(frameID: "idle")
        let w = CompanionSprite.gridWidth * cellScale
        let h = CompanionSprite.gridHeight * cellScale
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<CompanionSprite.gridHeight {
            for x in 0..<CompanionSprite.gridWidth {
                var symbol = grid[y][x]
                guard symbol != "." else { continue }
                // v18: the event variant highlights accent cells in paper.
                if state == .event, symbol == "A" { symbol = "W" }
                guard let hex = sprite.paletteHex[symbol] else { continue }
                var rgb = CompanionSprite.hexToRGB(hex)
                // v18: the asleep variant matches the stage rest LOD dim
                // (paper x0.30, everything else x0.22).
                if state == .asleep {
                    let f: Double = symbol == "W" ? 0.30 : 0.22
                    rgb = (UInt8(Double(rgb.r) * f), UInt8(Double(rgb.g) * f), UInt8(Double(rgb.b) * f))
                }
                for dy in 0..<cellScale {
                    for dx in 0..<cellScale {
                        let i = ((y * cellScale + dy) * w + x * cellScale + dx) * 4
                        pixels[i] = rgb.r
                        pixels[i + 1] = rgb.g
                        pixels[i + 2] = rgb.b
                        pixels[i + 3] = 255
                    }
                }
            }
        }
        return pixels
    }

    /// PNG data of the rendered icon (ImageIO — no UIKit dependency), used
    /// to publish the complication icons into the shared app-group
    /// container (v12 presence pass; v18 adds the per-state variants).
    static func pngData(for archetype: Archetype, state: IconState = .awake) -> Data? {
        guard let cg = cgImage(for: archetype, state: state) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func render(_ archetype: Archetype, state: IconState = .awake) -> CGImage? {
        let bytes = snapshotBytes(for: archetype, state: state)
        let w = CompanionSprite.gridWidth * cellScale
        let h = CompanionSprite.gridHeight * cellScale
        guard bytes.count == w * h * 4,
              let data = CFDataCreate(kCFAllocatorDefault, bytes, bytes.count),
              let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
