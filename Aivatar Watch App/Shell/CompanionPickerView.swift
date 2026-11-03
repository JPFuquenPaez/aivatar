import SwiftUI

/// Companion picker (v10): a visual, one-decision-per-screen carousel — the
/// watchOS pattern for choosing a character. Replaces the Phase B text-list
/// picker: on a 40-46 mm screen a choice must read at a glance, so each page
/// leads with the rendered animal icon (the real avatar, Render/CompanionIcon),
/// then the animal name and a one-line temperament (Tools/PIXEL_DESIGN.md v3;
/// likable pole per §5 — no companion reads as a negative trait).
///
/// Layout rules (watchOS HIG): native vertical page TabView — the same paging
/// gesture as stage -> settings, one companion per screen; text styles only
/// (Dynamic Type); one full-width, 44 pt+ choose button per page; tapping
/// chooses immediately (no Save step) with a haptic and a checkmark state.
/// VoiceOver reads each page's art as one labeled element and the button as
/// its own action. Used two ways: pushed from Settings (re-choosable) and as
/// the first-run onboarding sheet (choosing completes onboarding).
struct CompanionPickerView: View {
    /// Non-nil in first-run onboarding mode: choosing completes onboarding
    /// and the closure lets the parent dismiss the sheet (and continue to
    /// the naming ceremony). Nil when pushed from Settings.
    var onChosenOnboarding: (() -> Void)?

    @AppStorage(ArchetypeSelection.storageKey) private var selection: Archetype = .ember
    @AppStorage("companionPickerCompleted") private var pickerCompleted = false
    @State private var page = 0

    init(onChosenOnboarding: (() -> Void)? = nil) {
        self.onChosenOnboarding = onChosenOnboarding
    }

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(Archetype.allCases.enumerated()), id: \.offset) { index, archetype in
                page(archetype)
                    .tag(index)
            }
        }
        .tabViewStyle(.page)
        .navigationTitle("Companion")
        .onAppear {
            // Open on the current companion so the checkmark is visible.
            page = Archetype.allCases.firstIndex(of: selection) ?? 0
        }
    }

    private func page(_ archetype: Archetype) -> some View {
        let isSelected = archetype == selection
        return GeometryReader { geometry in
            VStack(spacing: 8) {
                Spacer(minLength: 4)
                VStack(spacing: 6) {
                    if let icon = CompanionIcon.image(for: archetype) {
                        icon
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: geometry.size.height * 0.42)
                    }
                    Text(archetype.animal.name)
                        .font(.headline)
                    Text(archetype.animal.temperament)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(archetype.fullName), \(archetype.animal.element). \(archetype.animal.temperament)\(isSelected ? ", your current companion" : "")")
                Spacer(minLength: 4)
                Button {
                    choose(archetype)
                } label: {
                    Label(
                        isSelected ? "Your companion" : "Choose the \(archetype.animalName)",
                        systemImage: isSelected ? "checkmark.circle.fill" : "circle"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(isSelected
                                     ? "\(archetype.animal.name) is your companion"
                                     : "Choose the \(archetype.animalName)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func choose(_ archetype: Archetype) {
        selection = archetype
        // Immediate confirmation: the archetype's own reaction haptic (§9
        // haptics as an output channel) — the choice answers back.
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
    NavigationStack { CompanionPickerView(onChosenOnboarding: {}) }
}
#endif
