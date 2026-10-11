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
                    NavigationLink {
                        ArchetypePickerView()
                    } label: {
                        HStack {
                            Text("Personality")
                            Spacer()
                            Text(archetype.displayName)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Personality, currently \(archetype.displayName)")
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
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// Companion personality picker (§5 one avatar per personality, §9 pushed
/// settings section). Every archetype is presented at its likable pole —
/// no row reads as a negative trait. Rows are standard List buttons
/// (44 pt+ targets, VoiceOver-labeled, text styles only).
private struct ArchetypePickerView: View {
    @AppStorage(ArchetypeSelection.storageKey) private var selection: Archetype = .ember

    var body: some View {
        List {
            Section {
                ForEach(Archetype.allCases, id: \.self) { archetype in
                    Button {
                        selection = archetype
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(archetype.displayName)
                                Text(archetype.tagline)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if archetype == selection {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(archetype == selection ? .isSelected : [])
                }
            } footer: {
                Text("Your companion remembers your choice.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Personality")
    }
}
