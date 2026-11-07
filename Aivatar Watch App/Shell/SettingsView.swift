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
    /// v14 sonic presence: the user's listening opt-out (the in-context
    /// permission ask is the real gate; this is the always-visible off
    /// switch).
    @AppStorage("listenForSounds") private var listenForSounds = true
    /// v17 F2 life sense: explicit opt-ins — with both off, the feature is
    /// fully dormant (no polling, no permission ask).
    @AppStorage("lifeSenseCalendar") private var lifeSenseCalendar = false
    @AppStorage("lifeSenseHealth") private var lifeSenseHealth = false
    /// v18 F3 weather: opt-in; current conditions fetched on visit, cached.
    @AppStorage("lifeSenseWeather") private var lifeSenseWeather = false
    @State private var showNaming = false
    /// v22 F8: the postcard preview sheet.
    @State private var showPostcard = false

    private var stageName: String {
        companionName.isEmpty ? archetype.displayName : companionName
    }

    /// v16 F1: "Ember · day 23 · old friends" — the About line. Bond is
    /// never a meter; at the confidant level the line says so in words.
    private var aboutLine: String {
        let memory = CompanionMemoryStore().load()
        let days = memory.map { CompanionMemoryStore.dayDistance(from: $0.firstLaunch, to: Date()) + 1 } ?? 1
        let confidant = memory.map { BondRules.isConfidant($0.bondLevel) } ?? false
        return "\(stageName) · day \(days)" + (confidant ? " · old friends" : "")
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
                // v14 sonic presence: the opt-out lives next to the
                // behavior it governs, with the privacy contract in the
                // footer — no hidden recording, no background listening.
                Section {
                    Toggle("Listen for sounds", isOn: $listenForSounds)
                        .accessibilityHint("Your companion reacts to your voice and claps while the app is open")
                } header: {
                    Text("Sounds")
                } footer: {
                    Text("While Aivatar is open with the stage awake, its microphone listens for your voice and claps so your companion can react. Sounds are analyzed on the watch instantly and never recorded or saved.")
                        .font(.footnote)
                }
                // v17 F2 life sense: the consent copy names exactly what is
                // read, where, and what is never kept (G5 written down).
                Section {
                    Toggle("Calendar", isOn: $lifeSenseCalendar)
                        .accessibilityHint("Your companion can notice when a calendar event is about to start")
                    Toggle("Workouts & sleep", isOn: $lifeSenseHealth)
                        .accessibilityHint("Your companion can celebrate your saved workouts and notice your sleep")
                    Toggle("Weather", isOn: $lifeSenseWeather)
                        .accessibilityHint("Your companion can notice the current weather where you are")
                } header: {
                    Text("Life sense")
                } footer: {
                    Text("While Aivatar is open, your companion can react to upcoming calendar events, to workouts and sleep saved in Health, and to the current weather at your location — read on this watch only, fetched at most once an hour. Event titles, health details, and weather are never stored beyond a hash, and nothing ever leaves the watch.")
                        .font(.footnote)
                }
                Section("About") {
                    // v16 F1: one gentle line — day count only, never levels
                    // or numbers of trust ("old friends" is the whole story).
                    Text(aboutLine)
                        .font(.footnote)
                    // v22 F8: the deterministic postcard of this companion.
                    Button {
                        showPostcard = true
                    } label: {
                        HStack {
                            Text("Postcard")
                            Spacer()
                            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHint("Preview a shareable card of your companion")
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
            // v22 F8: postcard preview.
            .sheet(isPresented: $showPostcard) {
                NavigationStack {
                    PostcardPreviewView(archetype: archetype)
                        .navigationTitle("Postcard")
                }
            }
        }
    }
}


