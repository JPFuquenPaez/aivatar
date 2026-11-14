import SwiftUI
import WatchKit

/// LiveCompanionPreviewView (Aivatar 2.0, E2 "Meet them"): the companion picker
/// hero is the LIVING animal, not a static disc. A preview-configured
/// SpriteDirector (blink x 0.7, glance x 0.5, no motes/yawn/poke, mood calm,
/// life floor on) drives the same authored 20x18 grid through the same 150 ms
/// clock; after >= 8 ticks (1.2 s) of continuous dwell the animal performs its
/// owner quirk exactly once per page visit. Distinct seed stream
/// (stageSeed ^ 0x9BE2EEF1) so picker goldens never alias stage goldens.
///
/// Lifecycle: the director is created on appear and torn down on disappear —
/// the sheet's dismissal guarantees zero surviving directors/timers. Always
/// On (luminance reduced) freezes to the static idle frame (G9). Reduce Motion
/// L2 renders the static idle frame; L1 keeps the life floor but suppresses
/// the dwell quirk; accessibility type sizes fall back to the static disc
/// (handled by the caller).
struct LiveCompanionPreviewView: View {
    let archetype: Archetype
    let size: CGFloat
    /// Draws the selected ring around the hero (picker state), like the disc.
    var selected: Bool = false
    /// The picker's current page index — any page change resets the dwell
    /// counter, re-arming the once-per-visit quirk.
    var page: Int = 0
    /// E3: lets a parent (the naming ceremony) hold the live director to send
    /// a perk while the user types. Nil when no director is alive.
    var onDirectorChange: ((SpriteDirector?) -> Void)? = nil

    /// E3: trigger the perk act on the live preview director.
    func triggerPerk() { director?.playPerk() }

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @AppStorage("reduceMotionL2") private var reduceMotionL2 = false
    @State private var director: SpriteDirector?
    @State private var epoch = Date()

    /// The preview seed: the stage's stable per-archetype seed XOR a private
    /// constant (house rule: dedicated streams; String.hashValue banned).
    static func previewSeed(_ archetype: Archetype) -> UInt64 {
        let stageSeed = 20261010 + UInt64(Archetype.allCases.firstIndex(of: archetype) ?? 0)
        return stageSeed ^ 0x9BE2_EEF1
    }

    private var staticFrame: Bool {
        isLuminanceReduced || reduceMotionL2
    }

    var body: some View {
        ZStack {
            if staticFrame {
                Canvas { ctx, _ in
                    drawFrame(ctx: ctx, frameID: "idle", pose: .identity, size: size)
                }
            } else {
                TimelineView(.animation(minimumInterval: SpriteDirector.tickDuration)) { timeline in
                    Canvas { ctx, _ in
                        guard let director else { return }
                        director.accessibilityMode = resolveAccessibilityMode()
                        let elapsed = timeline.date.timeIntervalSince(epoch)
                        director.advance(toTick: Int((elapsed / SpriteDirector.tickDuration).rounded(.down)))
                        let pose = PetMotion.pose(frameID: director.currentFrame, frameAge: director.frameAge,
                                                  tick: director.tick, seed: director.seed)
                        drawFrame(ctx: ctx, frameID: director.currentFrame, pose: pose, size: size)
                    }
                }
            }
            if selected {
                Circle()
                    .stroke(SetupTheme.accent(for: archetype), lineWidth: 2.5)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard let profile = try? PersonalityProfile.load(archetype) else { return }
            let d = SpriteDirector(profile: profile, seed: Self.previewSeed(archetype))
            d.previewMode = true
            director = d
            onDirectorChange?(d)
        }
        .onDisappear {
            director = nil  // teardown: no surviving director ticks after the page/sheet
            onDirectorChange?(nil)
        }
        .onChange(of: page) { _ in
            director?.resetPreviewDwell()
        }
    }

    private func resolveAccessibilityMode() -> MotionAccessibilityMode {
        if reduceMotionL2 { return .reduceMotionL2 }
        if WKAccessibilityIsReduceMotionEnabled() { return .reduceMotionL1 }
        return .full
    }

    private func drawFrame(ctx: GraphicsContext, frameID: String, pose: PetMotion.Pose = .identity, size: CGFloat) {
        let sprite = AuthoredSprites.sprite(for: archetype)
        let cell = size / CGFloat(CompanionSprite.gridWidth)
        let baseTop = size * 0.46 - cell * CGFloat(CompanionSprite.gridHeight) / 2
        // Ground shadow (E9.1): awake preview frames carry it too.
        let overlay = SpriteStageMetadata.shadowOverlayIfAwake(archetype, frame: frameID, farewellPending: false)
        // v40: image-backed companions draw the HD pet (tile under it);
        // the inhale lift rides the frame transform.
        if sprite.isImageBacked, PetImageRender.uiImage(sprite) != nil {
            PetImageRender.drawOverlay(ctx: ctx,
                box: CGRect(x: 0, y: baseTop, width: size, height: size),
                cell: cell, sprite: sprite, cells: overlay)
            PetImageRender.draw(ctx: ctx,
                box: CGRect(x: 0, y: baseTop, width: size,
                            height: CGFloat(PetImageRender.imageBoxRows) * cell),
                sprite: sprite, pose: pose)
            return
        }
        let grid = sprite.symbols(frameID: frameID)
        var top = baseTop
        // v35: same inhale lift as the stage (one cell off the tile).
        if frameID == "breathe" { top -= cell }
        var paths: [Character: Path] = [:]
        var gridWithShadow = grid
        for diff in overlay {
            guard diff.x >= 0, diff.x < CompanionSprite.gridWidth,
                  diff.y >= 0, diff.y < CompanionSprite.gridHeight else { continue }
            gridWithShadow[diff.y][diff.x] = diff.symbol
        }
        for y in 0..<CompanionSprite.gridHeight {
            for x in 0..<CompanionSprite.gridWidth {
                let symbol = gridWithShadow[y][x]
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
