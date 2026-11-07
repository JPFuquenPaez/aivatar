import SwiftUI

/// PostcardPreviewView (v22, F8): the watch-side preview of the user's
/// deterministic postcard — the real rendered companion plus the
/// auto-generated caption. The shareable export (looping card via the
/// share sheet) lands with the iPhone companion shell; the composer behind
/// this preview is the same bit-exact path (pinned by tests).
struct PostcardPreviewView: View {
    let archetype: Archetype

    @AppStorage("companionName") private var companionName = ""

    private var name: String {
        companionName.isEmpty ? archetype.displayName : companionName
    }

    private var inputs: PostcardInputs {
        let memory = CompanionMemoryStore().load()
        let now = Date()
        let dayIndex = CompanionMemoryStore.dayIndex(of: now)
        let weatherRaw = memory?.lifeLog
            .filter { $0.kindHash == LifeKind.hash(of: .weatherClass) && $0.dayIndex == dayIndex }
            .last?.classHash
            .flatMap { ConditionClass.fromHash($0)?.rawValue }
        return PostcardInputs(
            archetypeRaw: archetype.rawValue,
            seed: 20261010 + UInt64(Archetype.allCases.firstIndex(of: archetype) ?? 0),
            name: name,
            bondLevel: memory?.bondLevel ?? 1,
            dayCount: memory.map { CompanionMemoryStore.dayDistance(from: $0.firstLaunch, to: now) + 1 } ?? 1,
            streakDays: memory?.streakDays ?? 0,
            weatherClassRaw: weatherRaw)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let image = CompanionIcon.image(for: archetype) {
                image
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 60, height: 54)
            }
            Text(PostcardComposer.caption(inputs))
                .font(.footnote)
                .multilineTextAlignment(.center)
            Text("A card of \(name), rendered from the same pixels as the stage.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
    }
}

#if DEBUG
#Preview { PostcardPreviewView(archetype: .ember) }
#endif
