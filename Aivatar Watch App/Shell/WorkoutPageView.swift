import SwiftUI

/// WorkoutPageView (v21, F6): the crown-scroll page that starts Aivatar's
/// OWN workout session ("Run with Ember") — one row, one tap, platform
/// chrome. During the run the stage shows the companion (run grammar) plus
/// a minimal elapsed-time corner; this page shows the honest controls.
/// No metrics dashboard: the numbers live in Fitness afterwards — Aivatar
/// shows presence, not data.
struct WorkoutPageView: View {
    let archetype: Archetype
    let active: Bool
    let elapsed: TimeInterval
    let onStart: () -> Void
    let onStop: () -> Void

    private var name: String {
        UserDefaults.standard.string(forKey: "companionName").flatMap { $0.isEmpty ? nil : $0 }
            ?? archetype.displayName
    }

    var body: some View {
        let accent = SetupTheme.accent(for: archetype)
        VStack(spacing: 12) {
            if active {
                SetupTheme.iconDisc(for: archetype, size: 56)
                Text(String(format: String(localized: "workout.running_with"), name))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(Self.format(elapsed))
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 14)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel(String(format: String(localized: "workout.elapsed"), Self.format(elapsed)))
                Button {
                    onStop()
                } label: {
                    Label(String(localized: "workout.end_run"), systemImage: "stop.fill")
                }
                .buttonStyle(.setupProminent(tint: .red))
                .accessibilityHint("Ends the workout and saves it to Health")
            } else {
                SetupTheme.iconDisc(for: archetype, size: 72)
                Text(String(format: String(localized: "workout.run_with"), name))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Button {
                    onStart()
                } label: {
                    Label(String(localized: "workout.start"), systemImage: "figure.run")
                }
                .buttonStyle(.setupProminent(tint: accent))
                .accessibilityHint("Starts a workout with your companion running beside you")
                Text(String(localized: "workout.sub"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 12)
    }

    /// mm:ss (system monospaced digits — the one number Aivatar shows).
    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

#if DEBUG
#Preview { WorkoutPageView(archetype: .ember, active: false, elapsed: 0, onStart: {}, onStop: {}) }
#Preview { WorkoutPageView(archetype: .willow, active: true, elapsed: 754, onStart: {}, onStop: {}) }
#endif
