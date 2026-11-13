import WidgetKit

/// CompanionWidgetPublisher (v29): the single writer of the watch-face
/// snapshot. Every shell surface that changes what the complication should
/// say (stage visit/wake, rename, archetype switch, life event)
/// calls `publish` — the widget itself never polls; WidgetKit is told to
/// reload. Extracted from AvatarStageView so Settings (rename) shares the
/// exact same path instead of a hand-rolled copy.
nonisolated enum CompanionWidgetPublisher {
    /// v12 presence pass + v18 F4 state model: write the companion snapshot
    /// (identity + presence state + derived one-line copy + the timestamps
    /// the widget timeline derives its schedule from) to the shared app
    /// group, seed the icon PNGs, and ask WidgetKit to redraw.
    static func publish(archetype: Archetype, name: String) {
        let memory = CompanionMemoryStore().load()
        let now = Date()
        let lastEvent = memory?.lifeLog.last
        let lastEventKind = lastEvent.flatMap { LifeKind.kind(forHash: $0.kindHash) }
        let dayCount = memory.map { CompanionMemoryStore.dayDistance(from: $0.firstLaunch, to: now) + 1 } ?? 1
        let presence = CompanionStateDerivation.presence(
            now: now, lastSeen: memory?.lastSeen, lastEventAt: lastEvent?.at)
        let snapshot = CompanionWidgetSnapshot(
            archetypeRaw: archetype.rawValue,
            name: name,
            streakDays: memory?.streakDays ?? 1,
            presence: presence,
            line: CompanionStateDerivation.line(for: presence, lastEventKind: lastEventKind),
            dayCount: dayCount,
            animalName: archetype.animalName,
            lastSeen: memory?.lastSeen,
            lastEventAt: lastEvent?.at,
            lastEventKindRaw: lastEventKind?.rawValue
        )
        // The snapshot write is always cheap and local — it keeps lastSeen
        // fresh for the widget's own hourly presence derivation.
        CompanionWidgetState.write(snapshot)
        seedIcons()
        // watchOS budget guidance: reloads are budget-limited, so ask only
        // when what the widget SHOWS actually changed (or the 10-minute
        // visit bucket moved — the awake window must not go stale on the
        // face). Redundant publishes (settings toggles, re-renders) skip
        // the reload entirely; the timeline policy covers time-based
        // reverts on its own.
        let signature = "\(archetype.rawValue)|\(name)|\(presence.rawValue)|\(lastEventKind?.rawValue ?? "-")|\(dayCount)|\(Int((memory?.lastSeen.timeIntervalSince1970 ?? 0) / 600))"
        let defaults = UserDefaults(suiteName: CompanionWidgetState.appGroupID)
        let lastSignature = defaults?.string(forKey: Self.widgetSignatureKey)
        if signature != lastSignature {
            defaults?.set(signature, forKey: Self.widgetSignatureKey)
            WidgetCenter.shared.reloadTimelines(ofKind: "AivatarCompanion")
        }
    }

    /// App-group key for the last widget-visible signature (see publish).
    private static let widgetSignatureKey = "widgetLastSignature"

    /// Renders every archetype's icon into the shared container (plain icon
    /// plus one PNG per presence state). Files are only written when missing
    /// — the directory name is versioned (`Icons-vN`) so a rendering-rule
    /// change re-seeds every icon atomically on both targets.
    private static func seedIcons() {
        guard let container = CompanionWidgetState.sharedContainer() else { return }
        let icons = container.appendingPathComponent(CompanionWidgetState.iconsDirectoryName)
        try? FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        for archetype in Archetype.allCases {
            if let url = CompanionWidgetState.iconURL(forArchetypeRaw: archetype.rawValue, container: container),
               !FileManager.default.fileExists(atPath: url.path),
               let png = CompanionIcon.pngData(for: archetype) {
                try? png.write(to: url)
            }
            for state: IconState in [.asleep, .awake, .event] {
                let presence = CompanionPresence(rawValue: state.rawValue) ?? .awake
                guard let url = CompanionWidgetState.iconURL(
                        forArchetypeRaw: archetype.rawValue, presence: presence, container: container),
                      !FileManager.default.fileExists(atPath: url.path),
                      let png = CompanionIcon.pngData(for: archetype, state: state) else { continue }
                try? png.write(to: url)
            }
        }
    }
}
