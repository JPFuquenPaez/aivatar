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
    /// Gradient fill (v3 volumetric shading): top stop color. When
    /// `useGradient` is false this is the flat fill color and (r2,g2,b2)
    /// mirror it.
    var r: Float = 1
    var g: Float = 1
    var b: Float = 1
    /// Gradient bottom stop color.
    var r2: Float = 1
    var g2: Float = 1
    var b2: Float = 1
    var a: Float = 1
    var useGradient: Bool = false
}

/// Prebuilt shape: one CGPath per bend slice plus slice local offsets
/// (§6 mesh deformation approximated as along-bone slices; rigid parts have
/// a single slice). The v3 cloud head ("blob") uses the slice array for its
/// three puffs — separate fills so the raised middle puff occludes the side
/// puffs (the depth cue of the reference renders).
nonisolated struct PaintedShape {
    var paths: [CGPath]
    /// Slice offset from the shape origin along the bone (-Y), rig points.
    var offsetsY: [Float]
    /// Per-slice rotation fraction (bend accumulation along the bone).
    var bendFractions: [Float]
    /// Per-path local height (gradient endpoints span the path's own bbox).
    var pathHeights: [Float]
    /// Per-path shade multiplier (1 = fully lit; the cloud head's side puffs
    /// sit at ~0.86 so the middle puff reads as raised toward the light).
    var pathShades: [Float]
    /// True when each path is a self-shaded mass (the cloud head's puffs):
    /// the gradient spans each path's own bbox. False for bend slices —
    /// the gradient then spans the WHOLE shape continuously so a sliced
    /// capsule shades as one volume, not bands.
    var perPathGradient: Bool
    var width: Float
    var height: Float
}

/// Interiority tuning (A5d): the persistent traces the companion keeps —
/// fed from CompanionMemory at context build, NOT from the engine clock
/// (determinism: memory is an input, like the seed). Neutral by default
/// so untuned renders (tests, previews) match the pinned look exactly.
nonisolated struct InteriorityTuning: Sendable {
    /// Willow's tended sprout: 0.2 (just sprouted) ... 1.0 (mature).
    /// 1.0 = the A5a look; scales the soil pod and the sprout leaf.
    var sproutGrowth: Float = 1
    /// Compass's audit artifact: the week grid. 0 hides it (default);
    /// 1-7 lights `streakDays` cells and dims the rest — order made
    /// visible, the tidy artifact waiting for you.
    var streakDays: Int = 0
    /// Prism's found trinket: the day's small discovery, presented on
    /// return. Hidden by default.
    var trinketPresent = false

    static let `default` = InteriorityTuning()
}

/// Palette token resolution (§3: ArchetypeVisualSet tokens over the shared
/// rig). Roles in rig.json are tokens; the archetype supplies actual colors.
nonisolated enum PaletteRole: Sendable {
    case primary     // the ONE body accent hue (flat — no gradient, Mistral DNA)
    case primaryDim  // v1 fallback path only
    case deep        // v1 fallback path only
    case face        // ink: eyes/mouth/brows + beak/nose anchors
    case restDim     // rest LOD dim
    case accentA     // transient accent: spark particles + flicker tell swap
    case accentB     // flicker tell swap target
    case catchlight  // white eye catchlight (dead-eye guard)
    case paper       // white negative-space details (muzzle, tail tip)
    // v9 stage tone (rasterizer-only): the ambient background motes.
    case mote
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
        /// v7 face inset (§3, Tools/PIXEL_DESIGN.md): head-space X shift
        /// for the eye cluster (pupils/lids/brows), tuned per head width —
        /// 0 for every non-face slot. v9 adds faceInsetY (frog's dome eyes
        /// sit ON TOP of the head, so the whole eye cluster shifts up).
        let faceInsetX: Float
        let faceInsetY: Float
    }

    /// A species decoration (v3 trait tokens): a small prebuilt shape pinned
    /// to a bone with a fixed local offset — patches, grids, interior glows,
    /// sprout pods, wisp tips. `afterSlotName` injects the draw exactly after
    /// that slot so face-layer decorations (catchlights) still sit under the
    /// lids; nil draws after all slots (on top of the body). `id` names the
    /// tell-animated decorations ("sproutLeaf", "grid").
    private struct Decoration {
        let boneIndex: Int
        let shapeIndex: Int
        let role: PaletteRole
        let localX: Float
        let localY: Float
        let rotation: Float
        let alpha: Float
        let afterSlotName: String?
        let id: String?
    }

    private var slots: [Slot] = []
    private var decorations: [Decoration] = []
    private var slotIndexByName: [String: Int] = [:]
    private var catchlightShapeIndex = 0
    private var catchlights: [(boneIndex: Int, afterSlot: Int, localX: Float, localY: Float)] = []
    private var speciesSlots = false
    private var speciesAccentColor: (r: Float, g: Float, b: Float)?
    /// A5d interiority tuning (persistent traces): sprout growth, the
    /// audit week grid, the found trinket. Neutral = the pinned look.
    private let interiority: InteriorityTuning
    private(set) var shapes: [PaintedShape] = []
    private(set) var roleColors: [PaletteRole: (r: Float, g: Float, b: Float)] = [:]
    /// Prism's flicker table (v3 tell): accents swapped — a chromatic shift
    /// with zero per-frame cost (built once; selected by flag).
    private var flickerColors: [PaletteRole: (r: Float, g: Float, b: Float)] = [:]
    /// v3 volumetric shading: per-role gradient stops (top lightened toward
    /// white, bottom deepened toward the shadow tone), precomputed so the
    /// render loop only reads — the renderer caches fill objects per pair.
    private var gradientPairs: [PaletteRole: (top: (Float, Float, Float), bottom: (Float, Float, Float))] = [:]
    private var flickerGradientPairs: [PaletteRole: (top: (Float, Float, Float), bottom: (Float, Float, Float))] = [:]

    /// v7 (§1, Tools/PIXEL_DESIGN.md): the authored ramp stop colors —
    /// every gradient pair's lifted top + deepened bottom — so the
    /// rasterizer's LUT contains the FULL authored ramp (role + top +
    /// bottom). Without these, gradient pixels snap to whatever palette
    /// color happens to be nearest and the body reads as noise, not as
    /// a deliberate 3-4 tone cel ramp.
    var rampTonesForRasterizer: [(Float, Float, Float)] {
        var tones: [(Float, Float, Float)] = []
        tones.reserveCapacity(gradientPairs.count * 2)
        for (_, pair) in gradientPairs {
            tones.append(pair.top)
            tones.append(pair.bottom)
        }
        return tones
    }

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

    /// Interiority trace hooks (A5d, test-visible): the sprout leaf's
    /// prebuilt shape index (Willow), for growth assertions.
    private(set) var sproutLeafShapeIndex: Int?

    /// v9 test-visible: the anchor decoration ids of this animal plan
    /// (ears/domes/beak/fin/casque...) — the identity anchors per the
    /// refactor brief.
    private(set) var anchorDecorationIDsForTesting: [String] = []
    private var headBoneIndex = 0

    init(skeleton: Skeleton, visualSet: ArchetypeVisualSet,
         interiority: InteriorityTuning = .default) {
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

        // v9 animal icons (Tools/PIXEL_DESIGN.md v3): species archetypes
        // paint from an AnimalPlan — the frozen rig slots are re-purposed
        // per animal (kind + scale + role), and hidden slots (scale <= 0)
        // paint nothing, keeping each animal to 3-5 solid shapes + face.
        let plan = visualSet.isSpecies ? Self.animalPlan(visualSet.archetype) : nil
        for slot in sorted {
            guard let boneIndex = skeleton.boneIndex(slot.bone) else { continue }
            if armBones.contains(slot.bone) { continue }
            let archetype = visualSet.isSpecies ? visualSet.archetype : nil
            if let plan, let animal = plan.slots[slot.name] {
                if animal.w <= 0 || animal.h <= 0 { continue }  // hidden part
                let spec = RigDocument.Shape(
                    kind: slot.shape.kind,
                    width: slot.shape.width * animal.w,
                    height: slot.shape.height * animal.h,
                    bendSegments: slot.shape.bendSegments
                )
                shapes.append(Self.buildShape(spec, kind: animal.kind))
                slots.append(Slot(
                    name: slot.name,
                    boneIndex: boneIndex,
                    shapeIndex: shapes.count - 1,
                    role: animal.role ?? Self.resolveRole(slot.paletteRole),
                    roleOverride: nil,
                    faceInsetX: Self.speciesFaceInset(archetype: archetype, slotName: slot.name),
                    faceInsetY: Self.speciesFaceInsetY(archetype: archetype, slotName: slot.name)
                ))
                slotIndexByName[slot.name] = slots.count - 1
                continue
            }
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
                role: Self.resolveRole(slot.paletteRole),
                roleOverride: nil,
                faceInsetX: 0,
                faceInsetY: 0
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

        self.interiority = interiority
        if let plan, visualSet.isSpecies {
            buildAnimalDecorations(skeleton: skeleton, plan: plan, archetype: visualSet.archetype)
        }

        roleColors = Self.resolveColors(visualSet: visualSet)
        // v9 flat (Mistral DNA): NO gradient stops — every shape is one
        // solid LUT color. The flicker table swaps the body hue with the
        // archetype's accentB for the chromatic tell (Prism).
        gradientPairs = [:]
        flickerGradientPairs = [:]
        flickerColors = roleColors
        if let primary = roleColors[.primary], let accentB = roleColors[.accentB] {
            flickerColors[.primary] = accentB
            flickerColors[.accentB] = primary
        }
        // Species sparks (Ember's tell) fly in the trait-token color.
        if visualSet.isSpecies {
            speciesAccentColor = roleColors[.accentA]
        }
    }

    /// v9 animal decorations: the identity anchors (ears, eye domes,
    /// beak, fins, casque...) from the plan, then the catchlights, then
    /// the A5d interiority traces (sprout / week grid / trinket).
    private func buildAnimalDecorations(skeleton: Skeleton, plan: AnimalPlan, archetype: Archetype) {
        func append(_ spec: RigDocument.Shape, kind: String, bone: String,
                    role: PaletteRole, x: Float, y: Float, rotation: Float = 0,
                    alpha: Float = 1, afterSlot: String? = nil, id: String? = nil) {
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
                afterSlotName: afterSlot,
                id: id
            ))
            if let id { anchorDecorationIDsForTesting.append(id) }
        }

        headBoneIndex = skeleton.boneIndex("head") ?? 0

        // Eye catchlights (dead-eye guard, U2): one white dot per pupil,
        // drawn right after the pupil slots so the lids still cover them on
        // a blink. Same eye style across the whole set (grid discipline).
        let catchlightSpec = RigDocument.Shape(kind: "circle", width: 3.0, height: 3.0, bendSegments: nil)
        shapes.append(Self.buildShape(catchlightSpec, kind: "circle"))
        catchlightShapeIndex = shapes.count - 1
        for pupil in ["pupilL", "pupilR"] {
            guard let slotIndex = slotIndexByName[pupil] else { continue }
            let inset = slots[slotIndex].faceInsetX
            catchlights.append((slots[slotIndex].boneIndex, slotIndex, -1.1 + inset, -1.1))
        }

        for deco in plan.decorations {
            append(RigDocument.Shape(kind: deco.kind, width: deco.w, height: deco.h, bendSegments: nil),
                   kind: deco.kind, bone: deco.bone, role: deco.role,
                   x: deco.x, y: deco.y, rotation: deco.rot, id: deco.id)
        }

        // A5d interiority traces (persistent, off by default except the sprout).
        switch archetype {
        
        case .willow:
            let s = max(0.2, min(1.4, 0.4 + 0.6 * interiority.sproutGrowth))
            append(RigDocument.Shape(kind: "circle", width: 5 * s, height: 4 * s, bendSegments: nil),
                   kind: "circle", bone: "hips", role: .face, x: 17, y: 9)
            append(RigDocument.Shape(kind: "triangle", width: 4 * s, height: 7 * s, bendSegments: nil),
                   kind: "leaf", bone: "hips", role: .accentA, x: 17, y: 3, rotation: 0.2,
                   id: "sproutLeaf")
            sproutLeafShapeIndex = shapes.count - 1
        case .compass:
            if interiority.streakDays > 0 {
                for day in 0..<7 {
                    let lit = day < min(interiority.streakDays, 7)
                    append(RigDocument.Shape(kind: "rect", width: 2.6, height: 2.6, bendSegments: nil),
                           kind: "patch", bone: "hips",
                           role: lit ? .accentA : .face,
                           x: Float(-10.5 + Double(day) * 3.5), y: 25,
                           alpha: lit ? 0.85 : 0.30,
                           id: "weekGrid")
                }
            }
        case .prism:
            if interiority.trinketPresent {
                append(RigDocument.Shape(kind: "rect", width: 5, height: 5, bendSegments: nil),
                       kind: "patch", bone: "head", role: .accentB,
                       x: 17, y: -10, rotation: Float.pi / 4, alpha: 0.9,
                       id: "trinket")
            }
        default:
            break
        }
    }

    // MARK: - v9 AnimalPlan (one reduced animal per category)

    /// v9 (Tools/PIXEL_DESIGN.md v3): one simplified animal per archetype,
    /// built from 3-5 flat solid shapes on the frozen rig slots plus the
    /// shared face rig. `w`/`h` <= 0 hides a slot entirely (the animal has
    /// no such part). Roles: body = .primary (the one accent hue), ink
    /// details = .face, white negative space = .paper.
    struct AnimalSlot {
        var kind: String
        var w: Float
        var h: Float
        var role: PaletteRole?
    }
    struct AnimalDeco {
        var kind: String
        var w: Float
        var h: Float
        var bone: String
        var x: Float
        var y: Float
        var rot: Float
        var role: PaletteRole
        var id: String?
    }
    struct AnimalPlan {
        var slots: [String: AnimalSlot]
        var decorations: [AnimalDeco]
    }

    /// The five animals (category -> anchor): Ember = fox (land/fire:
    /// pointed ears + snout), Willow = frog (amphibian: dome eyes on top),
    /// Compass = fish (water: tail fin + dorsal), Nimbus = bird (air:
    /// beak + single wing), Prism = chameleon (reptile: casque + curled
    /// tail). Slot base sizes come from rig.json (frozen schema).
    static func animalPlan(_ archetype: Archetype) -> AnimalPlan {
        // Common face rig: pupils 1.4x (big cute eyes), everything else
        // per animal below. Face slots keep the rig kinds.
        var slots: [String: AnimalSlot] = [
            "pupilL": AnimalSlot(kind: "pupil", w: 1.4, h: 1.45, role: .face),
            "pupilR": AnimalSlot(kind: "pupil", w: 1.4, h: 1.45, role: .face),
            "lidL": AnimalSlot(kind: "rect", w: 1.0, h: 1.0, role: .face),
            "lidR": AnimalSlot(kind: "rect", w: 1.0, h: 1.0, role: .face),
            "browL": AnimalSlot(kind: "rect", w: 1.0, h: 1.0, role: .face),
            "browR": AnimalSlot(kind: "rect", w: 1.0, h: 1.0, role: .face),
            "mouth": AnimalSlot(kind: "rect", w: 1.0, h: 1.0, role: .face),
        ]
        var decos: [AnimalDeco] = []
        switch archetype {
        case .ember:
            // FOX (land/fire): pear body, round head, white muzzle + ink
            // nose, two ear triangles, big tail with white tip.
            slots["torsoChest"] = AnimalSlot(kind: "puff", w: 1.15, h: 1.0, role: .primary)
            slots["torsoUpper"] = AnimalSlot(kind: "puff", w: 0.95, h: 0.75, role: .primary)
            slots["torsoLower"] = AnimalSlot(kind: "puff", w: 1.05, h: 0.8, role: .primary)
            slots["head"] = AnimalSlot(kind: "circle", w: 1.12, h: 1.02, role: .primary)
            slots["jaw"] = AnimalSlot(kind: "circle", w: 0.8, h: 0.9, role: .paper)
            slots["appendageA"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["appendageA2"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["appendageB"] = AnimalSlot(kind: "circle", w: 2.2, h: 1.6, role: .primary)
            slots["appendageB2"] = AnimalSlot(kind: "circle", w: 1.3, h: 1.0, role: .paper)
            decos = [
                AnimalDeco(kind: "triangle", w: 11, h: 15, bone: "head", x: -16, y: -19, rot: 0.25, role: .primary, id: "ear"),
                AnimalDeco(kind: "triangle", w: 11, h: 15, bone: "head", x: 16, y: -19, rot: -0.22, role: .primary, id: "ear"),
                AnimalDeco(kind: "triangle", w: 4.5, h: 4, bone: "head", x: 0, y: 17, rot: Float.pi, role: .face, id: "nose"),
            ]
        case .willow:
            // FROG (amphibian): wide squat body, wide head, two dome eyes
            // ON TOP (the eye cluster shifts up via faceInsetY), feet nubs.
            slots["torsoChest"] = AnimalSlot(kind: "puff", w: 1.55, h: 0.75, role: .primary)
            slots["torsoUpper"] = AnimalSlot(kind: "puff", w: 1.3, h: 0.6, role: .primary)
            slots["torsoLower"] = AnimalSlot(kind: "puff", w: 1.2, h: 0.55, role: .primary)
            slots["head"] = AnimalSlot(kind: "circle", w: 1.5, h: 0.7, role: .primary)
            slots["jaw"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["appendageA"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["appendageA2"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["appendageB"] = AnimalSlot(kind: "circle", w: 0, h: 0, role: nil)
            slots["appendageB2"] = AnimalSlot(kind: "circle", w: 0, h: 0, role: nil)
            decos = [
                AnimalDeco(kind: "circle", w: 11, h: 11, bone: "head", x: -19, y: -17, rot: 0, role: .primary, id: "eyeDome"),
                AnimalDeco(kind: "circle", w: 11, h: 11, bone: "head", x: 19, y: -17, rot: 0, role: .primary, id: "eyeDome"),
                AnimalDeco(kind: "circle", w: 8, h: 4, bone: "hips", x: -12, y: 13, rot: 0, role: .primary, id: "foot"),
                AnimalDeco(kind: "circle", w: 8, h: 4, bone: "hips", x: 12, y: 13, rot: 0, role: .primary, id: "foot"),
            ]
        case .compass:
            // FISH (water): one big oval body, tail-fin triangle at the
            // base, dorsal fin on top, two pectoral fins at the sides.
            slots["torsoChest"] = AnimalSlot(kind: "circle", w: 1.5, h: 1.15, role: .primary)
            slots["torsoUpper"] = AnimalSlot(kind: "puff", w: 1.2, h: 0.8, role: .primary)
            slots["torsoLower"] = AnimalSlot(kind: "puff", w: 1.3, h: 0.85, role: .primary)
            slots["head"] = AnimalSlot(kind: "circle", w: 1.0, h: 0.9, role: .primary)
            slots["jaw"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["mouth"] = AnimalSlot(kind: "circle", w: 0.45, h: 0.45, role: .face)
            slots["appendageA"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["appendageA2"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["appendageB"] = AnimalSlot(kind: "triangle", w: 2.6, h: 2.2, role: .primary)
            slots["appendageB2"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            decos = [
                AnimalDeco(kind: "triangle", w: 8, h: 9, bone: "head", x: 0, y: -20, rot: 0, role: .primary, id: "dorsalFin"),
                AnimalDeco(kind: "triangle", w: 7, h: 4.5, bone: "chest", x: -21, y: 2, rot: 0.5, role: .primary, id: "fin"),
                AnimalDeco(kind: "triangle", w: 7, h: 4.5, bone: "chest", x: 21, y: 2, rot: -0.5, role: .primary, id: "fin"),
            ]
        case .nimbus:
            // BIRD (air): round body + head, ink beak, ONE swept wing on
            // the left (asymmetry), tail feathers, two ink feet.
            slots["torsoChest"] = AnimalSlot(kind: "puff", w: 1.0, h: 0.95, role: .primary)
            slots["torsoUpper"] = AnimalSlot(kind: "puff", w: 0.9, h: 0.7, role: .primary)
            slots["torsoLower"] = AnimalSlot(kind: "puff", w: 1.0, h: 0.75, role: .primary)
            slots["head"] = AnimalSlot(kind: "circle", w: 1.15, h: 1.05, role: .primary)
            slots["jaw"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["appendageA"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["appendageA2"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["appendageB"] = AnimalSlot(kind: "triangle", w: 2.4, h: 2.0, role: .primary)
            slots["appendageB2"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            decos = [
                AnimalDeco(kind: "triangle", w: 7, h: 6, bone: "head", x: 0, y: 10, rot: Float.pi, role: .face, id: "beak"),
                AnimalDeco(kind: "leaf", w: 16, h: 9, bone: "chest", x: -18, y: -2, rot: 0.5, role: .primary, id: "wing"),
                AnimalDeco(kind: "rect", w: 4, h: 3.5, bone: "hips", x: -6, y: 15, rot: 0, role: .face, id: "foot"),
                AnimalDeco(kind: "rect", w: 4, h: 3.5, bone: "hips", x: 6, y: 15, rot: 0, role: .face, id: "foot"),
            ]
        case .prism:
            // CHAMELEON (reptile): body + head, casque crest on the head,
            // curled tail (stem + ball), two stub legs.
            slots["torsoChest"] = AnimalSlot(kind: "puff", w: 1.05, h: 1.05, role: .primary)
            slots["torsoUpper"] = AnimalSlot(kind: "puff", w: 0.95, h: 0.75, role: .primary)
            slots["torsoLower"] = AnimalSlot(kind: "puff", w: 1.05, h: 0.8, role: .primary)
            slots["head"] = AnimalSlot(kind: "circle", w: 1.05, h: 0.95, role: .primary)
            slots["jaw"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["appendageA"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["appendageA2"] = AnimalSlot(kind: "rect", w: 0, h: 0, role: nil)
            slots["appendageB"] = AnimalSlot(kind: "capsule", w: 0.9, h: 1.2, role: .primary)
            slots["appendageB2"] = AnimalSlot(kind: "circle", w: 1.9, h: 1.9, role: .primary)
            decos = [
                AnimalDeco(kind: "triangle", w: 9, h: 13, bone: "head", x: 0, y: -21, rot: 0.15, role: .primary, id: "casque"),
                AnimalDeco(kind: "rect", w: 5, h: 8, bone: "hips", x: -10, y: 10, rot: 0, role: .primary, id: "leg"),
                AnimalDeco(kind: "rect", w: 5, h: 8, bone: "hips", x: 10, y: 10, rot: 0, role: .primary, id: "leg"),
            ]
        }
        return AnimalPlan(slots: slots, decorations: decos)
    }

    /// v7/v9 face inset: eye-cluster spacing + vertical shift per animal
    /// (frog's domes sit on top of the head). Left slots get +d, right -d.
    static func speciesFaceInset(archetype: Archetype?, slotName: String) -> Float {
        guard let archetype else { return 0 }
        let d: Float
        switch archetype {
        case .ember: d = 2.0      // fox: close-set
        case .willow: d = -6.0    // frog: wide-set domes
        case .compass: d = 3.0    // fish: close-set
        case .nimbus: d = 2.5     // bird
        case .prism: d = 1.0      // chameleon
        }
        switch slotName {
        case "pupilL", "lidL", "browL": return d
        case "pupilR", "lidR", "browR": return -d
        default: return 0
        }
    }

    /// v9 vertical face inset: only the frog rides its eyes up into the
    /// domes; every other animal keeps the standard face line.
    static func speciesFaceInsetY(archetype: Archetype?, slotName: String) -> Float {
        guard archetype == .willow else { return 0 }
        switch slotName {
        case "pupilL", "pupilR", "lidL", "lidR", "browL", "browR": return -13
        default: return 0
        }
    }

    /// Shape-language geometry overrides (§5) — v1 fallback path only;
    /// species archetypes are authored by `animalPlan` instead.
    private static func resolvedKind(slotName: String, defaultKind: String,
                                      style: ShapeLanguage) -> String {
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

        // v9 flat icon palette (Mistral DNA, Tools/PIXEL_DESIGN.md v3):
        // ONE body accent + ink face + white (catchlight/paper) +
        // transient accents (sparks/flicker) + stage mote. No gradients,
        // no glow, no second body shade — flat solid shapes only.
        if let species = visualSet.species {
            let body = parse(species.bodyLight)
            var colors: [PaletteRole: (Float, Float, Float)] = [
                .primary: body,
                .face: parse(species.face),
                .catchlight: (1, 1, 1),
                .paper: (1, 1, 1),
                .accentA: parse(species.accentA),
                .restDim: dimmed(body),
                // v11: motes dimmer (25% of the body) — background dust,
                // never a competing focal tone. The factor must stay AWAY
                // from restDim's 0.22: restDim is excluded from the active
                // snap set, and a mote tone that equals it would smuggle
                // restDim-colored pixels into active frames.
                .mote: (body.0 * 0.25, body.1 * 0.25, body.2 * 0.25),
            ]
            if let accentB = species.accentB {
                colors[.accentB] = parse(accentB)
            }
            return colors
        }

        let primary = parse(visualSet.primaryHex)
        let deep = parse(visualSet.deepHex)
        let face = parse(visualSet.faceAccentHex)
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
            .mote: (primary.0 * 0.25, primary.1 * 0.25, primary.2 * 0.25),
        ]
    }

    /// Rim-light constants for the v1 blob fallback path only (the v9
    /// animal icons are flat and never use them).
    static let rimLight: (Float, Float, Float) = (0.92, 0.94, 1.0)
    static let rimLightAlpha: Float = 0.85

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
        var pathHeights: [Float] = []
        var pathShades: [Float] = []
        paths.reserveCapacity(max(segments, 3))
        offsetsY.reserveCapacity(max(segments, 3))

        func append(_ path: CGPath, centerY: Float, height: Float, shade: Float = 1) {
            paths.append(path)
            offsetsY.append(centerY)
            pathHeights.append(height)
            pathShades.append(shade)
        }

        if kind == "blob" {
            // Nimbus-head anatomy, v3 volumetric: THREE SEPARATE fills
            // (back-to-front: side puffs, then the raised middle puff on
            // top) with per-puff shade — the middle puff occludes the side
            // puffs and reads as raised toward the light. Proportions
            // measured from the source logo; face slots (pupils at
            // ±0.25w) stay on the middle puff, eyes slightly below its
            // center. pathShades: sides 0.86, middle 1.0.
            let midRect = CGRect(x: -w * 0.323, y: -h * 0.467,
                                 width: w * 0.646, height: h * 0.934)
            let leftRect = CGRect(x: -w * 0.557, y: -h * 0.148,
                                  width: w * 0.424, height: h * 0.614)
            let rightRect = CGRect(x: w * 0.202, y: -h * 0.148,
                                   width: w * 0.354, height: h * 0.604)
            let left = CGMutablePath(); left.addEllipse(in: leftRect)
            let right = CGMutablePath(); right.addEllipse(in: rightRect)
            let middle = CGMutablePath(); middle.addEllipse(in: midRect)
            append(left, centerY: Float(leftRect.midY), height: Float(leftRect.height), shade: 0.86)
            append(right, centerY: Float(rightRect.midY), height: Float(rightRect.height), shade: 0.86)
            append(middle, centerY: Float(midRect.midY), height: Float(midRect.height), shade: 1.0)
            // Rim-light crescent (species spec: faint silver rim light): a
            // thin ellipse laid along the middle puff's upper-left arc,
            // inset so it never crosses the silhouette edge. shade < 0 is
            // the painter's marker for a flat rim fill (see paint loop);
            // drawn last within the shape so it rides on the puff.
            // COMMAND-ORIGIN CONVENTION: the renderer's origin is the bone
            // transform applied to the SLICE CENTER (offsetsY[i]), and
            // paths are drawn in that local space — so the rim ellipse is
            // built relative to its own slice center (x = rimCx, y = 0),
            // NOT in absolute shape coordinates (the puff rects predate
            // this convention; do not copy their style for new paths).
            let rimCx = -w * 0.09
            let rimCy = -h * 0.36
            let rimRect = CGRect(
                x: rimCx - w * 0.15, y: -h * 0.045,
                width: w * 0.30, height: h * 0.09
            )
            let rim = CGMutablePath()
            rim.addEllipse(
                in: rimRect,
                transform: CGAffineTransform.identity
                    .translatedBy(x: rimCx, y: 0)
                    .rotated(by: -0.5)
                    .translatedBy(x: -rimCx, y: 0)
            )
            append(rim, centerY: Float(rimCy), height: Float(rimRect.height), shade: -1)
            bendFractions = [0, 0, 0, 0]
            return PaintedShape(paths: paths, offsetsY: offsetsY, bendFractions: bendFractions,
                                pathHeights: pathHeights, pathShades: pathShades,
                                perPathGradient: true,
                                width: shape.width, height: shape.height)
        }

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
            default:
                path.addRect(rect)
            }
            append(path, centerY: Float(top) + Float(sliceHeight) / 2, height: Float(sliceHeight))
            bendFractions.append(Float(i) / Float(segments))
        }
        return PaintedShape(paths: paths, offsetsY: offsetsY, bendFractions: bendFractions,
                           pathHeights: pathHeights, pathShades: pathShades,
                           perPathGradient: false,
                           width: shape.width, height: shape.height)
    }

    /// Paints the current pose into the command buffer. `rest` selects the
    /// dimmed rest palette (§6 LOD) — geometry comes from `world` either way.
    /// `accentPhase` is the active big-gesture phase (0...1) driving the
    /// archetype's spark-trail quirk (§8 accent particles). `tell`/`tellPhase`
    /// drive the v3 involuntary tells: Prism's accents flicker (color table
    /// swap), Nimbus's luminous pulse (a brightness wave traveling through
    /// the body masses), Willow's falling leaf (the sprout leaf's animated
    /// drop-and-return), Compass's grid flash (the tick's glow boost).
    func paint(world: [Transform2D], pose: AvatarPose, rest: Bool, accentPhase: Float = 0,
               tell: PersonalityTell? = nil, tellPhase: Float = 0) {
        commandCount = 0
        // v8: the flicker swap applies only while the tell is actually
        // playing (tellPhase > 0) — Prism's accents must not be permanently
        // swapped; the flicker is a transient chromatic shift on delight.
        let flickering = tell == .flicker && !rest && tellPhase > 0
        let colors = flickering ? flickerColors : roleColors
        let pairs = flickering ? flickerGradientPairs : gradientPairs
        let pulseActive = tell == .pulse && !rest && tellPhase > 0
        for (slotIndex, slot) in slots.enumerated() {
            let t = world[slot.boneIndex]
            let shape = shapes[slot.shapeIndex]
            let role = slot.roleOverride ?? slot.role
            let baseColor = rest
                ? colors[.restDim] ?? (1, 0, 1)
                : colors[role] ?? (1, 1, 1)
            // Volumetric fill: body masses and leaf/flame tokens take the
            // role's gradient stops (shade-adjusted per path so the cloud
            // head's side puffs read as turned away from the light); face
            // accents stay flat matte. Rest mode stays flat dim (§6 LOD).
            let pair = rest ? nil : pairs[role]
            let bend = pose.rotations[slot.boneIndex]
            let slices = shape.paths.count
            for i in 0..<slices {
                guard commandCount < commandCapacity else { return }
                var command = commands[commandCount]
                // Slice origin = bone world transform applied to the slice's
                // local center point (0, offsetY).
                let offX = shape.offsetsY[i] * t.c
                let offY = shape.offsetsY[i] * t.d
                // v7/v9 face inset (§3): head-space shift of the eye cluster
                // (X spacing per animal + Y for the frog's top domes),
                // applied through the bone transform so it rides breathing
                // tilt and gaze rotation like the rest of the face.
                let insetX = slot.faceInsetX
                let insetY = slot.faceInsetY
                command.tx = t.tx + offX + insetX * t.a + insetY * t.c
                command.ty = t.ty + offY + insetX * t.b + insetY * t.d
                command.rotation = atan2(t.b, t.a) + (slices > 1 ? bend * shape.bendFractions[i] : 0)
                command.scaleX = sqrt(t.a * t.a + t.b * t.b)
                command.scaleY = sqrt(t.c * t.c + t.d * t.d)
                command.shapeIndex = slot.shapeIndex
                command.pathIndex = i
                if let pair {
                    let shade = i < shape.pathShades.count ? shape.pathShades[i] : 1
                    if shade < 0, !rest {
                        // Rim-light crescent: flat near-silver, translucent —
                        // a spec highlight, never a sticker (U1: same matte
                        // stylization level, just a lighter stop).
                        command.r = Self.rimLight.0
                        command.g = Self.rimLight.1
                        command.b = Self.rimLight.2
                        command.r2 = Self.rimLight.0
                        command.g2 = Self.rimLight.1
                        command.b2 = Self.rimLight.2
                        command.a = Self.rimLightAlpha
                        command.useGradient = false
                        commands[commandCount] = command
                        commandCount += 1
                        continue
                    }
                    var top = pair.top
                    let bottom = pair.bottom
                    if shade < 1 {
                        // Side puffs: pull the lit stop toward the shadow
                        // stop — reads as turned away from the key light.
                        let k = 1 - shade
                        top.0 = top.0 + (bottom.0 - top.0) * k
                        top.1 = top.1 + (bottom.1 - top.1) * k
                        top.2 = top.2 + (bottom.2 - top.2) * k
                    }
                    command.r = top.0
                    command.g = top.1
                    command.b = top.2
                    command.r2 = bottom.0
                    command.g2 = bottom.1
                    command.b2 = bottom.2
                    command.useGradient = true
                } else {
                    command.r = baseColor.0
                    command.g = baseColor.1
                    command.b = baseColor.2
                    command.r2 = baseColor.0
                    command.g2 = baseColor.1
                    command.b2 = baseColor.2
                    command.useGradient = false
                }
                command.a = 1
                commands[commandCount] = command
                commandCount += 1
            }
            // Nimbus's pulse: a flat white overlay per body mass whose
            // opacity is the traveling wave (body slots draw before the
            // face slots, so the face is never washed out). Kept as an
            // overlay so the gradient stops stay static — the renderer's
            // fill cache never churns (§7 no per-frame allocations).
            if pulseActive {
                let position = Float(slotIndex) / Float(max(slots.count - 1, 1))
                let wave = max(0, 1 - abs(position - tellPhase))
                let overlayAlpha = 0.45 * wave * wave
                if overlayAlpha > 0.01, commandCount < commandCapacity {
                    var overlay = commands[commandCount]
                    overlay.tx = t.tx + shape.offsetsY[0] * t.c
                    overlay.ty = t.ty + shape.offsetsY[0] * t.d
                    overlay.rotation = atan2(t.b, t.a)
                    overlay.scaleX = sqrt(t.a * t.a + t.b * t.b)
                    overlay.scaleY = sqrt(t.c * t.c + t.d * t.d)
                    overlay.shapeIndex = slot.shapeIndex
                    overlay.pathIndex = 0
                    overlay.r = 1
                    overlay.g = 1
                    overlay.b = 1
                    overlay.r2 = 1
                    overlay.g2 = 1
                    overlay.b2 = 1
                    overlay.a = overlayAlpha
                    overlay.useGradient = false
                    commands[commandCount] = overlay
                    commandCount += 1
                }
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
                        localX: catchlight.localX,
                        localY: catchlight.localY,
                        rotation: 0,
                        alpha: 1,
                        world: world
                    )
                }
                for decoration in decorations where decoration.afterSlotName == slot.name {
                    emitDecoration(decoration, world: world, colors: colors, pairs: pairs,
                                   tell: tell, tellPhase: tellPhase)
                }
            }
        }
        // Top-phase decorations: on top of the body (patches, grids, glows).
        if !rest {
            for decoration in decorations where decoration.afterSlotName == nil {
                emitDecoration(decoration, world: world, colors: colors, pairs: pairs,
                               tell: tell, tellPhase: tellPhase)
            }
        }
        if !rest {
            stepAndPaintParticles(world: world, accentPhase: accentPhase)
        }
    }

    /// Emits one decoration command: a small prebuilt shape pinned to a
    /// bone at a fixed local offset, transformed by the bone's world
    /// transform (so tokens ride breathing/sway/blink motion for free).
    /// Tell effects apply to named decorations: the sprout leaf drops and
    /// returns (Willow), the grid flashes on the approval tick (Compass).
    private func emitDecoration(
        _ decoration: Decoration,
        world: [Transform2D],
        colors: [PaletteRole: (r: Float, g: Float, b: Float)],
        pairs: [PaletteRole: (top: (Float, Float, Float), bottom: (Float, Float, Float))],
        tell: PersonalityTell?,
        tellPhase: Float
    ) {
        var localX = decoration.localX
        var localY = decoration.localY
        var alpha = decoration.alpha
        if tellPhase > 0 {
            switch (tell, decoration.id) {
            case (.leaf, "sproutLeaf"):
                // One leaf falls; Willow catches it and puts it back:
                // fall (0...0.4), held (0.4...0.6), placed back (0.6...1).
                let drop: Float
                if tellPhase < 0.4 {
                    drop = GestureClipLibrary.easeInOut(tellPhase / 0.4)
                } else if tellPhase < 0.6 {
                    drop = 1
                } else {
                    drop = 1 - GestureClipLibrary.easeInOut((tellPhase - 0.6) / 0.4)
                }
                localY += 9 * drop
            case (.tick, "grid"):
                // The confirmation pulse: the interior grid glows once.
                alpha = min(1, alpha * (1 + sin(tellPhase * .pi) * 1.2))
            default:
                break
            }
        }
        // The sprout leaf and the v7 ears take foliage/anatomy gradient
        // depth; every other token (patches, grid, glow, catchlight)
        // stays flat matte by design.
        let pair = (decoration.id == "sproutLeaf" || decoration.id == "ear")
            ? pairs[decoration.role] : nil
        emitDecoration(
            boneIndex: decoration.boneIndex,
            shapeIndex: decoration.shapeIndex,
            role: decoration.role,
            localX: localX,
            localY: localY,
            rotation: decoration.rotation,
            alpha: alpha,
            world: world,
            colors: colors,
            gradientPair: pair
        )
    }

    private func emitDecoration(
        boneIndex: Int, shapeIndex: Int, role: PaletteRole,
        localX: Float, localY: Float, rotation: Float, alpha: Float,
        world: [Transform2D],
        colors: [PaletteRole: (r: Float, g: Float, b: Float)]? = nil,
        gradientPair: (top: (Float, Float, Float), bottom: (Float, Float, Float))? = nil
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
        let color = (colors ?? roleColors)[role] ?? (1, 1, 1)
        if let pair = gradientPair {
            command.r = pair.top.0
            command.g = pair.top.1
            command.b = pair.top.2
            command.r2 = pair.bottom.0
            command.g2 = pair.bottom.1
            command.b2 = pair.bottom.2
            command.useGradient = true
        } else {
            command.r = color.0
            command.g = color.1
            command.b = color.2
            command.r2 = color.0
            command.g2 = color.1
            command.b2 = color.2
            command.useGradient = false
        }
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
            command.r2 = face.0
            command.g2 = face.1
            command.b2 = face.2
            command.useGradient = false
            command.a = Float(p.life) / Float(p.maxLife) * 0.9
            commands[commandCount] = command
            commandCount += 1
        }
    }
}
