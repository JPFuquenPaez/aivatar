import SwiftUI

/// Settings (§9): one level down from the stage, List inside a
/// NavigationStack with pushed sections. Text styles only (Dynamic Type).
struct SettingsView: View {
    let archetype: Archetype

    /// Reduce Motion Level 2 (§8): the in-app user setting — static pose +
    /// gentle blink only. Strongest level wins over the system setting.
    @AppStorage("reduceMotionL2") private var reduceMotionL2 = false

    /// A5c naming ceremony: rename access (§10.5.1).
    @AppStorage("companionName") private var companionName = ""
    @State private var showNaming = false

    private var stageName: String {
        companionName.isEmpty ? archetype.displayName : companionName
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Companion") {
                    Button {
                        showNaming = true
                    } label: {
                        HStack {
                            Text("Name")
                            Spacer()
                            Text(stageName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Name, currently \(stageName)")
                    NavigationLink {
                        CompanionPickerView()
                    } label: {
                        HStack {
                            Text("Companion")
                            Spacer()
                            Text(archetype.animal.name)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Companion, currently \(archetype.fullName)")
                    }
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
                    Text("Tip: touch and hold your companion to share a slow blink — its trust ritual.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showNaming) {
                NamingCeremonyView(archetype: archetype, isPresented: $showNaming, onName: nil)
            }
        }
    }
}


