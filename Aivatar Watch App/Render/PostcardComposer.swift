import Foundation
import CoreGraphics

/// PostcardComposer (v22 F8, v3): deterministic shareable postcards of the
/// user's ACTUAL companion. Inputs are (archetype, seed, memory snapshot,
/// moment) — all persisted or derivable — and the output is a run of the
/// same director + puppet path as the live stage, so a postcard is
/// bit-exact reproducible: identical inputs -> identical pose hashes
/// (pinned). No server, no account.
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
    /// Aivatar 2.0 E4: true on the naming-day anniversary — the card carries
    /// the accent stamp in the top corner. Optional so legacy payloads decode.
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

nonisolated enum PostcardComposer {
    /// Frames per card (a ~3 s loop at the 150 ms director clock).
    static let frameCount = 20

    /// The auto-generated caption: "<name> · day N" + bond/weather words.
    /// House voice, <= 8 words; never raw kinds or life-log content.
    static func caption(_ inputs: PostcardInputs) -> String {
        var parts = [String(format: String(localized: "postcard.day"), inputs.name, max(1, inputs.dayCount))]
        if BondRules.isConfidant(inputs.bondLevel) {
            parts.append(String(localized: "postcard.old_friends"))
        }
        if let weatherClassRaw = inputs.weatherClassRaw,
           let klass = ConditionClass(rawValue: weatherClassRaw), klass != .unknown {
            let weatherKey = "weather.\(klass.rawValue)"
            let weatherName = NSLocalizedString(weatherKey, comment: "weather class name")
            #if DEBUG
            assert(weatherName != weatherKey, "missing localization for \(weatherKey)")
            #endif
            parts.append(String(format: String(localized: "postcard.weather_day"), weatherName))
        }
        return parts.joined(separator: " · ")
    }

    /// The card's frames as director drives, deterministic per inputs. The
    /// card plays a seed-picked two-act moment at the bonded level. Corrupt
    /// inputs (unknown archetype, missing profile) degrade to the default
    /// companion's warm greeting — a postcard never fails to compose.
    static func drives(_ inputs: PostcardInputs) -> [PuppetDrive] {
        let archetype = Archetype(rawValue: inputs.archetypeRaw) ?? .ember
        guard let profile = try? PersonalityProfile.load(archetype) else {
            return plainDrives(seed: inputs.seed)
        }
        let director = SpriteDirector(profile: profile, seed: inputs.seed)
        director.bondLevel = min(max(inputs.bondLevel, 1), BondRules.maxLevel)
        var rng = SeededRandom(inputs.seed)
        let pool: [SpriteDirector.SpriteAct] = [.quirk, .happy, .slowBlink, .perk]
        director.playSequence([pool[rng.nextInt(pool.count)], pool[rng.nextInt(pool.count)]])
        director.interiority = InteriorityTuning(
            sproutGrowth: 1,
            streakDays: inputs.streakDays,
            trinketPresent: false,
            confidantMemento: BondRules.isConfidant(director.bondLevel))
        var out: [PuppetDrive] = []
        for _ in 0..<frameCount {
            out.append(director.puppetDrive(atTick: director.tick + 1))
        }
        return out
    }

    /// The card's frame images: the clay-styled puppet posed by the drive
    /// run — the same resolver the stage renders, bit-exact per inputs.
    static func frameImages(_ inputs: PostcardInputs) -> [CGImage] {
        drives(inputs).compactMap { CompanionIcon.cgImage(for: $0) }
    }

    /// FNV-1a hashes of each frame's resolved POSE — the determinism pins
    /// (the parameter-set truth layer, doc §5.5).
    static func frameHashes(_ inputs: PostcardInputs) -> [UInt64] {
        drives(inputs).map { PuppetPoser.resolve($0).pose.hashValue64() }
    }

    /// The warm-greeting fallback (default companion, plain idle run).
    private static func plainDrives(seed: UInt64) -> [PuppetDrive] {
        guard let profile = try? PersonalityProfile.load(.ember) else { return [] }
        let director = SpriteDirector(profile: profile, seed: seed)
        director.playSequence([.happy])
        var out: [PuppetDrive] = []
        for _ in 0..<frameCount {
            out.append(director.puppetDrive(atTick: director.tick + 1))
        }
        return out
    }
}
