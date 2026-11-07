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
    /// v25: localized (en/fr).
    private var aboutLine: String {
        let memory = CompanionMemoryStore().load()
        let days = memory.map { CompanionMemoryStore.dayDistance(from: $0.firstLaunch, to: Date()) + 1 } ?? 1
        let confidant = memory.map { BondRules.isConfidant($0.bondLevel) } ?? false
        let base = String(format: String(localized: "about.day"), stageName, days)
        return confidant ? base + " · " + String(localized: "postcard.old_friends") : base
    }

    var body: some View {
        NavigationStack {
            List {
                // v27: an identity card leads Settings — the companion in its
                // tinted disc, its name, and the one gentle About line.
                Section {
                    HStack(spacing: 10) {
                        SetupTheme.iconDisc(for: archetype, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stageName)
                                .font(.headline)
                            Text(aboutLine)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(stageName), \(archetype.fullName). \(aboutLine)")
                }
                Section(String(localized: "settings.companion")) {
                    Button {
                        showNaming = true
                    } label: {
                        Label {
                            HStack {
                                Text(String(localized: "settings.name"))
                                Spacer()
                                Text(stageName)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "text.badge.star")
                                .foregroundStyle(SetupTheme.accent(for: archetype))
                        }
                    }
                    .accessibilityLabel("Name, currently \(stageName)")
                    NavigationLink {
                        CompanionPickerView()
                    } label: {
                        Label {
                            HStack {
                                Text(String(localized: "settings.animal"))
                                Spacer()
                                Text(archetype.animal.name)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "pawprint.fill")
                                .foregroundStyle(SetupTheme.accent(for: archetype))
                        }
                        .accessibilityLabel("Companion, currently \(archetype.fullName)")
                    }
                }
                Section {
                    Toggle(String(localized: "settings.reduce_motion"), isOn: $reduceMotionL2)
                        .accessibilityLabel("Reduce Motion, stronger than the system setting")
                        .accessibilityHint("Keeps your companion still with only a gentle blink")
                } header: {
                    Text(String(localized: "settings.accessibility"))
                } footer: {
                    Text(String(localized: "settings.reduce_motion_footer"))
                        .font(.footnote)
                }
                // v14 sonic presence: the opt-out lives next to the
                // behavior it governs, with the privacy contract in the
                // footer — no hidden recording, no background listening.
                Section {
                    Toggle(String(localized: "settings.sounds"), isOn: $listenForSounds)
                        .accessibilityHint("Your companion reacts to your voice and claps while the app is open")
                } header: {
                    Text(String(localized: "settings.sounds_header"))
                } footer: {
                    Text(String(localized: "settings.sounds_footer"))
                        .font(.footnote)
                }
                // v17 F2 life sense: the consent copy names exactly what is
                // read, where, and what is never kept (G5 written down).
                Section {
                    Toggle(String(localized: "settings.calendar"), isOn: $lifeSenseCalendar)
                        .accessibilityHint("Your companion can notice when a calendar event is about to start")
                        // v25 (audit M2): ask at the opt-in moment, not later.
                        .onChange(of: lifeSenseCalendar) { on in
                            if on { CalendarSenseBridge().requestAccessIfNeeded() }
                        }
                    Toggle(String(localized: "settings.health"), isOn: $lifeSenseHealth)
                        .accessibilityHint("Your companion can celebrate your saved workouts and notice your sleep")
                        .onChange(of: lifeSenseHealth) { on in
                            if on { HealthSenseBridge().requestAccessIfNeeded() }
                        }
                    Toggle(String(localized: "settings.weather"), isOn: $lifeSenseWeather)
                        .accessibilityHint("Your companion can notice the current weather where you are")
                        .onChange(of: lifeSenseWeather) { on in
                            if on { WeatherSenseBridge().requestLocationAuthorizationIfNeeded() }
                        }
                } header: {
                    Text(String(localized: "settings.life_sense"))
                } footer: {
                    Text(String(localized: "settings.life_sense_footer"))
                        .font(.footnote)
                }
                Section(String(localized: "settings.about")) {
                    // v22 F8: the deterministic postcard of this companion.
                    Button {
                        showPostcard = true
                    } label: {
                        Label {
                            HStack {
                                Text(String(localized: "settings.postcard"))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                                    .font(.caption2)
                            }
                        } icon: {
                            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                                .foregroundStyle(SetupTheme.accent(for: archetype))
                        }
                    }
                    .accessibilityHint("Preview a shareable card of your companion")
                    Text(String(localized: "settings.about_copy"))
                        .font(.footnote)
                    Text(String(localized: "settings.tip"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "settings.nav"))
            // v29: a rename republishes the complication immediately (the
            // watch face carries the name) — the shared publisher, same path
            // as the stage, not a hand-rolled copy.
            .onChange(of: companionName) { _ in
                CompanionWidgetPublisher.publish(archetype: archetype, name: stageName)
            }
            .sheet(isPresented: $showNaming) {
                NamingCeremonyView(archetype: archetype, isPresented: $showNaming, onName: nil)
            }
            // v22 F8: postcard preview.
            .sheet(isPresented: $showPostcard) {
                NavigationStack {
                    PostcardPreviewView(archetype: archetype)
                        .navigationTitle(String(localized: "postcard.nav"))
                }
            }
        }
    }
}


