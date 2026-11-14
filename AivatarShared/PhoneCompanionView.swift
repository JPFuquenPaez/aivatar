import SwiftUI

/// PhoneCompanionView (v36): the living companion on the iPhone shell. Renders
/// the same authored 20x18 grid as the watch (AivatarShared.CompanionSprite)
/// on the same 150 ms clock, with the same isometric ground tile
/// (SpriteStageMetadata) and the same inhale lift, driven by
/// PhoneCompanionAnimator. Reduce Motion freezes to the static idle frame.
struct PhoneCompanionView: View {
    let archetype: Archetype
    var presence: CompanionPresence
    let size: CGFloat

    @State private var animator: PhoneCompanionAnimator
    @State private var epoch = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(archetype: Archetype, presence: CompanionPresence = .awake, size: CGFloat) {
        self.archetype = archetype
        self.presence = presence
        self.size = size
        _animator = State(initialValue: PhoneCompanionAnimator(archetype: archetype, presence: presence))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15)) { timeline in
            Canvas { ctx, _ in
                let frame: String
                if reduceMotion {
                    frame = presence == .asleep ? "sleepy" : "idle"
                } else {
                    let elapsed = timeline.date.timeIntervalSince(epoch)
                    animator.advance(toTick: Int((elapsed / 0.15).rounded(.down)))
                    frame = animator.currentFrame
                }
                drawFrame(ctx: ctx, frameID: frame)
            }
        }
        .frame(width: size, height: size * 0.9)
    }

    private func drawFrame(ctx: GraphicsContext, frameID: String) {
        let sprite = AuthoredSprites.sprite(for: archetype)
        let cell = size / CGFloat(CompanionSprite.gridWidth)
        let baseTop = size * 0.42 - cell * CGFloat(CompanionSprite.gridHeight) / 2
        // Same isometric ground tile as the watch stage (awake frames only).
        let tile = presence != .asleep
            ? SpriteStageMetadata.shadowOverlayIfAwake(archetype, frame: frameID, farewellPending: false)
            : []
        // v40: image-backed companions draw the HD pet — the SAME image the
        // watch stage draws, animated by the same frame transform.
        if sprite.isImageBacked, PetImageRender.uiImage(sprite) != nil {
            PetImageRender.drawOverlay(ctx: ctx,
                box: CGRect(x: 0, y: baseTop, width: size, height: size),
                cell: cell, sprite: sprite, cells: tile)
            PetImageRender.draw(ctx: ctx,
                box: CGRect(x: 0, y: baseTop, width: size,
                            height: CGFloat(PetImageRender.imageBoxRows) * cell),
                sprite: sprite, frameID: frameID, rest: presence == .asleep)
            return
        }
        var grid = sprite.symbols(frameID: frameID)
        for diff in tile where diff.y >= 0 && diff.y < CompanionSprite.gridHeight
            && diff.x >= 0 && diff.x < CompanionSprite.gridWidth {
            grid[diff.y][diff.x] = diff.symbol
        }
        var top = baseTop
        // Same inhale lift as the watch stage.
        if frameID == "breathe" { top -= cell }
        var paths: [Character: Path] = [:]
        for y in 0..<CompanionSprite.gridHeight {
            for x in 0..<CompanionSprite.gridWidth {
                let symbol = grid[y][x]
                guard symbol != "." else { continue }
                paths[symbol, default: Path()].addRect(
                    CGRect(x: CGFloat(x) * cell, y: top + CGFloat(y) * cell, width: cell, height: cell))
            }
        }
        for (symbol, path) in paths {
            if let hex = sprite.paletteHex[symbol] {
                let rgb = CompanionSprite.hexToRGB(hex)
                ctx.fill(path, with: .color(Color(.sRGB,
                    red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)))
            }
        }
    }
}
