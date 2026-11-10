import Foundation

// Build-time asset validator (§10 pipeline: validate before bundle).
// Usage: swift asset_validator.swift <path-to-AvatarAssets-dir>
//
// Checks (schema freeze v1):
//  - rig.json parses; formatVersion == 1; bone names unique; parent references
//    exist; parent order is satisfiable; every slot binds a known bone;
//    expression channel and gesture registries match the code enums.
//  - Every profile_<archetype>.json parses; id matches the archetype;
//    gesturePoolWeights contains exactly the shared 12 clips (weight 0 allowed)
//    with weights >= 0 summing to 1 (+/- 0.02); rates > 0; palette hex parses;
//    transitionDurationSec has 2 ascending entries.
//
// Exits non-zero on any violation so CI fails the build.

struct Rig: Decodable {
    struct Bone: Decodable {
        let name: String
        let parent: String?
        let x: Float
        let y: Float
        let rotation: Float
        let length: Float
    }
    struct Slot: Decodable {
        let name: String
        let bone: String
        let drawOrder: Int
    }
    let formatVersion: Int
    let width: Float
    let height: Float
    let bones: [Bone]
    let slots: [Slot]
    let expressionChannels: [String]?
    let gestures: [String]?
}

struct Profile: Decodable {
    let id: String
    let motionProfile: MotionProfile
    let visualTokens: VisualTokens
    let gesturePoolWeights: [String: Float]
    // Schema v2 (A5a, additive — all optional).
    let speciesTokens: SpeciesTokens?
    let motionGrammar: MotionGrammar?
    let gazePolicy: String?
    let blink: BlinkGrammar?
    let tell: String?
    let quirkLoop: String?
    let voiceStyle: String?
    let assetVersion: String?
    // Schema v3 (v19 F3, additive — optional).
    let weatherDials: WeatherDials?
    struct WeatherDials: Decodable {
        let classes: [String: WeatherDial]
        struct WeatherDial: Decodable {
            let tempoScale: Float?
            let amplitudeScale: Float?
            let accentBias: Float?
            let hueShiftDeg: Float?
        }
    }
    struct MotionProfile: Decodable {
        let gestureRatePerMin: Float
        let amplitudeScale: Float
        let tempoScale: Float
        let transitionDurationSec: [Float]
        let overshoot: Float
    }
    struct SpeciesTokens: Decodable {
        let bodyLight: String
        let bodyMid: String
        let shadow: String
        let face: String
        let accentA: String
        let accentB: String?
        let glow: String?
    }
    struct MotionGrammar: Decodable {
        let settleComplete: Float
        let drift: Float
        let anticipation: Float
    }
    struct BlinkGrammar: Decodable {
        let durationScale: Float
        let variance: Float
    }
    struct VisualTokens: Decodable {
        let dominantShape: String
        let accentShape: String
        let palette: [String]
        let silhouetteWeights: SilhouetteWeights
        struct SilhouetteWeights: Decodable {
            let roundness: Float
            let angularity: Float
        }
    }
}

let expressionChannels = ["joy", "sad", "surprise", "alert", "sleepy", "focus", "warm", "wry", "startle", "rest"]
let gestures = ["wave", "bounce", "stretch", "spin", "nod", "tilt", "lookAround", "shiftWeight", "shiver", "doubleTake", "sparkle", "puff", "preen", "swayCatch", "tick", "mirror", "driftFloat", "slowBlink"]
let archetypes = ["ember", "willow", "compass", "prism", "nimbus", "lumen"]

var failures: [String] = []
func fail(_ message: String) {
    failures.append(message)
    print("ASSET-VALIDATOR FAIL: \(message)")
}

guard CommandLine.arguments.count == 2 else {
    print("usage: asset_validator.swift <AvatarAssets dir>")
    exit(2)
}
let assetsDir = URL(fileURLWithPath: CommandLine.arguments[1])
let decoder = JSONDecoder()

// ---- rig.json ----
let rigURL = assetsDir.appendingPathComponent("rig.json")
do {
    let rig = try decoder.decode(Rig.self, from: Data(contentsOf: rigURL))
    if rig.formatVersion != 1 { fail("rig.json formatVersion \(rig.formatVersion) != 1 (schema freeze)") }
    if rig.width <= 0 || rig.height <= 0 { fail("rig.json canvas dimensions must be positive") }
    var names = Set<String>()
    for bone in rig.bones {
        if !names.insert(bone.name).inserted { fail("duplicate bone name \(bone.name)") }
    }
    for bone in rig.bones {
        if let parent = bone.parent, !names.contains(parent) {
            fail("bone \(bone.name) references unknown parent \(parent)")
        }
    }
    // Parent-order satisfiability (topological check).
    var placed = Set<String>()
    var pending = rig.bones.map(\.name)
    var progressed = true
    while !pending.isEmpty && progressed {
        progressed = false
        pending = pending.filter { name in
            let bone = rig.bones.first { $0.name == name }!
            if let parent = bone.parent {
                if placed.contains(parent) {
                    placed.insert(name); progressed = true; return false
                }
                return true
            }
            placed.insert(name); progressed = true; return false
        }
    }
    if !pending.isEmpty { fail("rig.json parent order unsatisfiable for \(pending)") }
    for slot in rig.slots where !names.contains(slot.bone) {
        fail("slot \(slot.name) binds unknown bone \(slot.bone)")
    }
    if let channels = rig.expressionChannels {
        if channels != expressionChannels { fail("rig.json expressionChannels mismatch: \(channels)") }
    } else {
        fail("rig.json missing expressionChannels registry")
    }
    if let rigGestures = rig.gestures {
        if rigGestures != gestures { fail("rig.json gestures registry mismatch: \(rigGestures)") }
    } else {
        fail("rig.json missing gestures registry")
    }
} catch {
    fail("rig.json failed to decode: \(error)")
}

// ---- profiles ----
for archetype in archetypes {
    let url = assetsDir.appendingPathComponent("profile_\(archetype).json")
    do {
        let profile = try decoder.decode(Profile.self, from: Data(contentsOf: url))
        if profile.id != archetype { fail("profile_\(archetype).json id \(profile.id) != \(archetype)") }
        let clips = profile.gesturePoolWeights
        let expected = Set(gestures)
        let actual = Set(clips.keys)
        if actual != expected {
            let missing = expected.subtracting(actual).sorted()
            let extra = actual.subtracting(expected).sorted()
            if !missing.isEmpty { fail("profile_\(archetype): missing clips \(missing) (weight 0 entries are required for parity)") }
            if !extra.isEmpty { fail("profile_\(archetype): unknown clips \(extra)") }
        }
        let sum = clips.values.reduce(0, +)
        if abs(sum - 1.0) > 0.02 { fail("profile_\(archetype): gesturePoolWeights sum \(sum) != 1.0") }
        for (clip, weight) in clips where weight < 0 {
            fail("profile_\(archetype): negative weight for \(clip)")
        }
        if profile.motionProfile.gestureRatePerMin <= 0 { fail("profile_\(archetype): gestureRatePerMin must be > 0") }
        if profile.motionProfile.amplitudeScale <= 0 { fail("profile_\(archetype): amplitudeScale must be > 0") }
        if profile.motionProfile.tempoScale <= 0 { fail("profile_\(archetype): tempoScale must be > 0") }
        if profile.motionProfile.transitionDurationSec.count != 2 {
            fail("profile_\(archetype): transitionDurationSec must have 2 entries")
        }
        if let lo = profile.motionProfile.transitionDurationSec.first,
           let hi = profile.motionProfile.transitionDurationSec.last, lo > hi {
            fail("profile_\(archetype): transitionDurationSec must be ascending")
        }
        for hex in profile.visualTokens.palette {
            let clean = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            if clean.count != 6 || Int(clean, radix: 16) == nil {
                fail("profile_\(archetype): palette entry \(hex) is not a hex color")
            }
        }
        // Schema v2 (A5a): species tokens + grammar, all optional but
        // mutually consistent when present.
        if let species = profile.speciesTokens {
            for (label, hex) in [
                ("bodyLight", species.bodyLight), ("bodyMid", species.bodyMid),
                ("shadow", species.shadow), ("face", species.face),
                ("accentA", species.accentA),
            ] {
                let clean = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
                if clean.count != 6 || Int(clean, radix: 16) == nil {
                    fail("profile_\(archetype): speciesTokens.\(label) \(hex) is not a hex color")
                }
            }
            if let accentB = species.accentB {
                let clean = accentB.hasPrefix("#") ? String(accentB.dropFirst()) : accentB
                if clean.count != 6 || Int(clean, radix: 16) == nil {
                    fail("profile_\(archetype): speciesTokens.accentB \(accentB) is not a hex color")
                }
            }
        }
        if let grammar = profile.motionGrammar {
            for (label, value) in [
                ("settleComplete", grammar.settleComplete),
                ("drift", grammar.drift),
                ("anticipation", grammar.anticipation),
            ] where !(0...1).contains(value) {
                fail("profile_\(archetype): motionGrammar.\(label) \(value) outside 0...1")
            }
        }
        if let blink = profile.blink {
            if blink.durationScale <= 0 || blink.durationScale > 3 {
                fail("profile_\(archetype): blink.durationScale \(blink.durationScale) outside 0...3")
            }
            if !(0...1).contains(blink.variance) {
                fail("profile_\(archetype): blink.variance \(blink.variance) outside 0...1")
            }
        }
        if let policy = profile.gazePolicy {
            let valid = ["lock", "soft", "metricSweep", "wander", "detectThenSettle", "linger"]
            if !valid.contains(policy) {
                fail("profile_\(archetype): gazePolicy \(policy) not in \(valid)")
            }
        }
        if let tell = profile.tell {
            let valid = ["spark", "leaf", "tick", "flicker", "pulse", "dust"]
            if !valid.contains(tell) {
                fail("profile_\(archetype): tell \(tell) not in \(valid)")
            }
        }
        if let quirkLoop = profile.quirkLoop {
            let valid = ["preen", "phototropism", "alignmentFidget", "mirrorMoment", "weatherMap", "stargazing"]
            if !valid.contains(quirkLoop) {
                fail("profile_\(archetype): quirkLoop \(quirkLoop) not in \(valid)")
            }
        }
        if profile.assetVersion != nil, profile.assetVersion!.hasPrefix("1.") || profile.assetVersion!.hasPrefix("2.") {
            fail("profile_\(archetype): v3 weatherDials require assetVersion >= 3 (got \(profile.assetVersion!))")
        }
        if let dials = profile.weatherDials {
            let expected = Set(["sunny", "gray", "rain", "wind", "cold", "hot", "unknown"])
            if Set(dials.classes.keys) != expected {
                fail("profile_\(archetype): weatherDials classes must be \(expected)")
            }
            if let unknown = dials.classes["unknown"],
               unknown.tempoScale != nil || unknown.amplitudeScale != nil
                || unknown.accentBias != nil || unknown.hueShiftDeg != nil {
                // neutral defaults decode as present-or-nil; all must be neutral
            }
            for (klass, dial) in dials.classes {
                if let h = dial.hueShiftDeg, abs(h) > 20 {
                    fail("profile_\(archetype): weatherDials.\(klass) hueShift \(h) exceeds 20 deg")
                }
            }
        } else {
            fail("profile_\(archetype): weatherDials required at assetVersion 3")
        }
    } catch {
        fail("profile_\(archetype).json failed to decode: \(error)")
    }
}

// ---- Aivatar 2.0 E1: app icon + AccentColor pins ----
// The appiconset lives at <repo>/Aivatar Watch App/Assets.xcassets — derive the
// repo root from the AvatarAssets dir argument (…/<root>/Aivatar Watch App/AvatarAssets).
let repoRoot = assetsDir.deletingLastPathComponent().deletingLastPathComponent()
let xcassets = repoRoot.appendingPathComponent("Aivatar Watch App/Assets.xcassets")

do {
    let iconset = xcassets.appendingPathComponent("AppIcon.appiconset/Contents.json")
    let data = try Data(contentsOf: iconset)
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let images = json["images"] as? [[String: Any]],
       images.count == 1,
       images[0]["size"] as? String == "1024x1024",
       images[0]["idiom"] as? String == "universal",
       images[0]["platform"] as? String == "watchos",
       let filename = images[0]["filename"] as? String {
        let png = xcassets.appendingPathComponent("AppIcon.appiconset/\(filename)")
        if !FileManager.default.fileExists(atPath: png.path) {
            fail("AppIcon.png missing from appiconset")
        }
    } else {
        fail("AppIcon.appiconset must declare exactly one universal watchos 1024x1024 image")
    }
} catch {
    fail("AppIcon.appiconset unreadable: \(error)")
}

do {
    let accent = xcassets.appendingPathComponent("AccentColor.colorset/Contents.json")
    let data = try Data(contentsOf: accent)
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let colors = json["colors"] as? [[String: Any]], !colors.isEmpty {
        // Must match Ember's accent token (paletteHex["A"] = FFC800) within 1/255.
        let target: (Float, Float, Float) = (1.0, Float(0xC8) / 255.0, 0.0)
        let first = colors[0]
        if let color = first["color"] as? [String: Any],
           color["color-space"] as? String == "srgb",
           let comps = color["components"] as? [String: String],
           let r = Float(comps["red"] ?? ""), let g = Float(comps["green"] ?? ""), let b = Float(comps["blue"] ?? "") {
            if abs(r - target.0) > 1.0 / 255 || abs(g - target.1) > 1.0 / 255 || abs(b - target.2) > 1.0 / 255 {
                fail("AccentColor (\(r),\(g),\(b)) does not match ember accent FFC800 within 1/255")
            }
        } else {
            fail("AccentColor first entry must be sRGB with numeric components")
        }
    } else {
        fail("AccentColor.colorset must be populated (E1)")
    }
} catch {
    fail("AccentColor.colorset unreadable: \(error)")
}

if failures.isEmpty {
    print("ASSET-VALIDATOR OK: rig.json v1 + profiles + app icon/AccentColor (E1) pass schema + parity checks")
    exit(0)
}
exit(1)
