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
/// stage's rest LOD dim (body x0.22, paper x0.30); event is a uniform flash
/// for every animal — accents to paper, body to accent (v29) —
/// "something happened", legible even on accent-carrying families.
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

    /// SwiftUI image for the picker. v40: HD pet icons interpolate smoothly
    /// (they are no longer pixel art); authored grids stay nearest-neighbor.
    static func image(for archetype: Archetype) -> Image? {
        guard let cg = cgImage(for: archetype) else { return nil }
        let sprite = AuthoredSprites.sprite(for: archetype)
        return Image(decorative: cg, scale: 1)
            .interpolation(sprite.isImageBacked ? .high : .none)
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
        let w = CompanionSprite.gridWidth * cellScale
        let h = CompanionSprite.gridHeight * cellScale
        // v40: image-backed companions icon with the HD pet itself
        // (downscaled into the 20x15 cell box above the tile rows).
        if sprite.isImageBacked, let img = PetImageRender.uiImage(sprite) {
            return imageBackedBytes(img, sprite: sprite, state: state, w: w, h: h)
        }
        let grid = sprite.symbols(frameID: "idle")
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<CompanionSprite.gridHeight {
            for x in 0..<CompanionSprite.gridWidth {
                var symbol = grid[y][x]
                guard symbol != "." else { continue }
                // v18/v29: the event variant is a uniform, legible flash for
                // EVERY animal — accent cells go to paper AND the body flashes
                // in the accent tone. (v24 only flashed the body when the idle
                // grid had no accent cells, which left Prism's event icon
                // nearly unchanged — not legible on a text-less family.)
                if state == .event {
                    if symbol == "A" { symbol = "W" }
                    else if symbol == "B" { symbol = "A" }
                }
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

    /// Renders an arbitrary grid (e.g. a PostcardComposer frame) to a CGImage.
    /// v26: the postcard preview plays the composed card, not a static icon.
    static func cgImage(for archetype: Archetype, grid: [[Character]]) -> CGImage? {
        let sprite = AuthoredSprites.sprite(for: archetype)
        let w = CompanionSprite.gridWidth * cellScale
        let h = CompanionSprite.gridHeight * cellScale
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<min(grid.count, CompanionSprite.gridHeight) {
            let row = grid[y]
            for x in 0..<min(row.count, CompanionSprite.gridWidth) {
                let symbol = row[x]
                guard symbol != ".", let hex = sprite.paletteHex[symbol] else { continue }
                let rgb = CompanionSprite.hexToRGB(hex)
                for dy in 0..<cellScale {
                    for dx in 0..<cellScale {
                        let i = ((y * cellScale + dy) * w + x * cellScale + dx) * 4
                        pixels[i] = rgb.r; pixels[i + 1] = rgb.g
                        pixels[i + 2] = rgb.b; pixels[i + 3] = 255
                    }
                }
            }
        }
        guard let data = CFDataCreate(kCFAllocatorDefault, pixels, pixels.count),
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

    /// One frame of a companion as a CGImage: the HD pet posed with
    /// `pose` for image-backed sprites (animated postcard), else the symbol
    /// grid (authored sprites). v40/v42.
    static func cgImage(for archetype: Archetype, frameID: String = "idle",
                        pose: PetMotion.Pose = .identity,
                        overlay: [CompanionSprite.CellDiff] = []) -> CGImage? {
        let sprite = AuthoredSprites.sprite(for: archetype)
        if sprite.isImageBacked, let img = PetImageRender.uiImage(sprite) {
            let w = CompanionSprite.gridWidth * cellScale
            let h = CompanionSprite.gridHeight * cellScale
            let bytes = imageBackedBytes(img, sprite: sprite, state: .awake, w: w, h: h,
                                         pose: pose, overlay: overlay)
            return cgImage(from: bytes, w: w, h: h)
        }
        return cgImage(for: archetype, grid: sprite.symbols(frameID: frameID, overlay: overlay))
    }

    private static func cgImage(from bytes: [UInt8], w: Int, h: Int) -> CGImage? {
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

    /// v40/v42: renders the pet image into the 60x54 icon buffer, posed with
    /// `pose` (the postcard plays the same continuous motion as the stage).
    /// Awake =
    /// full color on transparency; asleep = the rest-LOD dim (matches the
    /// stage: black 0.78 over the art); event = the empty cells flash in
    /// the companion's accent (legible on every family, same contract as
    /// the grid path's uniform flash). The frame transform animates the pet
    /// around the bottom-center anchor of the 20x15 cell box (CG is y-up:
    /// the box occupies the TOP of the buffer, anchor at its bottom edge).
    private static func imageBackedBytes(_ img: UIImage, sprite: CompanionSprite,
                                         state: IconState, w: Int, h: Int,
                                         pose: PetMotion.Pose = .identity,
                                         overlay: [CompanionSprite.CellDiff] = []) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = img.cgImage else { return pixels }
        if state == .event {
            let rgb = CompanionSprite.hexToRGB(sprite.uiAccentHex)
            ctx.setFillColor(CGColor(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
                                     blue: CGFloat(rgb.b) / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let cell = CGFloat(w) / CGFloat(CompanionSprite.gridWidth)
        let boxH = CGFloat(PetImageRender.imageBoxRows) * cell
        let scale = min(CGFloat(w) / CGFloat(cg.width), boxH / CGFloat(cg.height))
        let dw = CGFloat(cg.width) * scale, dh = CGFloat(cg.height) * scale
        // y-up anchor: bottom-center of the 20x15 box = (w/2, h - boxH).
        // The rect's bottom-center is (dw/2, 0) in y-up coords.
        let anchorX = CGFloat(w) / 2, anchorY = CGFloat(h) - boxH
        var tr = CGAffineTransform.identity
            .translatedBy(x: anchorX + CGFloat(pose.dx) * cell, y: anchorY + CGFloat(pose.dy) * cell)
            .rotated(by: CGFloat(pose.rotation))
            .scaledBy(x: CGFloat(pose.scaleX), y: CGFloat(pose.scaleY))
            .translatedBy(x: -dw / 2, y: 0)
        let rect = CGRect(origin: .zero, size: CGSize(width: dw, height: dh)).applying(tr)
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: rect)
        // Puppet regions (head/tail) redrawn on top, like the live stage.
        if let tail = sprite.puppetTail {
            drawRegionCG(ctx: ctx, cg: cg, sprite: sprite, region: tail,
                         base: rect, anchorBase: CGPoint(x: anchorX, y: anchorY),
                         rotation: pose.tailWag, bobCells: 0, cell: cell)
        }
        if let head = sprite.puppetHead {
            drawRegionCG(ctx: ctx, cg: cg, sprite: sprite, region: head,
                         base: rect, anchorBase: CGPoint(x: anchorX, y: anchorY),
                         rotation: pose.headTilt, bobCells: pose.headBob, cell: cell)
        }
        if state == .asleep {
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.78))
            ctx.fill(rect)
        }
        // Overlay cells (blush/stamp/week grid) at their grid rects, y-up.
        for d in overlay {
            guard d.x >= 0, d.x < CompanionSprite.gridWidth,
                  d.y >= 0, d.y < CompanionSprite.gridHeight,
                  let hex = sprite.paletteHex[d.symbol] else { continue }
            let rgb = CompanionSprite.hexToRGB(hex)
            ctx.setFillColor(CGColor(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
                                     blue: CGFloat(rgb.b) / 255, alpha: CGFloat(d.alpha)))
            ctx.fill(CGRect(x: CGFloat(d.x) * cell, y: CGFloat(h) - CGFloat(d.y + 1) * cell,
                            width: cell, height: cell))
        }
        return pixels
    }

    /// v42: draws one puppeteered region (cropped from the pet CGImage) at
    /// its rect inside the posed image `base`, rotated around its anchor.
    /// CG is y-up; region rects are normalized y-down, so flip the crop.
    private static func drawRegionCG(ctx: CGContext, cg: CGImage, sprite: CompanionSprite,
                                     region: CompanionSprite.PuppetRegion,
                                     base: CGRect, anchorBase: CGPoint,
                                     rotation: Double, bobCells: Double, cell: CGFloat) {
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let src = CGRect(x: region.rect.minX * iw, y: (1 - region.rect.maxY) * ih,
                         width: region.rect.width * iw, height: region.rect.height * ih)
        guard let cropped = cg.cropping(to: src) else { return }
        let cellH = base.height / CGFloat(PetImageRender.imageBoxRows)
        let destBase = CGRect(x: base.minX + region.rect.minX * base.width,
                              y: base.minY + (1 - region.rect.maxY) * base.height + CGFloat(bobCells) * cellH,
                              width: region.rect.width * base.width,
                              height: region.rect.height * base.height)
        let anchor = CGPoint(x: base.minX + region.anchor.x * base.width,
                             y: base.minY + (1 - region.anchor.y) * base.height)
        var tr = CGAffineTransform(translationX: anchor.x, y: anchor.y)
            .rotated(by: CGFloat(rotation))
            .translatedBy(x: -anchor.x, y: -anchor.y)
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: destBase.applying(tr))
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
