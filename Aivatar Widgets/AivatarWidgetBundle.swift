import WidgetKit
import SwiftUI

/// Aivatar widget extension (v12 presence pass): the watch-face
/// complication — the surface where, per the watchOS HIG, people actually
/// experience a watch app between launches. State comes from the shared
/// app-group snapshot (AivatarShared/CompanionWidgetState.swift, compiled
/// into both targets); the app redraws the timeline on every context
/// build, companion switch and rename, so the widget never polls.
///
/// Design per complication-family guidance: the circular/corner families
/// show the REAL rendered pixel companion (the icon PNG the app writes
/// from the rasterizer — never a stock symbol); inline carries the name
/// and the streak; content is monochrome-adaptable and glanceable at the
/// face's size/temperature settings.

struct CompanionEntry: TimelineEntry {
    let date: Date
    let snapshot: CompanionWidgetSnapshot
}

struct CompanionProvider: TimelineProvider {
    func placeholder(in context: Context) -> CompanionEntry {
        CompanionEntry(date: .now, snapshot: CompanionWidgetState.readSnapshot() ?? .default())
    }

    func getSnapshot(in context: Context, completion: @escaping (CompanionEntry) -> Void) {
        completion(CompanionEntry(date: .now, snapshot: current()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CompanionEntry>) -> Void) {
        // Rare safety-net refresh only: streaks roll at midnight and the
        // app reloads the timeline on its own state changes (power
        // discipline — complications must not poll).
        completion(Timeline(entries: [CompanionEntry(date: .now, snapshot: current())],
                            policy: .after(.now + 4 * 3600)))
    }

    private func current() -> CompanionWidgetSnapshot {
        CompanionWidgetState.readSnapshot() ?? .default()
    }
}

struct CompanionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CompanionEntry

    /// The companion's real pixel icon, written by the app into the shared
    /// container; falls back to a pawprint before the first app launch.
    @ViewBuilder
    private var icon: some View {
        let url = CompanionWidgetState.iconURL(forArchetypeRaw: entry.snapshot.archetypeRaw)
        if let url, let data = try? Data(contentsOf: url),
           let ui = UIImage(data: data) {
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
                // Inline: the widest glance — name + the streak beat.
                Text(entry.snapshot.streakDays > 1
                     ? "\(entry.snapshot.name) · \(entry.snapshot.streakDays)-day streak"
                     : entry.snapshot.name)
            case .accessoryCorner:
                icon
                    .widgetLabel(entry.snapshot.name)
            default:
                // accessoryCircular: the companion itself, nothing else.
                icon
            }
        }
        .containerBackground(for: .widget) { Color.black }
    }
}

struct CompanionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AivatarCompanion", provider: CompanionProvider()) { entry in
            CompanionWidgetView(entry: entry)
        }
        .configurationDisplayName("Your companion")
        .description("Your companion, present on the watch face.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

@main
struct AivatarWidgets: WidgetBundle {
    var body: some Widget {
        CompanionWidget()
    }
}
