import WidgetKit
import SwiftUI

/// Aivatar widget extension (v12 presence pass, v18 F4 state model): the
/// watch-face complication — the surface where, per the watchOS HIG, people
/// actually experience a watch app between launches. State comes from the
/// shared app-group snapshot (AivatarShared, compiled into both targets);
/// the app reloads the timeline on its own state changes, so the widget
/// never polls.
///
/// F4: three presence states (asleep/awake/event), never animated — the
/// state change across the day IS the animation. The timeline encodes the
/// schedule (hourly anchors, hard cap 12 entries, G9) and each entry carries
/// the presence AT ITS DATE, derived purely from the snapshot timestamps, so
/// the face reverts to asleep on its own. The circular/corner families show
/// the REAL rendered pixel companion per state (asleep = rest-dim icon);
/// inline/rectangular carry the state in words (text-first accessibility).

struct CompanionEntry: TimelineEntry {
    let date: Date
    let snapshot: CompanionWidgetSnapshot
    /// The presence at THIS entry's date (derived, not stored per entry).
    let presence: CompanionPresence
    /// v29: the icon PNGs are read ONCE per entry, here in the provider —
    /// never per view render, so every timeline refresh stays cheap in the
    /// widget process (memory budget on the smallest watch).
    let iconData: Data?
    let plainIconData: Data?
    /// v31: Smart Stack relevance (watchOS 26), derived purely from presence
    /// + event kind (CompanionStateDerivation.relevanceScore — unit-tested).
    let relevance: TimelineEntryRelevance?
}

struct CompanionProvider: TimelineProvider {
    func placeholder(in context: Context) -> CompanionEntry {
        let snapshot = CompanionWidgetState.readSnapshot() ?? .default()
        return CompanionEntry(date: .now, snapshot: snapshot, presence: snapshot.presence,
                              iconData: iconData(for: snapshot.archetypeRaw, presence: snapshot.presence),
                              plainIconData: plainIconData(for: snapshot.archetypeRaw),
                              relevance: Self.relevance(for: snapshot.presence, snapshot: snapshot))
    }

    func getSnapshot(in context: Context, completion: @escaping (CompanionEntry) -> Void) {
        completion(entry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CompanionEntry>) -> Void) {
        // v18 F4: hourly anchors capped at 12 entries (G9); each entry's
        // presence is derived from the snapshot's timestamps, so awake/event
        // expire on their own (30 min / 1 h windows). Rare safety-net policy
        // only — the app reloads on its own state changes.
        let now = Date()
        let snapshot = current()
        let dates = CompanionStateDerivation.timelineDates(
            now: now, lastSeen: snapshot.lastSeen, lastEventAt: snapshot.lastEventAt)
        let entries = dates.map { entry(at: $0, snapshot: snapshot, now: now) }
        let last = dates.last ?? now
        completion(Timeline(entries: entries, policy: .after(last.addingTimeInterval(3_600))))
    }

    private func current() -> CompanionWidgetSnapshot {
        CompanionWidgetState.readSnapshot() ?? .default()
    }

    private func entry(at date: Date, snapshot: CompanionWidgetSnapshot? = nil, now: Date? = nil) -> CompanionEntry {
        let snapshot = snapshot ?? current()
        let now = now ?? Date()
        let presence = CompanionStateDerivation.presence(
            now: date, lastSeen: snapshot.lastSeen, lastEventAt: snapshot.lastEventAt)
        return CompanionEntry(date: date, snapshot: snapshot, presence: presence,
                              iconData: iconData(for: snapshot.archetypeRaw, presence: presence),
                              plainIconData: plainIconData(for: snapshot.archetypeRaw),
                              relevance: Self.relevance(for: presence, snapshot: snapshot))
    }

    /// v31: relevance from the entry's presence + the snapshot's last event.
    private static func relevance(for presence: CompanionPresence,
                                  snapshot: CompanionWidgetSnapshot) -> TimelineEntryRelevance? {
        let kind = snapshot.lastEventKindRaw.flatMap { LifeKind(rawValue: $0) }
        return TimelineEntryRelevance(score: Float(CompanionStateDerivation.relevanceScore(
            presence: presence, lastEventKind: kind)))
    }

    /// v29: one small file read per entry — the per-state icon PNG the app
    /// wrote into the shared container.
    private func iconData(for archetypeRaw: String, presence: CompanionPresence) -> Data? {
        guard let url = CompanionWidgetState.iconURL(forArchetypeRaw: archetypeRaw, presence: presence) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func plainIconData(for archetypeRaw: String) -> Data? {
        guard let url = CompanionWidgetState.iconURL(forArchetypeRaw: archetypeRaw) else { return nil }
        return try? Data(contentsOf: url)
    }
}

struct CompanionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CompanionEntry

    private var snapshot: CompanionWidgetSnapshot { entry.snapshot }
    private var kind: LifeKind? {
        snapshot.lastEventKindRaw.flatMap { LifeKind(rawValue: $0) }
    }
    /// The state line for this entry's date ("napping", "celebrated your
    /// workout") — words, not pixels, carry the state for VoiceOver.
    private var stateLine: String {
        CompanionStateDerivation.line(for: entry.presence, lastEventKind: kind)
    }

    /// The companion's real pixel icon for THIS state — the entry carries
    /// the PNG bytes (read once in the provider, v29); falls back to the
    /// plain icon, then a pawprint before the first app launch.
    @ViewBuilder
    private var icon: some View {
        if let data = entry.iconData, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else if let data = entry.plainIconData, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Image(systemName: "pawprint.fill")
        }
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                // Inline: name + the state in words.
                Text(CompanionStateDerivation.inlineLine(
                    name: snapshot.name, presence: entry.presence, lastEventKind: kind))
            case .accessoryRectangular:
                // Rectangular: icon + identity + day + state line.
                HStack(spacing: 6) {
                    icon
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        // v30: the identity line is localized (was a hardcoded
                        // English "the" + the English stored animalName) —
                        // resolved from the archetype raw value so the widget
                        // bundle's own strings table supplies the words.
                        Text(String(format: String(localized: "identity.full"),
                                    snapshot.name, LocalizedAnimalCopy.animalName(
                                        CompanionStateDerivation.sanitizedArchetypeRaw(snapshot.archetypeRaw))))
                            .font(.footnote)
                            .lineLimit(1)
                        Text(CompanionStateDerivation.rectangularLine(
                            dayCount: snapshot.dayCount, presence: entry.presence, lastEventKind: kind))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            case .accessoryCorner:
                icon
                    .widgetLabel(stateLine)
            default:
                // accessoryCircular: the companion itself, nothing else.
                icon
            }
        }
        .accessibilityLabel(String(format: String(localized: "widget.a11y"), snapshot.name, stateLine))
        .containerBackground(for: .widget) { Color.black }
    }
}

struct CompanionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AivatarCompanion", provider: CompanionProvider()) { entry in
            CompanionWidgetView(entry: entry)
        }
        // v29: widget chrome copy is localized in the extension's own bundle.
        .configurationDisplayName(String(localized: "widget.name"))
        .description(String(localized: "widget.description"))
        .supportedFamilies([
            .accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular,
        ])
    }
}

@main
struct AivatarWidgets: WidgetBundle {
    var body: some Widget {
        CompanionWidget()
    }
}
