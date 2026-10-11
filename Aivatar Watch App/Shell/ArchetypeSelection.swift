import Foundation

/// Companion archetype selection precedence (§9 settings one level down;
/// §10 CI reproducibility): launch argument > persisted user choice >
/// default. Pure value logic — unit-tested without UserDefaults; the UI
/// layers (@AppStorage) and the debug launch flag both feed into it.
nonisolated enum ArchetypeSelection {
    /// UserDefaults/@AppStorage key for the persisted companion choice.
    static let storageKey = "archetype"

    /// The `-archetype <name>` launch argument (smoke tests, CI, previews).
    static func fromLaunchArguments(_ args: [String]) -> Archetype? {
        guard let index = args.firstIndex(of: "-archetype"), index + 1 < args.count else {
            return nil
        }
        return Archetype(rawValue: args[index + 1])
    }

    /// Resolves the effective companion. Unknown stored values (corrupt
    /// defaults, schema renames) fall back to the default, never crash.
    static func resolve(launchOverride: Archetype?, storedRawValue: String?) -> Archetype {
        if let launchOverride {
            return launchOverride
        }
        if let raw = storedRawValue, let stored = Archetype(rawValue: raw) {
            return stored
        }
        return .ember
    }
}
