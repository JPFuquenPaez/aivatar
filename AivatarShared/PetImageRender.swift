import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// PetImageRender (v40 HD pet pass): draws a companion's HD pet image
/// (imageset `pet-<name>`, cut from the authored sheet in avatars/) instead
/// of the 20x18 cell grid. The image is drawn aspect-fit into the 20x15
/// cell box (rows 0...15 of the stage grid, bottom-anchored) so the
/// isometric ground tile keeps rows 15-17 underneath; motion is the pure
/// `CompanionSprite.frameTransform(_:)` mapping applied around the
/// bottom-center anchor (feet stay planted on the tile).
///
/// Shared by the watch stage (SpriteStageRenderer), the live picker
/// (LiveCompanionPreviewView) and the iPhone companion (PhoneCompanionView),
/// so the SAME animal with the SAME animation shows on every surface.
nonisolated enum PetImageRender {

    /// Cell rows the pet image occupies; rows below belong to the tile.
    static let imageBoxRows = 15

    /// The pet image, if the sprite is image-backed and the asset resolves.
    static func uiImage(_ sprite: CompanionSprite) -> UIImage? {
        guard let name = sprite.imageAssetName else { return nil }
        return UIImage(named: name)
    }

    /// The 20x15 cell box for a stage of `width`/`height` at vertical center
    /// 0.46 (same anchor math as the grid renderer). Pass `liftCells` for
    /// the inhale lift (grid mode lifts `top`; image mode expresses the
    /// lift as a transform dy, so pass 0 and let frameTransform do it).
    static func imageBox(width: CGFloat, height: CGFloat, top: CGFloat, cell: CGFloat) -> CGRect {
        CGRect(x: 0, y: top, width: CGFloat(CompanionSprite.gridWidth) * cell,
               height: CGFloat(imageBoxRows) * cell)
    }

    /// Draws the pet into `box` with the frame's transform. `overOverlay`
    /// cells (blush / vapor / interiority) paint on top of the image at
    /// their grid-cell rects; the ground tile is the caller's job (drawn
    /// before, from SpriteStageMetadata.shadowCells). `rest` dims to the
    /// Always-On LOD (matches the grid rest dim: body x0.22 ~= black 0.78).
    static func draw(ctx: GraphicsContext, box: CGRect, sprite: CompanionSprite,
                     frameID: String, rest: Bool = false,
                     overOverlay: [CompanionSprite.CellDiff] = []) {
        guard let img = uiImage(sprite), img.size.width > 0, img.size.height > 0 else { return }
        let t = CompanionSprite.frameTransform(frameID)
        let cell = box.width / CGFloat(CompanionSprite.gridWidth)
        let scale = min(box.width / img.size.width, box.height / img.size.height)
        let dw = img.size.width * scale, dh = img.size.height * scale
        // Anchor: bottom-center of the box (feet on the tile).
        var tr = CGAffineTransform.identity
            .translatedBy(x: box.midX, y: box.maxY)
            .rotated(by: CGFloat(t.rotation))
            .scaledBy(x: CGFloat(t.scaleX), y: CGFloat(t.scaleY))
            .translatedBy(x: CGFloat(t.dx) * cell - dw / 2, y: -CGFloat(t.dy) * cell - dh)
        let rect = CGRect(origin: .zero, size: CGSize(width: dw, height: dh)).applying(tr)
        ctx.draw(Image(uiImage: img), in: rect)
        if rest {
            ctx.fill(Path(rect), with: .color(.black.opacity(0.78)))
        }
        drawOverlay(ctx: ctx, box: box, cell: cell, sprite: sprite, cells: overOverlay)
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
