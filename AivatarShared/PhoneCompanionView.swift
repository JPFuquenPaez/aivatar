import SwiftUI

/// PhoneCompanionView (v36, AMS v2 v43): the iPhone companion shell. "The
/// portrait and the companion" — the HD portrait (a photo of the companion)
/// beside the living authored grid (the companion itself, animated by
/// PhoneCompanionAnimator on the same 150 ms clock as the watch stage, with
/// the same ground tile and the same quantized tail channel). The portrait
/// is static by contract: no surface animates the HD art.
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
        HStack(spacing: size * 0.08) {
            portraitDisc
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
            .frame(width: liveSize, height: liveSize * 0.9)
        }
        .frame(width: size, height: size * 0.9)
    }

    /// The static HD portrait in a soft disc (never animated).
    private var portraitDisc: some View {
        let disc = size * 0.36
        return Group {
            if let portrait = PetImageRender.portraitImage(AuthoredSprites.sprite(for: archetype)) {
                Image(uiImage: portrait)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: disc, height: disc)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            } else {
                Circle()
                    .fill(PetImageRender.color(AuthoredSprites.sprite(for: archetype).uiAccentHex).opacity(0.25))
                    .frame(width: disc, height: disc)
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
    }

    private var liveSize: CGFloat { size * 0.60 }

    private func drawFrame(ctx: GraphicsContext, frameID: String) {
        let sprite = AuthoredSprites.sprite(for: archetype)
        let cell = liveSize / CGFloat(CompanionSprite.gridWidth)
        let baseTop = liveSize * 0.42 - cell * CGFloat(CompanionSprite.gridHeight) / 2
        // Same isometric ground tile as the watch stage (awake frames only)
        // + the tail part overlay (the living wag, same quantized channel).
        var tile = presence != .asleep
            ? SpriteStageMetadata.shadowOverlayIfAwake(archetype, frame: frameID, farewellPending: false)
            : []
        if !reduceMotion { tile += animator.tailOverlayCells }
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
