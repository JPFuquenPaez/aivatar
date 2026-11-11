import SwiftUI

/// A5c naming ceremony (named things are owned things; personalization
/// increases felt responsibility). First-run sheet: the user names their
/// companion, the companion celebrates (sparkle + haptic), and the name
/// replaces the archetype's display name on the stage. Re-opened from
/// Settings to rename (the field is then prefilled with the current name).
///
/// v30 layout (setup-surface audit): glow-disc hero, oversized accent name
/// preview as the emotional center, the field in an accent-tinted card with
/// a 44 pt clear button, a full-width 44 pt commit, and a quiet 44 pt-hit
/// cancel — all inside a ScrollView so large Dynamic Type never clips, with
/// the bottom content above the safe area.
/// PerkThrottle (E3): pure, tick-injectable throttle for the naming perk —
/// one perk per >= 20-tick (3 s) window while the field is focused.
nonisolated struct PerkThrottle: Sendable {
    static let windowTicks = 20
    private var lastPerkTick = -1_000_000
    mutating func allow(tick: Int) -> Bool {
        guard tick - lastPerkTick >= Self.windowTicks else { return false }
        lastPerkTick = tick
        return true
    }
}

struct NamingCeremonyView: View {
    let archetype: Archetype
    @Binding var isPresented: Bool
    @AppStorage("companionName") private var companionName = ""
    @AppStorage("namingCompleted") private var namingCompleted = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    /// E3: live hero's director (held via callback) + the perk throttle.
    @State private var previewDirector: SpriteDirector?
    @State private var perkThrottle = PerkThrottle()
    @State private var appearDate = Date()

    /// Called when a name is committed so the stage can celebrate.
    var onName: ((String) -> Void)?

    private var accent: Color { SetupTheme.accent(for: archetype) }

    /// The current stage name (custom name, else the codename) — the
    /// placeholder and the rename prefill both show THIS, not the codename.
    private var currentName: String {
        companionName.isEmpty ? archetype.displayName : companionName
    }

    private var previewName: String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? currentName : trimmed
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                // v32 fit fix: on 42 mm (223 pt) the field + commit sat below
                // the fold — compact mode tightens the stack so the typing
                // surface is reachable with the keyboard open.
                let compact = geometry.size.height < 260
                ScrollView {
                    VStack(spacing: compact ? 8 : 10) {
                    // E3 "it hears you": the hero is alive — while you type,
                    // the companion perks (looks up at the name), throttled to
                    // once per 20 ticks (3 s).
                    LiveCompanionPreviewView(archetype: archetype, size: compact ? 44 : 56,
                                             onDirectorChange: { previewDirector = $0 })
                        .padding(.top, compact ? 2 : 6)
                        .onChange(of: draft) { _ in
                            guard focused else { return }
                            let tick = Int(Date().timeIntervalSince(appearDate) / SpriteDirector.tickDuration)
                            if perkThrottle.allow(tick: tick) { previewDirector?.playPerk() }
                        }
                    Text(String(format: String(localized: "naming.title"), archetype.animalName))
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(String(localized: "naming.subtitle"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(compact ? 1 : 2)
                    // v30: the live preview is the moment's headline — large,
                    // accent, scales down instead of truncating at AX sizes.
                    Text("“\(previewName)”")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .accessibilityLabel(String(format: String(localized: "naming.preview"), previewName))
                    // The field sits in an accent-tinted card with a 44 pt
                    // clear button (v27's bare 17 pt icon failed the target
                    // floor).
                    HStack(spacing: 6) {
                        TextField(currentName, text: $draft)
                            .focused($focused)
                            .textContentType(.name)
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
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel(String(localized: "naming.clear"))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(accent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button(action: commit) {
                        Text(String(localized: "naming.commit"))
                    }
                    .buttonStyle(.setupProminent(accentHex: SetupTheme.accentHex(for: archetype)))
                    .accessibilityHint(String(localized: "naming.commit_hint"))
                    Button(role: .cancel) {
                        finish()
                    } label: {
                        Text(String(localized: "naming.cancel"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // v30: quiet visually, 44 pt in hit area.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle(String(localized: "naming.nav"))
            .onAppear {
                // v30: rename path prefills the current name.
                if draft.isEmpty { draft = companionName }
                appearDate = Date()
                focused = true
            }
        }
    }

    /// v31: pure and testable — trim, clamp to 24 chars (one stage line,
    /// never wraps into the state line), fall back to the codename.
    static func resolvedName(_ draft: String, fallback: String) -> String {
        let clamped = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        return clamped.isEmpty ? fallback : clamped
    }

    private func commit() {
        let name = Self.resolvedName(draft, fallback: archetype.displayName)
        companionName = name
        // E3/E4: the naming day is persisted on commit (the anniversary anchor).
        var memory = CompanionMemoryStore().load() ?? CompanionMemory()
        memory.namingDay = Date()
        CompanionMemoryStore().save(memory)
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
