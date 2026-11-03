import SwiftUI
import CoreGraphics

/// Renders one static pixel icon per companion for the companion picker
/// (Shell/CompanionPickerView). The icon is the REAL authored avatar: the
/// same engine -> painter -> hi-bit rasterizer path as the golden frames,
/// painted once at a pinned frame, so the picker shows exactly what the
/// stage shows after choosing. Static on purpose — a watch picker must be
/// glanceable and near-zero power (five live TimelineViews would drain the
/// battery); the live avatar appears on the stage right after the choice.
/// Pixels are never interpolated (PIXEL_DESIGN.md §4: no smoothing).
nonisolated enum CompanionIcon {
    /// The pinned frame every icon is painted at (the golden idle pose).
    static let iconFrame = 300

    /// Lock-guarded icon cache (built once per process).
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var images: [Archetype: CGImage] = [:]
    }
    private static let cache = Cache()

    /// SwiftUI image for the picker, pixel-crisp.
    static func image(for archetype: Archetype) -> Image? {
        guard let cg = cgImage(for: archetype) else { return nil }
        return Image(decorative: cg, scale: 1).interpolation(.none)
    }

    /// The rendered icon, built once per process and cached.
    static func cgImage(for archetype: Archetype) -> CGImage? {
        cache.lock.lock()
        if let cached = cache.images[archetype] {
            cache.lock.unlock()
            return cached
        }
        cache.lock.unlock()
        guard let rendered = render(archetype) else { return nil }
        cache.lock.lock()
        cache.images[archetype] = rendered
        cache.lock.unlock()
        return rendered
    }

    /// The raw RGBA8 pixels of the icon (grid-sized), test-visible.
    static func snapshotBytes(for archetype: Archetype) -> [UInt8] {
        guard let skeleton = try? Skeleton(document: RigDocument.load()),
              let profile = try? PersonalityProfile.load(archetype) else { return [] }
        let engine = AvatarEngine(
            skeleton: skeleton, profile: profile,
            seed: 20261010 + UInt64(Archetype.allCases.firstIndex(of: archetype) ?? 0)
        )
        engine.update(toFrame: iconFrame)
        let painter = AvatarSpritePainter(skeleton: engine.skeleton, visualSet: engine.visualSet)
        painter.paint(
            world: engine.currentWorld, pose: engine.currentPose, rest: false,
            accentPhase: engine.activeGesturePhase, tell: engine.tell, tellPhase: engine.tellPhase
        )
        let rasterizer = PixelStageRasterizer(painter: painter)
        rasterizer.rasterize(painter: painter, frame: iconFrame)
        return rasterizer.snapshotBytes()
    }

    private static func render(_ archetype: Archetype) -> CGImage? {
        let bytes = snapshotBytes(for: archetype)
        let w = PixelStageRasterizer.gridWidth
        let h = PixelStageRasterizer.gridHeight
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
