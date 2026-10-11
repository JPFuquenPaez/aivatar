import Foundation

/// rig.json document schema (§6, v0 in A0, frozen at end of A1).
///
/// The rig is shared across all five archetypes: bones, slots and expression
/// channels are identical; only the texture atlas and palette tokens differ
/// per archetype.
nonisolated struct RigDocument: Codable, Sendable {
    nonisolated struct Bone: Codable, Sendable {
        var name: String
        var parent: String?
        /// Rest offset from the parent bone origin, points.
        var x: Float
        var y: Float
        /// Rest rotation, radians. 0 points up (-Y).
        var rotation: Float
        var length: Float
    }

    nonisolated struct Shape: Codable, Sendable {
        /// "rect" | "circle" | "capsule" | "triangle"
        var kind: String
        var width: Float
        var height: Float
        /// Mesh deformation (§6): number of slices the shape is cut into along
        /// the bone axis so bending parts can bend. Rigid parts use 1.
        var bendSegments: Int?
    }

    nonisolated struct Slot: Codable, Sendable {
        var name: String
        var bone: String
        /// Paint order, back to front.
        var drawOrder: Int
        var shape: Shape
        /// Palette token role, resolved by the archetype visual set.
        var paletteRole: String
    }

    var formatVersion: Int
    /// Logical authoring canvas, points (§4: silhouette readable at 205x251).
    var width: Float
    var height: Float
    var bones: [Bone]
    var slots: [Slot]

    static func load(bundle: Bundle = .main) throws -> RigDocument {
        let decoder = JSONDecoder()
        guard let url = bundle.url(forResource: "rig", withExtension: "json", subdirectory: "AvatarAssets")
            ?? bundle.url(forResource: "rig", withExtension: "json") else {
            throw RigError.missingResource("rig.json")
        }
        do {
            return try decoder.decode(RigDocument.self, from: Data(contentsOf: url))
        } catch {
            throw RigError.invalidJSON(error)
        }
    }
}

nonisolated enum RigError: Error, Sendable {
    case missingResource(String)
    case invalidJSON(any Error)
    case unknownBone(String)
    case parentOrderUnsatisfiable
}
