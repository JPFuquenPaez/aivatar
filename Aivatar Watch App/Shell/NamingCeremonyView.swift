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

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(archetype.displayName)
                    .font(.headline)
                Text("Give your companion a name. Named things are kept things.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                TextField("e.g. \(archetype.displayName)", text: $draft)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(commit)
                Button(action: commit) {
                    Text("Name them")
                        .frame(maxWidth: .infinity)
                }
                Button(role: .cancel) {
                    finish()
                } label: {
                    Text("Not now")
                        .frame(maxWidth: .infinity)
                }
                .tint(.secondary)
            }
            .padding(.horizontal, 4)
            .navigationTitle("Name")
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
