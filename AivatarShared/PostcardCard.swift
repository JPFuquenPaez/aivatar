import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// PostcardCard (Aivatar 2.0 Phase 3, v3): the shareable postcard renderer
/// for the iPhone companion shell — the claymorphic puppet rendered directly
/// on a pure-black 1080x1080 canvas with the caption in CoreText. Pure
/// CoreGraphics / CoreText only: compiles on watchOS and iOS alike,
/// deterministic for the same inputs (same bytes -> same PNG). The HD photo
/// front retire with the pixel stage: the card IS the same character as the
/// watch, one identity everywhere.
nonisolated enum PostcardCard {
    static let canvasSize: Int = 1080

    /// Renders the card: the clay puppet (the quiet contentment moment) in
    /// the hero band, growth + accessory riding the bond level, the
    /// naming-day three-dot accent stamp when `anniversary`.
    static func render(archetype: Archetype, title: String, subtitle: String,
                       bondLevel: Int = 1, anniversary: Bool = false) -> CGImage? {
        let size = canvasSize
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Pure black (OLED-brand) background.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // The clay puppet: a fixed contentment pose, resolved through the
        // same poser as the live stage (bit-exact per inputs).
        var drive = PuppetDrive(archetype: archetype, frameID: "idle")
        drive.bondLevel = bondLevel
        drive.mood = .calm
        var (pose, props) = PuppetPoser.resolve(drive)
        pose.mouth = .smile
        pose.cheekGlow = 0.45
        _ = props
        let layout = PuppetDrawing.Layout.fit(
            canvas: CGSize(width: size, height: size), scaleFactor: 0.80)
        let device = layout.deviceTransform
            .concatenating(PuppetDrawing.CGSurface.flip(height: CGFloat(size)))
        let surface = PuppetDrawing.CGSurface(cg: ctx, device: device)
        PuppetDrawing.draw(
            surface, spec: CompanionToys.spec(for: archetype),
            pose: pose, props: props, style: .clay, time: 0,
            growthScale: CompanionToys.growthScale(bondLevel: bondLevel),
            accessory: CompanionToys.accessory(bondLevel: bondLevel))

        // E4: the naming-day stamp — three accent dots in the top corner.
        if anniversary {
            let tint = CompanionToys.spec(for: archetype).accentHex
            let rgb = ColorHex.rgb(tint)
            ctx.setFillColor(CGColor(red: CGFloat(rgb.r) / 255,
                                     green: CGFloat(rgb.g) / 255,
                                     blue: CGFloat(rgb.b) / 255, alpha: 1))
            for i in 0..<3 {
                let rect = CGRect(x: CGFloat(size) - 92,
                                  y: CGFloat(size) - 92 - CGFloat(i) * 58,
                                  width: 44, height: 44)
                ctx.fillEllipse(in: rect)
            }
        }

        // Caption: title (semibold) + subtitle (secondary), centered, bottom.
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let secondary = CGColor(red: 1, green: 1, blue: 1, alpha: 0.55)
        drawCentered(ctx: ctx, text: title, fontSize: 56, color: white,
                     centerYDown: CGFloat(size) * 0.82)
        drawCentered(ctx: ctx, text: subtitle, fontSize: 36, color: secondary,
                     centerYDown: CGFloat(size) * 0.82 + 64)
        return ctx.makeImage()
    }

    /// PNG bytes of the card (ImageIO), ready for a share sheet.
    static func pngData(archetype: Archetype, title: String, subtitle: String,
                        bondLevel: Int = 1, anniversary: Bool = false) -> Data? {
        guard let image = render(archetype: archetype, title: title, subtitle: subtitle,
                                 bondLevel: bondLevel, anniversary: anniversary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func drawCentered(ctx: CGContext, text: String,
                                     fontSize: CGFloat, color: CGColor,
                                     centerYDown: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attr = CFAttributedStringCreate(nil, text as CFString, [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attr)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.textMatrix = .identity
        ctx.translateBy(x: CGFloat(canvasSize - Int(width)) / 2,
                        y: CGFloat(canvasSize) - centerYDown + fontSize * 0.35)
        CTLineDraw(line, ctx)
    }
}
