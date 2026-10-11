import Foundation
import CoreGraphics

/// One flattened draw command: shape + full world transform + resolved color.
/// Produced by `AvatarSpritePainter` into a pre-allocated buffer (no
/// allocation on the frame path) and consumed by the Canvas renderer (live)
/// and the CoreGraphics golden-frame rasterizer (tests).
nonisolated struct SpriteCommand: Sendable {
    /// World transform of the shape origin, rig space (205x251 points).
    var tx: Float = 0
    var ty: Float = 0
    var rotation: Float = 0
    var scaleX: Float = 1
    var scaleY: Float = 1
    /// Index into the painter's prebuilt shape (shapeIndex + pathIndex).
    var shapeIndex: Int = 0
    var pathIndex: Int = 0
    /// Resolved color, 0...1 linear components.
    var r: Float = 1
    var g: Float = 1
    var b: Float = 1
    var a: Float = 1
}

/// Prebuilt shape: one CGPath per bend slice plus slice local offsets
/// (§6 mesh deformation approximated as along-bone slices; rigid parts have
/// a single slice).
nonisolated struct PaintedShape {
    var paths: [CGPath]
    /// Slice offset from the shape origin along the bone (-Y), rig points.
    var offsetsY: [Float]
    /// Per-slice rotation fraction (bend accumulation along the bone).
    var bendFractions: [Float]
    var width: Float
    var height: Float
}

/// Palette token resolution (§3: ArchetypeVisualSet tokens over the shared
/// rig). Roles in rig.json are tokens; the archetype supplies actual colors.
nonisolated enum PaletteRole: Sendable {
    case primary
    case primaryDim
    case deep
    case face
    case restDim
    // v3 species roles (A5a): tint -> token -> tell.
    case bodyLight   // light upper mass (head middle puff, chest top)
    case accentA     // trait token A
    case accentB     // trait token B
    case glow        // interior glow (Ember embers)
    case catchlight  // the single bright eye catchlight (dead-eye guard)
}

/// Converts rig + pose + visual set into the per-frame sprite command list.
/// All buffers and CGPaths are built once at init; `paint()` writes in place.
nonisolated final class AvatarSpritePainter {
    let commandCapacity: Int
    private(set) var commands: [SpriteCommand]
    private(set) var commandCount = 0

    /// Slots in draw order (back to front) with their prebuilt shapes.
    private struct Slot {
        let name: String
        let boneIndex: Int
        let shapeIndex: Int
        let role: PaletteRole
        /// Species token color override (e.g. Ember's flame tip accent).
        let roleOverride: PaletteRole?
    }

    /// A species decoration (v3 trait tokens): a small prebuilt shape pinned
    /// to a bone with a fixed local offset — patches, grids, interior glows,
    /// sprout pods, wisp tips. `afterSlotName` injects the draw exactly after
    /// that slot so face-layer decorations (catchlights) still sit under the
    /// lids; nil draws after all slots (on top of the body).
    private struct Decoration {
        let boneIndex: Int
        let shapeIndex: Int
        let role: PaletteRole
        let localX: Float
        let localY: Float
        let rotation: Float
        let alpha: Float
        let afterSlotName: String?
    }

    private var slots: [Slot] = []
    private var decorations: [Decoration] = []
    private var slotIndexByName: [String: Int] = [:]
    private var catchlightShapeIndex = 0
    private var catchlights: [(boneIndex: Int, afterSlot: Int)] = []
    private var speciesSlots = false
    private var speciesAccentColor: (r: Float, g: Float, b: Float)?
    private(set) var shapes: [PaintedShape] = []
    private(set) var roleColors: [PaletteRole: (r: Float, g: Float, b: Float)] = [:]

    private var scratchTransforms: [Transform2D]

    /// Accent particle pool (§8: "Ember sparks; capped pool, pre-allocated").
    /// Deterministic: a fixed-seed RNG is drawn from only while emitting, so
    /// the same pose sequence produces the same sparks (CI golden frames).
    private struct Particle {
        var x: Float = 0
        var y: Float = 0
        var vx: Float = 0
        var vy: Float = 0
        var life: Int = 0
        var maxLife: Int = 1
        var size: Float = 3
    }
    private static let particlePoolSize = 12
    private var particles: [Particle] = []
    private var particleRng = SeededRandom(0x5E_A7_C0)
    private let emitsSparks: Bool
    private var sparkShapeIndex = 0
    private let hipsBoneIndex: Int

    init(skeleton: Skeleton, visualSet: ArchetypeVisualSet) {
        let rig = skeleton.document
        var sorted = rig.slots
        sorted.sort { $0.drawOrder < $1.drawOrder }
        slots.reserveCapacity(sorted.count)
        shapes.reserveCapacity(sorted.count + 8)
        commandCapacity = 160 // slots * max slices + decorations + particles
        commands = [SpriteCommand](repeating: SpriteCommand(), count: commandCapacity)
        scratchTransforms = [Transform2D](repeating: .identity, count: 8)
        emitsSparks = visualSet.emitsSparkTrail
        hipsBoneIndex = skeleton.boneIndex("hips") ?? 0
        speciesSlots = visualSet.isSpecies

        // v3 species (U5: never drift humanoid): the limbless cloud anatomy
        // paints no arm slots. The arm bones stay in the (frozen) skeleton —
        // dormant, unsolved-for-paint — so a future direction can revive
        // them without a rig migration.
        let armBones: Set<String> = visualSet.isLimbless
            ? ["upperArmL", "upperArmR", "forearmL", "forearmR", "handL", "handR"]
            : []

        for slot in sorted {
            guard let boneIndex = skeleton.boneIndex(slot.bone) else { continue }
            if armBones.contains(slot.bone) { continue }
            let kind = Self.resolvedKind(
                slotName: slot.name,
                defaultKind: slot.shape.kind,
                style: visualSet.shapeLanguage,
                species: visualSet.isSpecies ? visualSet.archetype : nil
            )
            shapes.append(Self.buildShape(slot.shape, kind: kind))
            slots.append(Slot(
                name: slot.name,
                boneIndex: boneIndex,
                shapeIndex: shapes.count - 1,
                role: Self.resolveRole(slot.paletteRole),
                roleOverride: Self.speciesRoleOverride(
                    slotName: slot.name,
                    archetype: visualSet.isSpecies ? visualSet.archetype : nil
                )
            ))
            slotIndexByName[slot.name] = slots.count - 1
        }

        // Spark sprite for the accent particle pool (tiny upward triangle).
        if emitsSparks {
            let sparkSpec = RigDocument.Shape(kind: "triangle", width: 5, height: 5, bendSegments: nil)
            sparkShapeIndex = shapes.count
            shapes.append(Self.buildShape(sparkSpec, kind: "triangle"))
        }
        particles = [Particle](repeating: Particle(), count: Self.particlePoolSize)

        if visualSet.isSpecies {
            buildSpeciesDecorations(skeleton: skeleton, archetype: visualSet.archetype)
        }

        roleColors = Self.resolveColors(visualSet: visualSet)
        // Species sparks (Ember's tell) fly in the trait-token color, not
        // the near-black face accent.
        if visualSet.isSpecies {
            speciesAccentColor = roleColors[.accentA]
        }
    }

    /// v3 trait tokens per archetype (§6 v2: tint -> ONE token -> tell).
    /// Decorations are bone-pinned prebuilt shapes drawn at fixed local
    /// offsets; all colors come from the species palette roles.
    private func buildSpeciesDecorations(skeleton: Skeleton, archetype: Archetype) {
        func append(_ spec: RigDocument.Shape, kind: String, bone: String,
                    role: PaletteRole, x: Float, y: Float, rotation: Float = 0,
                    alpha: Float = 1, afterSlot: String? = nil) {
            guard let boneIndex = skeleton.boneIndex(bone) else { return }
            shapes.append(Self.buildShape(spec, kind: kind))
            decorations.append(Decoration(
                boneIndex: boneIndex,
                shapeIndex: shapes.count - 1,
                role: role,
                localX: x,
                localY: y,
                rotation: rotation,
                alpha: alpha,
                afterSlotName: afterSlot
            ))
        }

        // Eye catchlights (dead-eye guard, U2): one bright dot per pupil,
        // drawn right after the pupil slots so the lids still cover them on
        // a blink. Pupils never shrink (small pupils read cold).
        let catchlightSpec = RigDocument.Shape(kind: "circle", width: 2.2, height: 2.2, bendSegments: nil)
        shapes.append(Self.buildShape(catchlightSpec, kind: "circle"))
        catchlightShapeIndex = shapes.count - 1
        for pupil in ["pupilL", "pupilR"] {
            guard let slotIndex = slotIndexByName[pupil] else { continue }
            catchlights.append((slots[slotIndex].boneIndex, slotIndex))
        }

        switch archetype {
        case .ember:
            // Interior embers visible through the translucency: two soft
            // glows in the lower body, capped well under 20% of body area
            // (glow budget, v3 10.4). The flame tip is the appendageA2 slot
            // kind; the glow is decoration.
            append(RigDocument.Shape(kind: "circle", width: 13, height: 8, bendSegments: nil),
                   kind: "circle", bone: "chest", role: .glow, x: 0, y: -3, alpha: 0.55)
            append(RigDocument.Shape(kind: "circle", width: 9, height: 6, bendSegments: nil),
                   kind: "circle", bone: "chest", role: .glow, x: 4, y: 8, alpha: 0.35)
        case .willow:
            // The tended sprout floats beside it in a small soil-pod
            // (interiority made discoverable; the plant itself grows in a
            // later pass).
            append(RigDocument.Shape(kind: "circle", width: 5, height: 4, bendSegments: nil),
                   kind: "circle", bone: "hips", role: .deep, x: 17, y: 9)
            append(RigDocument.Shape(kind: "triangle", width: 4, height: 7, bendSegments: nil),
                   kind: "leaf", bone: "hips", role: .accentA, x: 17, y: 3, rotation: 0.2)
        case .compass:
            // The interior progress grid (order token): thin cyan lines on
            // the chest, inside the "translucency". U3: precision lives in
            // the grid and the timing, never in hard edges.
            for (gx, gy) in [(-4.0, 0.0), (0.0, 0.0), (4.0, 0.0)] {
                append(RigDocument.Shape(kind: "rect", width: 1.2, height: 13, bendSegments: nil),
                       kind: "rect", bone: "chest", role: .accentA, x: Float(gx), y: Float(gy), alpha: 0.55)
            }
            for gy in [-5.0, 0.0, 5.0] {
                append(RigDocument.Shape(kind: "rect", width: 11, height: 1.2, bendSegments: nil),
                       kind: "rect", bone: "chest", role: .accentA, x: 0, y: Float(gy), alpha: 0.55)
            }
        case .prism:
            // Sticker patches: max two, matte (v3 10.4 — the one mismatch is
            // the wisp tips, drawn as slot kind + tip below).
            append(RigDocument.Shape(kind: "rect", width: 7, height: 7, bendSegments: nil),
                   kind: "patch", bone: "chest", role: .accentA, x: -7, y: -2, rotation: 0.1)
            append(RigDocument.Shape(kind: "rect", width: 6, height: 6, bendSegments: nil),
                   kind: "patch", bone: "chest", role: .accentB, x: 7, y: 3, rotation: -0.15)
            // Mismatched wisp tips: triangle (slot) + round (decoration).
            append(RigDocument.Shape(kind: "circle", width: 3.5, height: 3.5, bendSegments: nil),
                   kind: "circle", bone: "appendageA2", role: .accentB, x: 3, y: -4)
        case .nimbus:
            // Reference specimen: no extra token — identity is the lavender
            // tint and the tell (the post-event pulse, engine-side A5b).
            break
        }
    }

    /// Shape-language geometry overrides (§5): the shared rig's default part
    /// shapes are re-authored per archetype family. With `species` non-nil
    /// (v3 unified cloud-species), every archetype shares one anatomy — the
    /// 3-puff cloud head, stacked puff masses, wisp antenna — and only the
    /// token slots (antenna tip, tail wisps) vary per temperament.
    private static func resolvedKind(slotName: String, defaultKind: String,
                                      style: ShapeLanguage, species: Archetype?) -> String {
        guard let species else {
            switch slotName {
            case "head":
                switch style {
                case .angularClean: return "square"
                case .softCloud: return "blob"
                default: return defaultKind
                }
            case "appendageA", "appendageA2", "appendageB", "appendageB2":
                switch style {
                case .roundSparks, .crystalMix: return "triangle"
                case .droopingLeaf: return "leaf"
                case .softCloud: return "circle"
                case .angularClean: return "rect"
                }
            default:
                return defaultKind
            }
        }

        // v3 shared species anatomy.
        switch slotName {
        case "head":
            return "blob"                        // 3-puff brand cloud, all five
        case "torsoLower", "torsoUpper", "torsoChest":
            return species == .compass && slotName == "torsoLower"
                ? "chamferPuff"                  // soft rounded chamfer (>=15% radius)
                : (species == .willow && slotName == "torsoLower"
                    ? "sagPuff"                  // the only cloud whose base droops
                    : "puff")
        case "jaw":
            return "puff"                        // chin puff
        case "appendageA":
            return "capsule"                     // wisp-antenna stem
        case "appendageA2":
            // Antenna tip = the archetype's one sharp accent, exactly one:
            // Ember flame, Willow leaf, Compass plumb, Prism triangle,
            // Nimbus round. (Ember's "never more than three flame tips":
            // antenna tip + head tuft only.)
            switch species {
            case .ember: return "flame"
            case .willow: return "leaf"
            case .prism: return "triangle"
            default: return "circle"
            }
        case "appendageB", "appendageB2":
            // Tail wisps: hanging leaf-wisps for Willow, smoke for Ember,
            // cloud wisps otherwise.
            return species == .willow ? "leaf" : "circle"
        case "pupilL", "pupilR":
            return "pupil"                        // large matte pupils (U2)
        default:
            return defaultKind
        }
    }

    /// Species slot color overrides: token slots take trait-token colors
    /// instead of the body-mass roles.
    private static func speciesRoleOverride(slotName: String, archetype: Archetype?) -> PaletteRole? {
        guard let archetype else { return nil }
        switch slotName {
        case "appendageA2":
            switch archetype {
            case .ember, .willow, .prism: return .accentA
            case .compass: return .accentB       // brushed-silver plumb tip
            default: return .bodyLight
            }
        case "appendageB", "appendageB2":
            return archetype == .willow ? .accentA : nil
        default:
            return nil
        }
    }

    /// Rig palette tokens -> archetype roles. The greybox tokens map onto the
    /// archetype palette so the shared rig re-tints per personality (§3).
    private static func resolveRole(_ token: String) -> PaletteRole {
        switch token {
        case "greyLight", "primary": return .primary
        case "greyMid": return .primaryDim
        case "face", "greyDark", "secondary": return .face
        default: return .deep
        }
    }

    private static func resolveColors(visualSet: ArchetypeVisualSet) -> [PaletteRole: (Float, Float, Float)] {
        func parse(_ hex: String) -> (Float, Float, Float) {
            let clean = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard clean.count == 6, let value = UInt64(clean, radix: 16) else {
                return (0.5, 0.5, 0.5)
            }
            let r = Float((value >> 16) & 0xFF) / 255
            let g = Float((value >> 8) & 0xFF) / 255
            let b = Float(value & 0xFF) / 255
            return (r, g, b)
        }

        // Rest LOD: everything dimmed toward pure black (§6).
        func dimmed(_ c: (Float, Float, Float)) -> (Float, Float, Float) { (c.0 * 0.22, c.1 * 0.22, c.2 * 0.22) }

        // v3 species palette (A5a): tint roles from the profile's
        // speciesTokens; roles absent from the stack fall back to the v1
        // palette so a v1 profile still renders (schema v2 is additive).
        if let species = visualSet.species {
            let bodyLight = parse(species.bodyLight)
            let bodyMid = parse(species.bodyMid)
            let shadow = parse(species.shadow)
            let face = parse(species.face)
            var colors: [PaletteRole: (Float, Float, Float)] = [
                .bodyLight: bodyLight,
                .primary: bodyLight,
                .primaryDim: bodyMid,
                .deep: shadow,
                .face: face,
                .accentA: parse(species.accentA),
                .restDim: dimmed(bodyLight),
                .catchlight: (1, 1, 1),
            ]
            if let accentB = species.accentB {
                colors[.accentB] = parse(accentB)
            }
            if let glow = species.glow {
                colors[.glow] = parse(glow)
            }
            return colors
        }

        let primary = parse(visualSet.primaryHex)
        let deep = parse(visualSet.deepHex)
        let face = parse(visualSet.faceAccentHex)
        // primaryDim: primary mixed toward deep.
        let dim = (
            primary.0 * 0.62 + deep.0 * 0.38,
            primary.1 * 0.62 + deep.1 * 0.38,
            primary.2 * 0.62 + deep.2 * 0.38
        )

        return [
            .primary: primary,
            .primaryDim: dim,
            .deep: deep,
            .face: face,
            .restDim: dimmed(primary),
        ]
    }

    private static func buildShape(_ shape: RigDocument.Shape, kind: String) -> PaintedShape {
        let w = CGFloat(shape.width)
        let h = CGFloat(shape.height)
        // Triangles, leaves, and the species token kinds taper or are tiny:
        // bending slices would break the apex or smear the token, so they
        // stay rigid (§6 flat parts stay rigid for fill rate).
        let rigidKinds: Set<String> = ["triangle", "leaf", "flame", "pupil", "patch", "blob"]
        let segments = rigidKinds.contains(kind) ? 1 : max(1, shape.bendSegments ?? 1)
        var paths: [CGPath] = []
        var offsetsY: [Float] = []
        var bendFractions: [Float] = []
        paths.reserveCapacity(segments)
        offsetsY.reserveCapacity(segments)
        bendFractions.reserveCapacity(segments)

        let sliceHeight = h / CGFloat(segments)
        for i in 0..<segments {
            let top = -h / 2 + sliceHeight * CGFloat(i)
            let rect = CGRect(x: -w / 2, y: top, width: w, height: sliceHeight)
            let path = CGMutablePath()
            switch kind {
            case "circle":
                if segments == 1 {
                    path.addEllipse(in: rect)
                } else {
                    path.addRoundedRect(in: rect, cornerWidth: w / 2, cornerHeight: w / 4)
                }
            case "capsule":
                path.addRoundedRect(
                    in: rect,
                    cornerWidth: w / 2,
                    cornerHeight: min(w / 2, sliceHeight / 2)
                )
            case "triangle":
                path.move(to: CGPoint(x: -w / 2, y: rect.maxY))
                path.addLine(to: CGPoint(x: w / 2, y: rect.maxY))
                path.addLine(to: CGPoint(x: 0, y: rect.minY))
                path.closeSubpath()
            case "leaf":
                // Willow's accent (§5 "drooping leaf curves"): a curved,
                // asymmetric teardrop — same attach/tip convention as the
                // triangle accents (base low, tip up), but both edges sweep
                // so the silhouette separates from the straight-edged
                // flame/crystal triangles of the other round archetypes.
                path.move(to: CGPoint(x: -w * 0.5, y: rect.maxY))
                path.addQuadCurve(
                    to: CGPoint(x: 0, y: rect.minY),
                    control: CGPoint(x: -w * 0.62, y: rect.minY + h * 0.15)
                )
                path.addQuadCurve(
                    to: CGPoint(x: -w * 0.5, y: rect.maxY),
                    control: CGPoint(x: w * 0.10, y: rect.minY + h * 0.55)
                )
                path.closeSubpath()
            case "square":
                // Compass head (v1 direction): softly rounded square —
                // dependable, not harsh (§4.2 shape language).
                let r = min(w, h) * 0.14
                path.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
            case "puff":
                // v3 species body mass: a wide soft ellipse — wider and
                // flatter than the v1 capsule so stacked masses read as
                // cloud, not torso (fill-rate-cheap, single path).
                path.addEllipse(in: CGRect(
                    x: -w * 0.62, y: -h * 0.46,
                    width: w * 1.24, height: h * 0.92
                ))
            case "sagPuff":
                // Willow's base mass: the only cloud whose forms droop
                // (botanical patience made physical). The ellipse's center
                // biases down and the bottom stretches past the slot rect —
                // the upper head stays round (U2 cuteness floor).
                path.addEllipse(in: CGRect(
                    x: -w * 0.66, y: -h * 0.30,
                    width: w * 1.32, height: h * 1.18
                ))
            case "chamferPuff":
                // Compass's order token: a soft rounded chamfer — the only
                // straight-ish edge in the family, with corner radius >= 15%
                // of the edge so it never reads as a cut in a soft body
                // (v3 audit finding 2).
                let r = min(w * 1.24, h) * 0.18
                path.addRoundedRect(
                    in: CGRect(x: -w * 0.62, y: -h * 0.46, width: w * 1.24, height: h * 0.92),
                    cornerWidth: r, cornerHeight: r
                )
            case "flame":
                // Ember's antenna tip: a symmetric curved teardrop, base
                // low, tip up — the archetype's one sharp accent.
                path.move(to: CGPoint(x: -w / 2, y: rect.maxY))
                path.addQuadCurve(
                    to: CGPoint(x: 0, y: rect.minY),
                    control: CGPoint(x: -w * 0.55, y: rect.minY + h * 0.2)
                )
                path.addQuadCurve(
                    to: CGPoint(x: w / 2, y: rect.maxY),
                    control: CGPoint(x: w * 0.55, y: rect.minY + h * 0.2)
                )
                path.closeSubpath()
            case "pupil":
                // v3 eyes (U2): large matte pupils — slightly larger than
                // the rig default; pupils never shrink (small pupils read
                // cold). The single catchlight is painted as a decoration.
                path.addEllipse(in: CGRect(
                    x: -w * 0.65, y: -h * 0.65, width: w * 1.3, height: h * 1.3
                ))
            case "patch":
                // Prism's sticker patches: small rounded squares, matte
                // (v3 audit finding 3: no holo sheen, max two patches).
                path.addRoundedRect(
                    in: rect, cornerWidth: w * 0.22, cornerHeight: w * 0.22
                )
            case "blob":
                // Nimbus head: the brand cloud (unified with the app icon's
                // logo geometry) — three overlapping puffs with the big
                // middle puff sitting higher, side puffs lower. Ellipses are
                // wound the same way, so a nonzero-winding fill renders the
                // union solidly. Same visual footprint as the old single
                // wide ellipse (roughly 1.11w x 0.93h); the face slots
                // (pupils at ±0.25w, brows at ±0.25w) stay on the middle
                // puff, eyes slightly below its center, as in the logo.
                // Proportions measured from the source logo.
                path.addEllipse(in: CGRect(            // middle puff
                    x: -w * 0.323, y: -h * 0.467,
                    width: w * 0.646, height: h * 0.934
                ))
                path.addEllipse(in: CGRect(            // left puff
                    x: -w * 0.557, y: -h * 0.148,
                    width: w * 0.424, height: h * 0.614
                ))
                path.addEllipse(in: CGRect(            // right puff
                    x: w * 0.202, y: -h * 0.148,
                    width: w * 0.354, height: h * 0.604
                ))
            default:
                path.addRect(rect)
            }
            paths.append(path)
            // Slice center in bone-local space (points along -Y are "up").
            offsetsY.append(Float(top) + Float(sliceHeight) / 2)
            bendFractions.append(Float(i) / Float(segments))
        }
        return PaintedShape(paths: paths, offsetsY: offsetsY, bendFractions: bendFractions, width: shape.width, height: shape.height)
    }

    /// Paints the current pose into the command buffer. `rest` selects the
    /// dimmed rest palette (§6 LOD) — geometry comes from `world` either way.
    /// `accentPhase` is the active big-gesture phase (0...1) driving the
    /// archetype's spark-trail quirk (§8 accent particles).
    func paint(world: [Transform2D], pose: AvatarPose, rest: Bool, accentPhase: Float = 0) {
        commandCount = 0
        for (slotIndex, slot) in slots.enumerated() {
            let t = world[slot.boneIndex]
            let shape = shapes[slot.shapeIndex]
            let role = slot.roleOverride ?? slot.role
            let color = rest
                ? roleColors[.restDim] ?? (1, 0, 1)
                : roleColors[role] ?? (1, 1, 1)
            let bend = pose.rotations[slot.boneIndex]
            let slices = shape.paths.count
            for i in 0..<slices {
                guard commandCount < commandCapacity else { return }
                var command = commands[commandCount]
                // Slice origin = bone world transform applied to the slice's
                // local center point (0, offsetY).
                let offX = shape.offsetsY[i] * t.c
                let offY = shape.offsetsY[i] * t.d
                command.tx = t.tx + offX
                command.ty = t.ty + offY
                command.rotation = atan2(t.b, t.a) + (slices > 1 ? bend * shape.bendFractions[i] : 0)
                command.scaleX = sqrt(t.a * t.a + t.b * t.b)
                command.scaleY = sqrt(t.c * t.c + t.d * t.d)
                command.shapeIndex = slot.shapeIndex
                command.pathIndex = i
                command.r = color.0
                command.g = color.1
                command.b = color.2
                command.a = 1
                commands[commandCount] = command
                commandCount += 1
            }
            // Face-phase injections: catchlights ride their pupil bone
            // (right after the pupil slot, still under the lids), then any
            // decoration keyed to this slot.
            if !rest {
                for catchlight in catchlights where catchlight.afterSlot == slotIndex {
                    emitDecoration(
                        boneIndex: catchlight.boneIndex,
                        shapeIndex: catchlightShapeIndex,
                        role: .catchlight,
                        localX: -1.1,
                        localY: -1.1,
                        rotation: 0,
                        alpha: 1,
                        world: world
                    )
                }
                for decoration in decorations where decoration.afterSlotName == slot.name {
                    emitDecoration(decoration, world: world)
                }
            }
        }
        // Top-phase decorations: on top of the body (patches, grids, glows).
        if !rest {
            for decoration in decorations where decoration.afterSlotName == nil {
                emitDecoration(decoration, world: world)
            }
        }
        if !rest {
            stepAndPaintParticles(world: world, accentPhase: accentPhase)
        }
    }

    /// Emits one decoration command: a small prebuilt shape pinned to a
    /// bone at a fixed local offset, transformed by the bone's world
    /// transform (so tokens ride breathing/sway/blink motion for free).
    private func emitDecoration(_ decoration: Decoration, world: [Transform2D]) {
        emitDecoration(
            boneIndex: decoration.boneIndex,
            shapeIndex: decoration.shapeIndex,
            role: decoration.role,
            localX: decoration.localX,
            localY: decoration.localY,
            rotation: decoration.rotation,
            alpha: decoration.alpha,
            world: world
        )
    }

    private func emitDecoration(
        boneIndex: Int, shapeIndex: Int, role: PaletteRole,
        localX: Float, localY: Float, rotation: Float, alpha: Float,
        world: [Transform2D]
    ) {
        guard commandCount < commandCapacity else { return }
        let t = world[boneIndex]
        var command = commands[commandCount]
        command.tx = t.tx + localX * t.a + localY * t.c
        command.ty = t.ty + localX * t.b + localY * t.d
        command.rotation = atan2(t.b, t.a) + rotation
        command.scaleX = sqrt(t.a * t.a + t.b * t.b)
        command.scaleY = sqrt(t.c * t.c + t.d * t.d)
        command.shapeIndex = shapeIndex
        command.pathIndex = 0
        let color = roleColors[role] ?? (1, 1, 1)
        command.r = color.0
        command.g = color.1
        command.b = color.2
        command.a = alpha
        commands[commandCount] = command
        commandCount += 1
    }

    /// Advances and draws the accent particle pool (§8). One spark is emitted
    /// per frame while a big gesture is active; particles rise, fade, and
    /// free their slot. The RNG is drawn from only when emitting, so the
    /// sequence stays deterministic for a fixed pose stream (CI golden frames).
    private func stepAndPaintParticles(world: [Transform2D], accentPhase: Float) {
        guard emitsSparks else { return }

        for i in particles.indices {
            var p = particles[i]
            if p.life > 0 {
                p.life -= 1
                p.x += p.vx
                p.y += p.vy
                p.vy -= 0.05 // sparks rise (-Y is up)
                particles[i] = p
            }
        }

        if accentPhase > 0 {
            for i in particles.indices where particles[i].life <= 0 {
                let hips = world[hipsBoneIndex]
                particles[i].x = hips.tx + particleRng.nextSignedFloat() * 24
                particles[i].y = hips.ty + particleRng.nextSignedFloat() * 18
                particles[i].vx = particleRng.nextSignedFloat() * 0.9
                particles[i].vy = -0.5 - particleRng.nextFloat() * 1.0
                particles[i].maxLife = 14 + Int(particleRng.nextFloat() * 10)
                particles[i].life = particles[i].maxLife
                particles[i].size = 2.2 + particleRng.nextFloat() * 2.2
                break // one spark per frame; capped pool
            }
        }

        guard let face = speciesAccentColor ?? roleColors[.face] else { return }
        for i in particles.indices {
            let p = particles[i]
            guard p.life > 0, commandCount < commandCapacity else { continue }
            var command = commands[commandCount]
            command.tx = p.x
            command.ty = p.y
            command.rotation = 0
            command.scaleX = p.size / 5
            command.scaleY = p.size / 5
            command.shapeIndex = sparkShapeIndex
            command.pathIndex = 0
            command.r = face.0
            command.g = face.1
            command.b = face.2
            command.a = Float(p.life) / Float(p.maxLife) * 0.9
            commands[commandCount] = command
            commandCount += 1
        }
    }
}
