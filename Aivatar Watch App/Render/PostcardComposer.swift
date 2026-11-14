import Foundation
import CoreGraphics

/// PostcardComposer (v22, Ambient Life F8): deterministic shareable
/// postcards of the user's ACTUAL companion. Inputs are (archetype, seed,
/// memory snapshot, moment) — all persisted or derivable — and the output
/// is a run of authored frames through the same director+sprite path as the
/// live stage, so a postcard is bit-exact reproducible: identical inputs ->
/// identical frame hashes (pinned). No server, no account; the share-sheet
/// export lands with the iPhone companion shell — the composer API is ready.
///
/// Privacy: captions are built from name/day/bond/weather-class words only —
/// never life-log content.
nonisolated struct PostcardInputs: Codable, Sendable, Equatable {
    var archetypeRaw: String
    var seed: UInt64
    var name: String
    var bondLevel: Int
    var dayCount: Int
    var streakDays: Int
    var weatherClassRaw: String?
    /// Aivatar 2.0 E4: true on the naming-day anniversary — the card carries a
    /// 3x3 accent stamp in the top corner. Optional so legacy payloads decode.
    var anniversary: Bool?

    init(archetypeRaw: String, seed: UInt64, name: String,
         bondLevel: Int = 1, dayCount: Int = 1, streakDays: Int = 0,
         weatherClassRaw: String? = nil, anniversary: Bool? = nil) {
        self.archetypeRaw = archetypeRaw
        self.seed = seed
        self.name = name
        self.bondLevel = bondLevel
        self.dayCount = dayCount
        self.streakDays = streakDays
        self.weatherClassRaw = weatherClassRaw
        self.anniversary = anniversary
    }
}

/// E4: the anniversary stamp — a 3x3 accent block in the card's top-right
/// corner, composed from the same seeded inputs and FNV-hash-pinned like the
/// frames themselves.
nonisolated enum PostcardStamp {
    static func cells() -> [CompanionSprite.CellDiff] {
        var cells: [CompanionSprite.CellDiff] = []
        for y in 0..<3 {
            for x in 17..<20 {
                cells.append(CompanionSprite.CellDiff(x, y, "A"))
            }
        }
        return cells
    }
}

nonisolated enum PostcardComposer {
    /// Frames per card (a ~3 s loop at the 150 ms director clock).
    static let frameCount = 20

    /// The auto-generated caption: "<name> · day N" + bond/weather words.
    /// House voice, <= 8 words; never raw kinds or life-log content.
    /// v25: localized (en/fr) with placeholders.
    static func caption(_ inputs: PostcardInputs) -> String {
        var parts = [String(format: String(localized: "postcard.day"), inputs.name, max(1, inputs.dayCount))]
        if BondRules.isConfidant(inputs.bondLevel) {
            parts.append(String(localized: "postcard.old_friends"))
        }
        if let weatherClassRaw = inputs.weatherClassRaw,
           let klass = ConditionClass(rawValue: weatherClassRaw), klass != .unknown {
            // v30: the class name is localized (was the raw English enum,
            // leaking into fr captions as "jour rain").
            let weatherKey = "weather.\(klass.rawValue)"
            let weatherName = NSLocalizedString(weatherKey, comment: "weather class name")
            #if DEBUG
            // v31: a missing weather key must fail loudly, not echo the key.
            assert(weatherName != weatherKey, "missing localization for \(weatherKey)")
            #endif
            parts.append(String(format: String(localized: "postcard.weather_day"), weatherName))
        }
        return parts.joined(separator: " · ")
    }

    /// The card's frames as symbol grids, deterministic per inputs. The
    /// card plays a seed-picked two-act moment at the bonded level (plus
    /// the confidant memento overlay at level 5). Corrupt inputs (unknown
    /// archetype, missing profile) degrade to the default companion's warm
    /// greeting — a postcard never fails to compose.
    /// v40: the card's frames as (frameID, overlay) pairs — the single
    /// source both the grid path (frames) and the HD-image path
    /// (frameImages) render from, so they can never diverge.
    static func frameSpecs(_ inputs: PostcardInputs) -> [(frameID: String, overlay: [CompanionSprite.CellDiff])] {
        let archetype = Archetype(rawValue: inputs.archetypeRaw) ?? .ember
        guard let profile = try? PersonalityProfile.load(archetype) else {
            return plainSpecs(seed: inputs.seed)
        }
        let director = SpriteDirector(profile: profile, seed: inputs.seed)
        director.bondLevel = min(max(inputs.bondLevel, 1), BondRules.maxLevel)
        // Seed-picked moment: the card is a genuine function of the seed.
        var rng = SeededRandom(inputs.seed)
        let pool: [SpriteDirector.SpriteAct] = [.quirk, .happy, .slowBlink, .perk]
        director.playSequence([pool[rng.nextInt(pool.count)], pool[rng.nextInt(pool.count)]])
        let sprite = AuthoredSprites.sprite(for: archetype)
        var overlay = sprite.interiorityDiffs(
            InteriorityTuning(sproutGrowth: 1, streakDays: inputs.streakDays,
                              trinketPresent: false,
                              confidantMemento: BondRules.isConfidant(director.bondLevel)))
        if inputs.anniversary == true {
            overlay += PostcardStamp.cells()
        }
        var out: [(frameID: String, overlay: [CompanionSprite.CellDiff])] = []
        for _ in 0..<frameCount {
            director.advance(toTick: director.tick + 1)
            out.append((director.currentFrame, overlay))
        }
        return out
    }

    static func frames(_ inputs: PostcardInputs) -> [[[Character]]] {
        let archetype = Archetype(rawValue: inputs.archetypeRaw) ?? .ember
        let sprite = AuthoredSprites.sprite(for: archetype)
        return frameSpecs(inputs).map { sprite.symbols(frameID: $0.frameID, overlay: $0.overlay) }
    }

    /// v40: the card's frames as rendered images — image-backed companions
    /// play the HD pet with each frame's transform (the postcard is alive).
    static func frameImages(_ inputs: PostcardInputs) -> [CGImage] {
        let archetype = Archetype(rawValue: inputs.archetypeRaw) ?? .ember
        return frameSpecs(inputs).compactMap {
            CompanionIcon.cgImage(for: archetype, frameID: $0.frameID, overlay: $0.overlay)
        }
    }

    /// The warm-greeting fallback (default companion, plain idle run).
    private static func plainSpecs(seed: UInt64) -> [(frameID: String, overlay: [CompanionSprite.CellDiff])] {
        guard let profile = try? PersonalityProfile.load(.ember) else { return [] }
        let director = SpriteDirector(profile: profile, seed: seed)
        director.playSequence([.happy])
        var out: [(frameID: String, overlay: [CompanionSprite.CellDiff])] = []
        for _ in 0..<frameCount {
            director.advance(toTick: director.tick + 1)
            out.append((director.currentFrame, []))
        }
        return out
    }

    /// FNV-1a hashes of the frame grids — the determinism pins.
    static func frameHashes(_ inputs: PostcardInputs) -> [UInt64] {
        frames(inputs).map { grid in
            var h: UInt64 = 0xcbf29ce484222325
            for row in grid { for c in row {
                h ^= UInt64(c.asciiValue ?? 0)
                h = h &* 0x100000001b3
            } }
            return h
        }
    }
}
