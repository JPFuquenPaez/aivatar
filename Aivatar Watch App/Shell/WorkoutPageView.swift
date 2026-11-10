import SwiftUI

/// WorkoutPageView (v21 F6, v30 layout): the crown-scroll page that starts
/// Aivatar's OWN workout session ("Run with Ember") — platform chrome, one
/// decision. During the run the stage shows the companion (run grammar) plus
/// a minimal elapsed-time corner; this page shows the honest controls.
/// No metrics dashboard: the numbers live in Fitness afterwards — Aivatar
/// shows presence, not data.
/// v30: the column is vertically centered (v27 left a dead zone at the
/// bottom of a 242 pt screen), the hero is the glow-disc, the elapsed chip
/// is accent-tinted, and the name reads through @AppStorage like every
/// other surface.
struct WorkoutPageView: View {
    let archetype: Archetype
    let active: Bool
    let elapsed: TimeInterval
    /// v31: set when a start failed (Health access off) — shown inline.
    let error: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    @AppStorage("companionName") private var companionName = ""

    private var name: String {
        companionName.isEmpty ? archetype.displayName : companionName
    }

    var body: some View {
        let accent = SetupTheme.accent(for: archetype)
        GeometryReader { geometry in
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                if active {
                    SetupTheme.iconDisc(for: archetype, size: 48)
                    Text(String(format: String(localized: "workout.running_with"), name))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(Self.format(elapsed))
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(accent.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        // v31: VoiceOver reads whole minutes, not a label that
                        // churns every 10 s.
                        .accessibilityLabel(String(format: String(localized: "workout.elapsed"),
                                                    Self.format(Double(Int(elapsed / 60) * 60))))
                    Spacer(minLength: 0)
                    Button {
                        onStop()
                    } label: {
                        Label(String(localized: "workout.end_run"), systemImage: "stop.fill")
                    }
                    .buttonStyle(.setupProminent(accentHex: "FF3B30"))
                    .accessibilityHint(String(localized: "workout.end_hint"))
                } else {
                    SetupTheme.iconDisc(for: archetype, size: 72)
                    Text(String(format: String(localized: "workout.run_with"), name))
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Button {
                        onStart()
                    } label: {
                        Label(String(localized: "workout.start"), systemImage: "figure.run")
                    }
                    .buttonStyle(.setupProminent(accentHex: SetupTheme.accentHex(for: archetype)))
                    .accessibilityHint(String(localized: "workout.start_hint"))
                    if error {
                        // v31: honest failure — Health access is off.
                        Text(String(localized: "workout.error"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Text(String(localized: "workout.sub"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8 + geometry.safeAreaInsets.bottom)
        }
    }

    /// mm:ss (system monospaced digits — the one number Aivatar shows).
    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

#if DEBUG
#Preview { WorkoutPageView(archetype: .ember, active: false, elapsed: 0, error: false, onStart: {}, onStop: {}) }
#Preview { WorkoutPageView(archetype: .willow, active: true, elapsed: 754, error: false, onStart: {}, onStop: {}) }
#Preview { WorkoutPageView(archetype: .compass, active: false, elapsed: 0, error: true, onStart: {}, onStop: {}) }
#endif
