import Foundation

/// The companion snapshot shared between the watch app and the WidgetKit
/// complication (v12 presence pass). This folder (AivatarShared/) is the
/// ONE set of sources compiled into BOTH the watch app and the widget
/// extension targets, so the schema has exactly one definition. Pure
/// Foundation — no app-module imports.

/// What the widget renders: the current companion, its (user-owned) name,
/// and the streak artifact.
nonisolated struct CompanionWidgetSnapshot: Codable, Sendable, Equatable {
    /// Archetype rawValue ("ember" ... "nimbus") — keys the icon file.
    var archetypeRaw: String
    /// The companion's name (user-owned via the naming ceremony, else the
    /// archetype codename).
    var name: String
    /// Consecutive attended days (Compass's streak artifact).
    var streakDays: Int

    static func `default`(
        archetypeRaw: String = "ember", name: String = "Ember", streakDays: Int = 1
    ) -> CompanionWidgetSnapshot {
        CompanionWidgetSnapshot(archetypeRaw: archetypeRaw, name: name, streakDays: streakDays)
    }
}

nonisolated enum CompanionWidgetState {
    /// Shared app-group id — declared in BOTH targets' entitlements.
    static let appGroupID = "group.aivatarapp.Aivatar"
    static let snapshotKey = "companionWidgetSnapshot"
    /// Icons live in the shared container: the app renders them once per
    /// archetype from the real pixel rasterizer (Render/CompanionIcon).
    static let iconsDirectoryName = "Icons"

    static func sharedContainer() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static func iconURL(
        forArchetypeRaw raw: String,
        container: URL? = nil
    ) -> URL? {
        (container ?? sharedContainer())?
            .appendingPathComponent(iconsDirectoryName)
            .appendingPathComponent("\(raw).png")
    }

    /// Reads the snapshot; nil = the app has not published yet (first
    /// install, widget added before first launch) — the widget falls back
    /// to the default snapshot.
    static func readSnapshot(
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)
    ) -> CompanionWidgetSnapshot? {
        guard let defaults, let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(CompanionWidgetSnapshot.self, from: data)
    }

    /// Writes the snapshot. Pure (defaults injectable) for test isolation.
    static func write(
        _ snapshot: CompanionWidgetSnapshot,
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)
    ) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }
}
