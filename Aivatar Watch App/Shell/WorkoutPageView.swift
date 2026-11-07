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
        VStack(spacing: 10) {
            if active {
                Text("Running with \(name)")
                    .font(.footnote)
                Text(Self.format(elapsed))
                    .font(.title3.monospacedDigit())
                    .accessibilityLabel("Elapsed time \(Self.format(elapsed))")
                Button {
                    onStop()
                } label: {
                    Label("End run", systemImage: "stop.fill")
                }
                .accessibilityHint("Ends the workout and saves it to Health")
            } else {
                Button {
                    onStart()
                } label: {
                    Label("Run with \(name)", systemImage: "figure.run")
                }
                .accessibilityHint("Starts a workout with your companion running beside you")
                Text("Your companion runs with you — splits cheer, no numbers here")
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
