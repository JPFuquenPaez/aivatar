import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// PostcardCard (Aivatar 2.0 Phase 3): the shareable postcard renderer for the
/// iPhone companion shell. Lives in AivatarShared so the watch app (tests),
/// the widget, and the iPhone app all compile the exact same card code.
///
/// The card is composed from the shared container's pixel icon (nearest-
/// neighbor upscale — crisp blocks, on-brand pixel art) on a pure-black
/// 1080x1080 canvas, with the caption drawn in CoreText. Pure CoreGraphics /
/// CoreText only: compiles on watchOS and iOS alike, deterministic for the
/// same inputs (same bytes -> same PNG).
nonisolated enum PostcardCard {
    static let canvasSize: Int = 1080
    /// The icon upscale factor: the shared icon is 60x54 device px -> 12x.
    static let iconScale = 12

    /// Renders the card. `iconPNG` is the companion's icon PNG from the shared
    /// container (nil = pawprint-less plain black card with just the caption).
    static func render(iconPNG: Data?, title: String, subtitle: String) -> CGImage? {
        let size = canvasSize
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx else { return nil }
        // Pure black (OLED-brand) background.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // The companion, nearest-neighbor upscaled, centered in the upper 2/3.
        // (The context is y-up; rects are computed y-down then converted.)
        if let iconPNG,
           let source = CGImageSourceCreateWithData(iconPNG as CFData, nil),
           let icon = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let w = icon.width * iconScale, h = icon.height * iconScale
            let topYDown = CGFloat(size) * 0.30 - CGFloat(h) / 2
            let rect = CGRect(x: CGFloat(size - w) / 2,
                              y: CGFloat(size) - topYDown - CGFloat(h),
                              width: CGFloat(w), height: CGFloat(h))
            ctx.interpolationQuality = .none
            ctx.draw(icon, in: rect)
        }
        // Caption: title (semibold) + subtitle (secondary), centered, bottom.
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let secondary = CGColor(red: 1, green: 1, blue: 1, alpha: 0.55)
        drawCentered(ctx: ctx, text: title, fontSize: 56, color: white, centerYDown: CGFloat(size) * 0.78)
        drawCentered(ctx: ctx, text: subtitle, fontSize: 36, color: secondary, centerYDown: CGFloat(size) * 0.78 + 64)
        return ctx.makeImage()
    }

    /// PNG bytes of the card (ImageIO), ready for a share sheet.
    static func pngData(iconPNG: Data?, title: String, subtitle: String) -> Data? {
        guard let image = render(iconPNG: iconPNG, title: title, subtitle: subtitle) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func drawCentered(ctx: CGContext, text: String, fontSize: CGFloat, color: CGColor, centerYDown: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attr = CFAttributedStringCreate(nil, text as CFString, [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attr)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        // y-up context: baseline = canvas - centerYDown + ~0.35 em (cap-height centering).
        ctx.textMatrix = .identity
        ctx.translateBy(x: CGFloat(canvasSize - Int(width)) / 2,
                        y: CGFloat(canvasSize) - centerYDown + fontSize * 0.35)
        CTLineDraw(line, ctx)
    }
}
