import SwiftUI
import CoreGraphics
import ImageIO

/// CompanionIcon (v3): the static icon cuts for the companion picker, the
/// Settings identity disc and the watch-face complication — the soft-toy
/// puppet's simplified head (silhouette + eyes), rendered through the same
/// pure CG drawing as the live stage. Three presence states, never
/// animated: the state change across the day IS the animation (F4).
nonisolated enum IconState: String, Sendable {
    case asleep, awake, event
}

nonisolated enum CompanionIcon {
    /// The icon canvas (device px): the head cut at complication quality.
    static let iconWidth = 132
    static let iconHeight = 120
    /// The postcard moment render (2x the on-card display size).
    static let momentWidth = 240
    static let momentHeight = 216

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// SwiftUI image for the picker / identity disc.
    static func image(for archetype: Archetype) -> Image? {
        guard let cg = cgImage(for: archetype) else { return nil }
        return Image(decorative: cg, scale: 1)
    }

    /// The rendered head-cut icon, cached per archetype-state.
    static func cgImage(for archetype: Archetype, state: IconState = .awake) -> CGImage? {
        let key = "\(archetype.rawValue)-\(state.rawValue)"
        cache.lock.lock()
        if let cached = cache.images[key] {
            cache.lock.unlock()
            return cached
        }
        cache.lock.unlock()
        guard let rendered = renderHeadCut(archetype, state: state) else { return nil }
        cache.lock.lock()
        cache.images[key] = rendered
        cache.lock.unlock()
        return rendered
    }

    /// The postcard moment: the full puppet at one drive state (posed by
    /// the same director the stage runs), clay-styled hero, never animated.
    static func cgImage(for drive: PuppetDrive, size: (w: Int, h: Int) = (momentWidth, momentHeight)) -> CGImage? {
        guard let ctx = makeContext(width: size.w, height: size.h) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        ctx.fill(CGRect(x: 0, y: 0, width: size.w, height: size.h))
        let layout = PuppetDrawing.Layout.fit(
            canvas: CGSize(width: size.w, height: size.h), scaleFactor: 0.94)
        let device = layout.deviceTransform
            .concatenating(PuppetDrawing.CGSurface.flip(height: CGFloat(size.h)))
        let surface = PuppetDrawing.CGSurface(cg: ctx, device: device)
        let spec = CompanionToys.spec(for: drive.archetype)
        let (pose, props) = PuppetPoser.resolve(drive)
        PuppetDrawing.draw(
            surface, spec: spec, pose: pose, props: props,
            style: drive.resting ? .rest : .clay, time: 0,
            growthScale: CompanionToys.growthScale(bondLevel: drive.bondLevel),
            accessory: CompanionToys.accessory(bondLevel: drive.bondLevel),
            hueShift: drive.hueShiftDeg)
        return ctx.makeImage()
    }

    /// The raw RGBA8 pixels of the head cut (test-visible, byte-stable).
    static func snapshotBytes(for archetype: Archetype, state: IconState = .awake) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: iconWidth * iconHeight * 4)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: iconWidth, height: iconHeight, bitsPerComponent: 8,
                bytesPerRow: iconWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            return renderHeadCut(archetype, state: state, into: ctx)
        }
        if !drew {
            pixels = [UInt8](repeating: 0, count: iconWidth * iconHeight * 4)
        }
        return pixels
    }

    /// PNG bytes of the icon (published into the shared app-group container
    /// for the complication; ImageIO — no UIKit dependency).
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

    // MARK: - Internals

    private static func renderHeadCut(_ archetype: Archetype, state: IconState) -> CGImage? {
        guard let ctx = makeContext(width: iconWidth, height: iconHeight) else { return nil }
        guard renderHeadCut(archetype, state: state, into: ctx) else { return nil }
        return ctx.makeImage()
    }

    @discardableResult
    private static func renderHeadCut(_ archetype: Archetype, state: IconState, into ctx: CGContext) -> Bool {
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        ctx.fill(CGRect(x: 0, y: 0, width: iconWidth, height: iconHeight))
        let surface = PuppetDrawing.CGSurface(
            cg: ctx,
            device: PuppetDrawing.CGSurface.flip(height: CGFloat(iconHeight)))
        let spec = CompanionToys.spec(for: archetype)
        let cut: PuppetDrawing.IconCutState
        switch state {
        case .awake: cut = .awake
        case .asleep: cut = .asleep
        case .event: cut = .event
        }
        let pose = PuppetPose()
        PuppetDrawing.drawHeadOnly(
            surface, spec: spec, pose: pose, state: cut, time: 0,
            canvas: CGSize(width: iconWidth, height: iconHeight))
        return true
    }

    /// Lock-guarded icon cache (built once per process).
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var images: [String: CGImage] = [:]
    }
    private static let cache = Cache()
}
