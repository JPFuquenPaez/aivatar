import SwiftUI

/// Settings (§9): one level down from the stage, List inside a
/// NavigationStack with pushed sections. Text styles only (Dynamic Type).
struct SettingsView: View {
    let archetype: Archetype

    /// Reduce Motion Level 2 (§8): the in-app user setting — static pose +
    /// gentle blink only. Strongest level wins over the system setting.
    @AppStorage("reduceMotionL2") private var reduceMotionL2 = false

    var body: some View {
        NavigationStack {
            List {
                Section("Companion") {
                    HStack {
                        Text("Archetype")
                        Spacer()
                        Text(archetype.displayName)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Current archetype: \(archetype.displayName)")
                }
                Section {
                    Toggle("Reduce Motion", isOn: $reduceMotionL2)
                        .accessibilityLabel("Reduce Motion, stronger than the system setting")
                        .accessibilityHint("Keeps your companion still with only a gentle blink")
                } header: {
                    Text("Accessibility")
                } footer: {
                    Text("Stops idle gestures and sway; your companion holds still and blinks.")
                        .font(.footnote)
                }
                Section("About") {
                    Text("Aivatar is procedural — no clip files, everything you see is generated live from a shared rig.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
