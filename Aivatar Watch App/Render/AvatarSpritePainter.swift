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
    }

    private var slots: [Slot] = []
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
        shapes.reserveCapacity(sorted.count + 1)
        commandCapacity = 160 // slots * max slices + particles + headroom
        commands = [SpriteCommand](repeating: SpriteCommand(), count: commandCapacity)
        scratchTransforms = [Transform2D](repeating: .identity, count: 8)
        emitsSparks = visualSet.emitsSparkTrail
        hipsBoneIndex = skeleton.boneIndex("hips") ?? 0

        for slot in sorted {
            guard let boneIndex = skeleton.boneIndex(slot.bone) else { continue }
            let kind = Self.resolvedKind(
                slotName: slot.name,
                defaultKind: slot.shape.kind,
                style: visualSet.shapeLanguage
            )
            shapes.append(Self.buildShape(slot.shape, kind: kind))
            slots.append(Slot(
                name: slot.name,
                boneIndex: boneIndex,
                shapeIndex: shapes.count - 1,
                role: Self.resolveRole(slot.paletteRole)
            ))
        }

        // Spark sprite for the accent particle pool (tiny upward triangle).
        if emitsSparks {
            let sparkSpec = RigDocument.Shape(kind: "triangle", width: 5, height: 5, bendSegments: nil)
            sparkShapeIndex = shapes.count
            shapes.append(Self.buildShape(sparkSpec, kind: "triangle"))
        }
        particles = [Particle](repeating: Particle(), count: Self.particlePoolSize)

        roleColors = Self.resolveColors(visualSet: visualSet)
    }

    /// Shape-language geometry overrides (§5): the shared rig's default part
    /// shapes are re-authored per archetype family so silhouettes separate
    /// (§11 silhouette readability) while the skeleton stays shared (§3).
    private static func resolvedKind(slotName: String, defaultKind: String, style: ShapeLanguage) -> String {
        switch slotName {
        case "head":
            switch style {
            case .angularClean: return "square"
            case .softCloud: return "blob"
            default: return defaultKind
            }
        case "appendageA", "appendageA2", "appendageB", "appendageB2":
            switch style {
            case .roundSparks, .crystalMix, .droopingLeaf: return "triangle"
            case .softCloud: return "circle"
            case .angularClean: return "rect"
            }
        default:
            return defaultKind
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

        let primary = parse(visualSet.primaryHex)
        let deep = parse(visualSet.deepHex)
        let face = parse(visualSet.faceAccentHex)
        // primaryDim: primary mixed toward deep.
        let dim = (
            primary.0 * 0.62 + deep.0 * 0.38,
            primary.1 * 0.62 + deep.1 * 0.38,
            primary.2 * 0.62 + deep.2 * 0.38
        )
        // Rest LOD: everything dimmed toward pure black (§6).
        func dimmed(_ c: (Float, Float, Float)) -> (Float, Float, Float) { (c.0 * 0.22, c.1 * 0.22, c.2 * 0.22) }

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
        // Triangles taper to a point: bending slices would break the apex,
        // so flame/leaf/crystal appendages stay rigid (§6 flat parts stay
        // rigid for fill rate).
        let segments = kind == "triangle" ? 1 : max(1, shape.bendSegments ?? 1)
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
            case "square":
                // Compass head: softly rounded square — dependable, not
                // harsh (§4.2 shape language).
                let r = min(w, h) * 0.14
                path.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
            case "blob":
                // Nimbus head: a soft cloud form, slightly wider than tall.
                let blobRect = CGRect(
                    x: rect.minX - w * 0.06,
                    y: rect.minY + h * 0.03,
                    width: rect.width * 1.12,
                    height: rect.height * 0.94
                )
                path.addEllipse(in: blobRect)
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
        for slot in slots {
            let t = world[slot.boneIndex]
            let shape = shapes[slot.shapeIndex]
            let color = rest
                ? roleColors[.restDim] ?? (1, 0, 1)
                : roleColors[slot.role] ?? (1, 1, 1)
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
        }
        if !rest {
            stepAndPaintParticles(world: world, accentPhase: accentPhase)
        }
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

        guard let face = roleColors[.face] else { return }
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
