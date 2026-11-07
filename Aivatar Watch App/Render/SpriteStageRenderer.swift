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
        farewellTotalSeconds = 15 * SpriteDirector.tickDuration  // idle 1 + blink 2 + sleepy 12
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(farewellTotalSeconds * 1_000_000_000))
            guard generation == farewellGeneration else { return }
            farewellPending = false
            director.setResting(true)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize, date: Date) {
        // Reduce Motion: L2 (in-app) > L1 (system). The director gates its
        // own scheduling; the renderer just forwards the resolved mode.
        director.accessibilityMode = resolveAccessibilityMode()
        let elapsed = date.timeIntervalSince(epoch)
        director.advance(toTick: Int((elapsed / SpriteDirector.tickDuration).rounded(.down)))
        // v15: session memory renders as authored overlay cells on whatever
        // frame plays (sprout / week grid / trinket).
        let overlay = sprite.interiorityDiffs(director.interiority)
        drawFrame(ctx: ctx, size: size, frameID: director.currentFrame,
                  overlay: overlay, rest: false, mote: director.moteCell)
        if farewellPending, let start = farewellStartedAt, farewellTotalSeconds > 0 {
            let ramp = min(1, max(0, date.timeIntervalSince(start) / farewellTotalSeconds))
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
        for y in 0..<CompanionSprite.gridHeight {
            for x in 0..<CompanionSprite.gridWidth {
                let symbol = grid[y][x]
                guard symbol != "." else { continue }
                let rect = CGRect(x: CGFloat(x) * cell, y: top + CGFloat(y) * cell,
                                  width: cell, height: cell)
                paths[symbol, default: Path()].addRect(rect)
            }
        }
        for (symbol, path) in paths {
            if let color = palette[symbol] {
                ctx.fill(path, with: .color(color))
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
