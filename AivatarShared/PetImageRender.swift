import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// PetImageRender (v40 HD pets, v42 living motion): draws a companion's HD
/// pet image (imageset `pet-<name>`, cut from the authored sheet in
/// avatars/) instead of the 20x18 cell grid. The image is drawn aspect-fit
/// into the 20x15 cell box (rows 0...15 of the stage grid, bottom-anchored)
/// so the isometric ground tile keeps rows 15-17 underneath.
///
/// Motion is PetMotion: a continuous Pose (ambient breathing/sway + act
/// envelopes, pure in (frameID, frameAge, tick, seed)) applied around the
/// bottom-center anchor — plus PUPPET regions (head, tail) redrawn on top
/// with their own tilt/bob/wag, so the animal feels alive rather than a
/// rigid sticker. Shared by the watch stage, the live picker and the
/// iPhone companion: same image, same motion, every surface.
nonisolated enum PetImageRender {

    /// Cell rows the pet image occupies; rows below belong to the tile.
    static let imageBoxRows = 15

    /// The pet image, if the sprite is image-backed and the asset resolves.
    static func uiImage(_ sprite: CompanionSprite) -> UIImage? {
        guard let name = sprite.imageAssetName else { return nil }
        return UIImage(named: name)
    }

    /// Draws the pet into `box` with `pose` applied. `overOverlay` cells
    /// (blush / vapor / interiority) paint on top at their grid-cell rects;
    /// the ground tile is the caller's job (drawn before, from
    /// SpriteStageMetadata.shadowCells). `rest` dims to the Always-On LOD
    /// (matches the grid rest dim: body x0.22 ~= black 0.78).
    static func draw(ctx: GraphicsContext, box: CGRect, sprite: CompanionSprite,
                     pose: PetMotion.Pose, rest: Bool = false,
                     overOverlay: [CompanionSprite.CellDiff] = []) {
        guard let img = uiImage(sprite), img.size.width > 0, img.size.height > 0 else { return }
        let cell = box.width / CGFloat(CompanionSprite.gridWidth)
        let scale = min(box.width / img.size.width, box.height / img.size.height)
        let dw = img.size.width * scale, dh = img.size.height * scale
        // Whole-body transform around the bottom-center anchor (feet planted).
        let base = CGRect(x: box.midX - dw / 2 + CGFloat(pose.dx) * cell,
                          y: box.maxY - dh - CGFloat(pose.dy) * cell,
                          width: dw, height: dh)
        let anchor = CGPoint(x: base.midX, y: base.maxY)
        let bodyTr = CGAffineTransform(translationX: anchor.x, y: anchor.y)
            .rotated(by: CGFloat(pose.rotation))
            .scaledBy(x: CGFloat(pose.scaleX), y: CGFloat(pose.scaleY))
            .translatedBy(x: -anchor.x, y: -anchor.y)
        let bodyRect = base.applying(bodyTr)
        ctx.draw(Image(uiImage: img), in: bodyRect)
        if rest {
            ctx.fill(Path(bodyRect), with: .color(.black.opacity(0.78)))
        }
        // Puppet regions redrawn on top with their own motion (tail, then head).
        if let tail = sprite.puppetTail {
            drawRegion(ctx: ctx, img: img, sprite: sprite, region: tail, key: "tail",
                       base: base, bodyTr: bodyTr,
                       rotation: pose.tailWag, bobCells: 0)
        }
        if let head = sprite.puppetHead {
            drawRegion(ctx: ctx, img: img, sprite: sprite, region: head, key: "head",
                       base: base, bodyTr: bodyTr,
                       rotation: pose.headTilt, bobCells: pose.headBob)
        }
        drawOverlay(ctx: ctx, box: box, cell: cell, sprite: sprite, cells: overOverlay)
    }

    /// Draws one puppeteered region: the image cropped to the region's
    /// normalized rect, placed at the region's rect inside the (already
    /// body-transformed) image, then rotated around the region's anchor.
    private static func drawRegion(ctx: GraphicsContext, img: UIImage, sprite: CompanionSprite,
                                   region: CompanionSprite.PuppetRegion, key: String,
                                   base: CGRect, bodyTr: CGAffineTransform,
                                   rotation: Double, bobCells: Double) {
        guard let regionImg = regionImage(img, assetName: sprite.imageAssetName ?? "", key: key, region) else { return }
        let cellH = base.height / CGFloat(imageBoxRows)
        let destBase = CGRect(x: base.minX + region.rect.minX * base.width,
                              y: base.minY + region.rect.minY * base.height - CGFloat(bobCells) * cellH,
                              width: region.rect.width * base.width,
                              height: region.rect.height * base.height)
        let anchorBase = CGPoint(x: base.minX + region.anchor.x * base.width,
                                 y: base.minY + region.anchor.y * base.height)
        let dest = destBase.applying(bodyTr)
        let a = anchorBase.applying(bodyTr)
        let rot = CGAffineTransform(translationX: a.x, y: a.y)
            .rotated(by: CGFloat(rotation))
            .translatedBy(x: -a.x, y: -a.y)
        ctx.draw(Image(uiImage: regionImg), in: dest.applying(rot))
    }

    // MARK: - Region image cache (cropped once per asset+region)

    private final class RegionCache: @unchecked Sendable {
        let lock = NSLock()
        var images: [String: UIImage] = [:]   // "<asset>#<key>" -> cropped UIImage
    }
    private static let regionCache = RegionCache()

    private static func regionImage(_ img: UIImage, assetName: String, key: String,
                                    _ region: CompanionSprite.PuppetRegion) -> UIImage? {
        let ck = "\(assetName)#\(key)"
        regionCache.lock.lock()
        if let cached = regionCache.images[ck] {
            regionCache.lock.unlock()
            return cached
        }
        regionCache.lock.unlock()
        guard let cg = img.cgImage else { return nil }
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        // CGImage crop rect is in image pixel space, y-down from the top row
        // for images loaded via CGImageSource (verified on device renders).
        let src = CGRect(x: region.rect.minX * iw, y: region.rect.minY * ih,
                         width: region.rect.width * iw, height: region.rect.height * ih)
        guard let cropped = cg.cropping(to: src) else { return nil }
        let ui = UIImage(cgImage: cropped, scale: img.scale, orientation: img.imageOrientation)
        regionCache.lock.lock()
        regionCache.images[ck] = ui
        regionCache.lock.unlock()
        return ui
    }

    /// Paints overlay cells at their grid rects (box origin = grid origin, so
    /// tile rows 15-17 still land correctly under the image box).
    static func drawOverlay(ctx: GraphicsContext, box: CGRect, cell: CGFloat,
                            sprite: CompanionSprite, cells: [CompanionSprite.CellDiff]) {
        var paths: [Character: Path] = [:]
        var partial: [(rect: CGRect, symbol: Character, alpha: Float)] = []
        for d in cells {
            guard d.x >= 0, d.x < CompanionSprite.gridWidth,
                  d.y >= 0, d.y < CompanionSprite.gridHeight else { continue }
            let r = CGRect(x: box.minX + CGFloat(d.x) * cell,
                           y: box.minY + CGFloat(d.y) * cell,
                           width: cell, height: cell)
            if d.alpha >= 1 { paths[d.symbol, default: Path()].addRect(r) }
            else { partial.append((r, d.symbol, d.alpha)) }
        }
        for (symbol, path) in paths {
            ctx.fill(path, with: .color(cellColor(sprite, symbol)))
        }
        for (rect, symbol, alpha) in partial {
            ctx.fill(Path(rect), with: .color(cellColor(sprite, symbol).opacity(Double(alpha))))
        }
    }

    /// Overlay cell color. v41: for image-backed pets the ground tile (and
    /// any ink) is neutral dark — a shadow is not tinted by the pet's shade
    /// token (the corgi's D is olive); accent cells keep the pet's accent.
    private static func cellColor(_ sprite: CompanionSprite, _ symbol: Character) -> Color {
        if sprite.isImageBacked {
            switch symbol {
            case "D": return color("26262B")
            case "K": return color("0B0B0D")
            default: break
            }
        }
        return color(sprite.paletteHex[symbol] ?? "000000")
    }

    static func color(_ hex: String) -> Color {
        let rgb = CompanionSprite.hexToRGB(hex)
        return Color(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}
