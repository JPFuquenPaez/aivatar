import Foundation

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

    init(archetypeRaw: String, seed: UInt64, name: String,
         bondLevel: Int = 1, dayCount: Int = 1, streakDays: Int = 0,
         weatherClassRaw: String? = nil) {
        self.archetypeRaw = archetypeRaw
        self.seed = seed
        self.name = name
        self.bondLevel = bondLevel
        self.dayCount = dayCount
        self.streakDays = streakDays
        self.weatherClassRaw = weatherClassRaw
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
            parts.append(String(format: String(localized: "postcard.weather_day"), klass.rawValue))
        }
        return parts.joined(separator: " · ")
    }

    /// The card's frames as symbol grids, deterministic per inputs. The
    /// card plays a seed-picked two-act moment at the bonded level (plus
    /// the confidant memento overlay at level 5). Corrupt inputs (unknown
    /// archetype, missing profile) degrade to the default companion's warm
    /// greeting — a postcard never fails to compose.
    static func frames(_ inputs: PostcardInputs) -> [[[Character]]] {
        let archetype = Archetype(rawValue: inputs.archetypeRaw) ?? .ember
        guard let profile = try? PersonalityProfile.load(archetype) else {
            return plainFrames(seed: inputs.seed)
        }
        let director = SpriteDirector(profile: profile, seed: inputs.seed)
        director.bondLevel = min(max(inputs.bondLevel, 1), BondRules.maxLevel)
        // Seed-picked moment: the card is a genuine function of the seed.
        var rng = SeededRandom(inputs.seed)
        let pool: [SpriteDirector.SpriteAct] = [.quirk, .happy, .slowBlink, .perk]
        director.playSequence([pool[rng.nextInt(pool.count)], pool[rng.nextInt(pool.count)]])
        let sprite = AuthoredSprites.sprite(for: archetype)
        let overlay = sprite.interiorityDiffs(
            InteriorityTuning(sproutGrowth: 1, streakDays: inputs.streakDays,
                              trinketPresent: false,
                              confidantMemento: BondRules.isConfidant(director.bondLevel)))
        var out: [[[Character]]] = []
        for _ in 0..<frameCount {
            director.advance(toTick: director.tick + 1)
            out.append(sprite.symbols(frameID: director.currentFrame, overlay: overlay))
        }
        return out
    }

    /// The warm-greeting fallback (default companion, plain idle run).
    private static func plainFrames(seed: UInt64) -> [[[Character]]] {
        guard let profile = try? PersonalityProfile.load(.ember) else { return [] }
        let director = SpriteDirector(profile: profile, seed: seed)
        director.playSequence([.happy])
        let sprite = AuthoredSprites.sprite(for: .ember)
        var out: [[[Character]]] = []
        for _ in 0..<frameCount {
            director.advance(toTick: director.tick + 1)
            out.append(sprite.symbols(frameID: director.currentFrame))
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
