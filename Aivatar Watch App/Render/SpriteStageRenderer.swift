import SwiftUI
import WatchKit

/// SpriteStageRenderer (v13, Tools/PIXEL_DESIGN.md v5): draws the authored
/// CompanionSprite as flat cell rects — nearest-neighbor by construction,
/// no rasterizer, no snapping, zero antialiasing. One 20x18 grid, all
/// scales: the stage fills the screen width (~9-10 pt per art cell on
/// current cases — the same chunky class as the reference mascot), the
/// picker and complication icons reuse the identical grid.
///
/// Motion is the director's 150 ms discrete clock (SpriteDirector), not
/// 30 fps transforms. Rest / Always On: a single static sleepy frame in
/// the dimmed rest palette — no ticks, no subsecond updates.
struct SpriteStageRenderer: View {
    let director: SpriteDirector
    let sprite: CompanionSprite
    /// CI/smoke hook (-stageAwake): the simulator dims to Always On on
    /// idle, which would screenshot the rest frame instead of the live
    /// stage. Never set in normal use.
    let forceAwake: Bool

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    private var luminanceReduced: Bool { isLuminanceReduced && !forceAwake }
    @AppStorage("reduceMotionL2") private var reduceMotionL2 = false
    @State private var epoch = Date()
    /// A5c farewell beat (U9): the goodbye plays at full palette, then the
    /// stage hands over to the static dimmed rest frame — never a pop into
    /// the Always-On state (v12 persistent-display guidance).
    @State private var farewellPending = false
    @State private var farewellGeneration = 0
    /// v12 farewell dim ramp: the wipe goes to ~82% black over the beat,
    /// matching the rest body's dim factor.
    @State private var farewellTotalSeconds: Double = 0
    @State private var farewellStartedAt: Date?

    /// Resolved active/rest palettes (symbol -> sRGB Color, built once).
    private let activeColors: [Character: Color]
    /// Base palette hexes, kept so the v18 weather hue shift can re-derive
    /// the active palette per frame without touching the pinned grids.
    private let activeHex: [Character: String]
    private let restColors: [Character: Color]
    /// The self-play mote tone: 25% of the body hue — a toy, not weather.
    private let moteColor: Color

    init(director: SpriteDirector, sprite: CompanionSprite, forceAwake: Bool = false) {
        self.director = director
        self.sprite = sprite
        self.forceAwake = forceAwake
        var active: [Character: Color] = [:]
        var rest: [Character: Color] = [:]
        var hexes: [Character: String] = [:]
        var mote = Color.black
        for (token, hex) in sprite.paletteHex {
            hexes[token] = hex
            let rgb = CompanionSprite.hexToRGB(hex)
            active[token] = Color(.sRGB,
                red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
            // Rest LOD: near-black, species tint preserved (§6 OLED power).
            let f = token == "W" ? 0.30 : 0.22
            rest[token] = Color(.sRGB,
                red: Double(rgb.r) / 255 * f, green: Double(rgb.g) / 255 * f, blue: Double(rgb.b) / 255 * f)
            if token == "B" {
                mote = Color(.sRGB,
                    red: Double(rgb.r) / 255 * 0.25, green: Double(rgb.g) / 255 * 0.25, blue: Double(rgb.b) / 255 * 0.25)
            }
        }
        activeColors = active
        activeHex = hexes
        restColors = rest
        moteColor = mote
    }

    /// The palette for a frame: rest uses the dim LOD; active applies the
    /// v18 weather hue shift (only when non-zero) on top of the pinned LUT.
    private func palette(rest: Bool) -> [Character: Color] {
        guard !rest else { return restColors }
        let shift = director.weatherHueShiftDeg
        guard abs(shift) >= 0.5 else { return activeColors }
        var out: [Character: Color] = [:]
        for (token, hex) in activeHex {
            let rgb = CompanionSprite.hexToRGB(CompanionSprite.hueRotated(hex, degrees: Double(shift)))
            out[token] = Color(.sRGB,
                red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
        }
        return out
    }

    var body: some View {
        Group {
            if luminanceReduced && !farewellPending {
                Canvas { ctx, size in
                    drawFrame(ctx: ctx, size: size, frameID: "sleepy",
                              overlay: [], rest: true, mote: nil)
                }
            } else {
                TimelineView(.animation(minimumInterval: SpriteDirector.tickDuration)) { timeline in
                    Canvas { ctx, size in
                        draw(ctx: ctx, size: size, date: timeline.date)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: luminanceReduced) { reduced in
            if reduced {
                beginFarewell()
            } else {
                farewellGeneration += 1
                farewellPending = false
                director.setResting(false)
                HapticsChannel.shared.wake()
            }
        }
    }

    /// U9 farewell beat on the director clock: idle, a blink, then the
    /// sleepy frame — with the dim ramp wiping in over the same beat.
    private func beginFarewell() {
        director.handleEvent(.sleep)
        farewellPending = true
        farewellGeneration += 1
        let generation = farewellGeneration
        farewellStartedAt = Date()
        // v26: the ramp matches the bonded bloom (idle 1 + blink 2 + sleepy N),
        // so a level-4+ goodbye doesn't get cut off mid-ramp.
        farewellTotalSeconds = Double(3 + BondRules.farewellBloomTicks(director.bondLevel)) * SpriteDirector.tickDuration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(farewellTotalSeconds * 1_000_000_000))
            guard generation == farewellGeneration else { return }
            farewellPending = false
            director.setResting(true)
        }
    }

    /// v28: skip the Canvas redraw when nothing visible changed (OLED/battery
    /// on long idle holds) — key = frame + overlay + mote + hue + farewell ramp bucket.
    @State private var lastDrawKey = ""

    private func draw(ctx: GraphicsContext, size: CGSize, date: Date) {
        // Reduce Motion: L2 (in-app) > L1 (system). The director gates its
        // own scheduling; the renderer just forwards the resolved mode.
        director.accessibilityMode = resolveAccessibilityMode()
        let elapsed = date.timeIntervalSince(epoch)
        director.advance(toTick: Int((elapsed / SpriteDirector.tickDuration).rounded(.down)))
        // v15: session memory renders as authored overlay cells on whatever
        // frame plays (sprout / week grid / trinket); Aivatar 2.0 adds the
        // director's transient tells (blush / vapor / memento deposit) and
        // the E9.1 ground shadow — awake frames only: absent in the rest LOD
        // and during the farewell wipe (G9 + craft: the rest frame's lit-pixel
        // ratio is untouched).
        var baseOverlay = sprite.interiorityDiffs(director.interiority)
        // E5: while the memento deposit animates, the stepped-alpha copy in the
        // transient channel replaces the full-alpha interiority cell.
        if director.mementoDepositAlpha != nil {
            baseOverlay.removeAll { $0.x == 9 && $0.y == 16 && $0.symbol == "A" }
        }
        var overlay = baseOverlay + director.transientOverlayCells
        overlay += SpriteStageMetadata.shadowOverlayIfAwake(
            director.currentArchetype, frame: director.currentFrame, farewellPending: farewellPending)
        let rampBucket = farewellPending ? Int(date.timeIntervalSince(farewellStartedAt ?? date) / 0.15) : -1
        // v31: the overlay joins the key by CONTENT, not count — a streakDays
        // change 3->4 keeps count but changes symbols, and the week grid must
        // not stay stale until the next frame change.
        let overlayKey = overlay.map { "\($0.x),\($0.y),\($0.symbol)" }.joined()
        let key = "\(director.currentFrame)|\(overlayKey)|\(director.moteCell?.x ?? -1),\(director.moteCell?.y ?? -1)|\(director.weatherHueShiftDeg)|\(rampBucket)"
        if key == lastDrawKey { return }
        lastDrawKey = key
        drawFrame(ctx: ctx, size: size, frameID: director.currentFrame,
                  overlay: overlay, rest: false, mote: director.moteCell)
        if farewellPending, let start = farewellStartedAt, farewellTotalSeconds > 0 {
            // v28: the dim ramps over the LAST ticks (peak-end), not the whole
            // beat — the goodbye stays warm through idle+blink, then dims.
            let bloom = Double(BondRules.farewellBloomTicks(director.bondLevel)) * SpriteDirector.tickDuration
            let ramp = min(1, max(0, (date.timeIntervalSince(start) - (farewellTotalSeconds - bloom)) / bloom))
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.82 * ramp)))
        }
    }

    private func drawFrame(ctx: GraphicsContext, size: CGSize, frameID: String,
                           overlay: [CompanionSprite.CellDiff], rest: Bool,
                           mote: (x: Int, y: Int)?) {
        let grid = sprite.symbols(frameID: frameID, overlay: overlay)
        let palette = palette(rest: rest)
        // Fill-width cell: the sprite spans the screen width exactly and
        // its content center sits slightly above the vertical middle (face
        // in the upper-third glance zone, §9).
        let cell = size.width / CGFloat(CompanionSprite.gridWidth)
        let top = size.height * 0.46 - cell * CGFloat(CompanionSprite.gridHeight) / 2
        var paths: [Character: Path] = [:]
        var partialCells: [(rect: CGRect, symbol: Character, alpha: Float)] = []
        for y in 0..<CompanionSprite.gridHeight {
            for x in 0..<CompanionSprite.gridWidth {
                let symbol = grid[y][x]
                guard symbol != "." else { continue }
                let rect = CGRect(x: CGFloat(x) * cell, y: top + CGFloat(y) * cell,
                                  width: cell, height: cell)
                // Aivatar 2.0: transient overlays may carry sub-1 alpha
                // (memento deposit) — those draw individually, not batched.
                let alpha = overlay.first { $0.x == x && $0.y == y }?.alpha ?? 1
                if alpha >= 1 {
                    paths[symbol, default: Path()].addRect(rect)
                } else {
                    partialCells.append((rect, symbol, alpha))
                }
            }
        }
        for (symbol, path) in paths {
            if let color = palette[symbol] {
                ctx.fill(path, with: .color(color))
            }
        }
        for cell in partialCells {
            if let color = palette[cell.symbol] {
                ctx.fill(Path(cell.rect), with: .color(color.opacity(Double(cell.alpha))))
            }
        }
        // v16 self-play: the single drifting mote the companion chases.
        if let mote, !rest {
            let rect = CGRect(x: CGFloat(mote.x) * cell, y: top + CGFloat(mote.y) * cell,
                              width: cell, height: cell)
            ctx.fill(Path(rect), with: .color(moteColor))
        }
    }

    private func resolveAccessibilityMode() -> MotionAccessibilityMode {
        if reduceMotionL2 { return .reduceMotionL2 }
        if WKAccessibilityIsReduceMotionEnabled() { return .reduceMotionL1 }
        return .full
    }
}
