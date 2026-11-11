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
            // v30: the whole list is tinted with the companion's accent, so
            // toggles, links and selection read as one brand, not system blue.
            List {
                // v30: an identity card leads Settings — tappable (opens the
                // rename), the companion in its glow-disc, its name, the one
                // gentle About line, and a chevron. Accent-tinted card, not a
                // bare clear row.
                Section {
                    Button {
                        showNaming = true
                    } label: {
                        // v32 audit: on 42 mm (187 pt wide) a 48 pt disc + name +
                        // chevron in one row left the text ~50 pt — the name
                        // truncated to "Will…". 40 pt disc, tighter metrics.
                        HStack(spacing: 10) {
                            SetupTheme.iconDisc(for: archetype, size: 40)
                            // v32 fix: the text column must take all remaining
                            // width (without the frame it was crushed to one
                            // character per line on small screens).
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stageName)
                                    .font(.headline)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Text(aboutLine)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(SetupTheme.accent(for: archetype).opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(format: String(localized: "a11y.identity_card"),
                                                stageName, archetype.fullName, aboutLine))
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
                                // v30: chevron like every other drill-in row.
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                                    .font(.caption2)
                            }
                        } icon: {
                            Image(systemName: "text.badge.star")
                                .foregroundStyle(SetupTheme.accent(for: archetype))
                        }
                    }
                    .accessibilityLabel(String(format: String(localized: "a11y.name_row"), stageName))
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
                        .accessibilityLabel(String(format: String(localized: "a11y.animal_row"), archetype.fullName))
                    }
                }
                Section {
                    Toggle(String(localized: "settings.reduce_motion"), isOn: $reduceMotionL2)
                        .accessibilityLabel(String(localized: "a11y.reduce_motion"))
                        .accessibilityHint(String(localized: "a11y.reduce_motion_hint"))
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
                        .accessibilityHint(String(localized: "a11y.sounds_hint"))
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
                        .accessibilityHint(String(localized: "a11y.calendar_hint"))
                        // v25 (audit M2): ask at the opt-in moment, not later.
                        .onChange(of: lifeSenseCalendar) { on in
                            if on { CalendarSenseBridge().requestAccessIfNeeded() }
                        }
                    Toggle(String(localized: "settings.health"), isOn: $lifeSenseHealth)
                        .accessibilityHint(String(localized: "a11y.health_hint"))
                        .onChange(of: lifeSenseHealth) { on in
                            if on { HealthSenseBridge().requestAccessIfNeeded() }
                        }
                    Toggle(String(localized: "settings.weather"), isOn: $lifeSenseWeather)
                        .accessibilityHint(String(localized: "a11y.weather_hint"))
                        .onChange(of: lifeSenseWeather) { on in
                            if on { WeatherSenseBridge().requestLocationAuthorizationIfNeeded() }
                        }
                } header: {
                    Text(String(localized: "settings.life_sense"))
                } footer: {
                    Text(String(localized: "settings.life_sense_footer"))
                        .font(.footnote)
                }
                // E8 "Sit together": the mindful minute, primary entry point.
                Section {
                    Button {
                        SitSession.shared.start()
                    } label: {
                        Label {
                            Text(String(format: String(localized: "sit.entry.title"),
                                        stageName))
                        } icon: {
                            Image(systemName: "lungs.fill")
                                .foregroundStyle(SetupTheme.accent(for: archetype))
                        }
                    }
                    .accessibilityHint(String(localized: "sit.entry.hint"))
                } footer: {
                    Text(String(localized: "sit.privacy.footer"))
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
                    .accessibilityHint(String(localized: "a11y.postcard_hint"))
                    Text(String(localized: "settings.about_copy"))
                        .font(.footnote)
                    Text(String(localized: "settings.tip"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "settings.nav"))
            // v30: the whole list takes the companion's accent as its tint —
            // toggles, links and selection read as one brand.
            .tint(SetupTheme.accent(for: archetype))
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


