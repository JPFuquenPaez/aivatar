import SwiftUI

/// A5c naming ceremony (§10.5.1 — U6 Tamagotchi literature: named things
/// are owned things; personalization increases felt responsibility).
/// First-run sheet: the user names their companion, the companion
/// celebrates (sparkle + haptic), and the name replaces the archetype's
/// display name on the stage. Re-opened from Settings to rename.
struct NamingCeremonyView: View {
    let archetype: Archetype
    @Binding var isPresented: Bool
    @AppStorage("companionName") private var companionName = ""
    @AppStorage("namingCompleted") private var namingCompleted = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// Called when a name is committed so the stage can celebrate.
    var onName: ((String) -> Void)?

    private var accent: Color { SetupTheme.accent(for: archetype) }

    private var previewName: String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? archetype.displayName : trimmed
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Spacer(minLength: 2)
                // v27: the companion in its tinted disc, then a large live
                // preview of the name being given.
                SetupTheme.iconDisc(for: archetype, size: 64)
                Text(String(format: String(localized: "naming.title"), archetype.animalName))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(String(localized: "naming.subtitle"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("“\(previewName)”")
                    .font(.headline)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .accessibilityLabel(String(format: String(localized: "naming.preview"), previewName))
                // v27: the field sits in a soft card with a clear button.
                HStack(spacing: 6) {
                    TextField(String(format: String(localized: "naming.placeholder"), archetype.displayName),
                              text: $draft)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(commit)
                        .textFieldStyle(.plain)
                        .accessibilityLabel(String(localized: "naming.field"))
                    if !draft.isEmpty {
                        Button {
                            draft = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(String(localized: "naming.clear"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button(action: commit) {
                    Text(String(localized: "naming.commit"))
                }
                .buttonStyle(.setupProminent(tint: accent))
                .accessibilityHint(String(localized: "naming.commit_hint"))
                Button(role: .cancel) {
                    finish()
                } label: {
                    Text(String(localized: "naming.cancel"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
            }
            .padding(.horizontal, 4)
            .navigationTitle(String(localized: "naming.nav"))
            .onAppear { focused = true }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? archetype.displayName : trimmed
        companionName = name
        onName?(name)
        finish()
    }

    private func finish() {
        namingCompleted = true
        isPresented = false
    }
}

#if DEBUG
#Preview {
    NamingCeremonyView(archetype: .ember, isPresented: .constant(true))
}
#endif
