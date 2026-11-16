import SwiftUI

/// Companion picker (v30): a visual, one-decision-per-screen carousel — the
/// watchOS onboarding idiom for choosing a character. The horizontal `.page`
/// TabView is deliberate: the app STRUCTURE pages vertically (`.verticalPage`
/// — stage / settings), a choice carousel swipes horizontally.
/// Each page leads with the rendered animal as a glow-disc hero (the real
/// avatar, Render/CompanionIcon, pixel-crisp), then the animal name, the
/// element tag, a one-line temperament, and a full-width 44 pt choose button
/// pinned to the bottom. Tapping chooses immediately (no Save step) with a
/// haptic, a selection bloom on the disc, and a selected state that reads
/// selected (accent variant + check), never disabled.
/// VoiceOver reads each page's art+text as one labeled element and the button
/// as its own action. Used two ways: pushed from Settings (re-choosable) and
/// as the one-time post-first-interaction onboarding sheet (the first frame
/// is the living stage; the ceremony follows the first tap, it never gates
/// the stage). In onboarding mode a quiet "Not now" skips the picker.
struct CompanionPickerView: View {
    /// Non-nil in first-run onboarding mode: choosing completes onboarding
    /// and the closure lets the parent dismiss the sheet (and continue to
    /// the naming ceremony). Nil when pushed from Settings.
    var onChosenOnboarding: (() -> Void)?
    /// v30: onboarding-only skip — dismisses without choosing; the parent
    /// routes on as after a plain dismiss.
    var onSkip: (() -> Void)?

    @AppStorage(ArchetypeSelection.storageKey) private var selection: Archetype = .ember
    @AppStorage("companionPickerCompleted") private var pickerCompleted = false
    @State private var page = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// E10: the sixth companion (lumen) appears in the picker only once the
    /// reveal has fired (confidant bond + sixthRevealed memory flag).
    private var shownArchetypes: [Archetype] {
        let memory = CompanionMemoryStore().load()
        if let memory, BondRules.sixthCompanionUnlocked(memory.bondLevel), memory.sixthRevealed {
            return Archetype.allCases
        }
        return Archetype.allCases.filter { $0 != .lumen }
    }

    init(onChosenOnboarding: (() -> Void)? = nil, onSkip: (() -> Void)? = nil) {
        self.onChosenOnboarding = onChosenOnboarding
        self.onSkip = onSkip
    }

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(shownArchetypes.enumerated()), id: \.offset) { index, archetype in
                page(archetype)
                    .tag(index)
            }
        }
        .tabViewStyle(.page)
        // E2: one .click per swipe, through the global haptic limiter
        // (fast swiping naturally throttles at the >= 1.5 s spacing).
        .onChange(of: page) { _ in
            HapticsChannel.shared.pageTick()
        }
        // v32 polish: no nav title — on 42 mm the centered title clips at
        // the right edge next to the "Not now" item; the page's own animal
        // name is the headline.
        .toolbar {
            // v30: onboarding must be skippable (HIG) — a quiet text button,
            // no dedicated key (reuses the ceremony's "Not now").
            if let onSkip {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "naming.cancel")) { onSkip() }
                }
            }
        }
        .onAppear {
            // Open on the current companion so the checkmark is visible.
            page = shownArchetypes.firstIndex(of: selection) ?? 0
            // v31 debug/CI hook: -pickerPage N forces page N (captures).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-pickerPage"), i + 1 < args.count,
               let n = Int(args[i + 1]), shownArchetypes.indices.contains(n) {
                page = n
            }
        }
    }

    private func page(_ archetype: Archetype) -> some View {
        let isSelected = archetype == selection
        let accent = SetupTheme.accent(for: archetype)
        return GeometryReader { geometry in
            // v30/v31 layout: hero -> name -> element -> temperament -> button
            // pinned to the bottom (safe-area aware). v32 fit fix: the hero
            // clamps harder on short screens (42mm = 198 pt) and the
            // temperament drops a line, so the choose button is ALWAYS on
            // screen (a TabView page cannot scroll).
            let compact = geometry.size.height < 215
            // v32 polish: the living hero is the page's heart — give it a
            // little more of the screen (was 0.22/56 compact, 0.30/88).
            let hero = dynamicTypeSize.isAccessibilitySize
                ? min(geometry.size.height * 0.20, 56)
                : min(geometry.size.height * (compact ? 0.26 : 0.34), compact ? 64 : 96)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                // AMS v2 (v43) "Meet them": the hero is the HD PORTRAIT in
                // the glow-disc chrome — identity art while choosing ("a
                // photo of your companion"); the living companion is the
                // authored grid on the stage you get after choosing. AX
                // type sizes clamp it to the small disc.
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        SetupTheme.iconDisc(for: archetype, selected: isSelected, size: hero)
                    } else {
                        SetupTheme.portraitDisc(for: archetype, selected: isSelected, size: hero)
                    }
                }
                .padding(.bottom, compact ? 8 : 14)
                VStack(spacing: 4) {
                    Text(archetype.animal.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(archetype.animal.element)
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1.5)
                        .foregroundStyle(accent)
                    Text(archetype.animal.temperament)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(compact ? 1 : 2)
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(archetype.fullName), \(archetype.animal.element). \(archetype.animal.temperament)\(isSelected ? String(localized: "a11y.picker_selected") : "")")
                Spacer(minLength: 0)
                Button {
                    choose(archetype)
                } label: {
                    Label(
                        isSelected
                            ? String(localized: "picker.current")
                            : String(format: String(localized: "picker.choose"), archetype.animalName),
                        systemImage: isSelected ? "checkmark.circle.fill" : "circle"
                    )
                }
                .buttonStyle(.setupProminent(accentHex: SetupTheme.accentHex(for: archetype),
                                             selected: isSelected))
                .accessibilityLabel(isSelected
                                     ? String(format: String(localized: "a11y.picker_button_selected"), archetype.animal.name)
                                     : String(format: String(localized: "picker.choose"), archetype.animalName))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .padding(.bottom, 6 + geometry.safeAreaInsets.bottom)
            }
            .padding(.horizontal, 12)
        }
    }

    private func choose(_ archetype: Archetype) {
        selection = archetype
        // Immediate confirmation: the archetype's own reaction haptic — the
        // choice answers back.
        HapticsChannel.shared.react(to: archetype)
        if onChosenOnboarding != nil {
            pickerCompleted = true
            onChosenOnboarding?()
        }
    }
}

#if DEBUG
#Preview("Picker") {
    NavigationStack { CompanionPickerView() }
}
#Preview("Picker onboarding") {
    NavigationStack { CompanionPickerView(onChosenOnboarding: {}, onSkip: {}) }
}
#endif
