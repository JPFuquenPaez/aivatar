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
    struct MotionProfile: Decodable {
        let gestureRatePerMin: Float
        let amplitudeScale: Float
        let tempoScale: Float
        let transitionDurationSec: [Float]
        let overshoot: Float
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
let gestures = ["wave", "bounce", "stretch", "spin", "nod", "tilt", "lookAround", "shiftWeight", "shiver", "doubleTake", "sparkle", "puff"]
let archetypes = ["ember", "willow", "compass", "prism", "nimbus"]

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
    } catch {
        fail("profile_\(archetype).json failed to decode: \(error)")
    }
}

if failures.isEmpty {
    print("ASSET-VALIDATOR OK: rig.json v1 + 5 profiles pass schema + parity checks")
    exit(0)
}
exit(1)
