import SwiftUI

/// PostcardPreviewView (v22 F8, v26 animated): the watch-side preview of the
/// user's deterministic postcard — now playing the ACTUAL composed card
/// (PostcardComposer.frames, the same bit-exact run the export will use) at
/// the 150 ms director clock, plus the auto-generated caption. The
/// share-sheet export lands with the iPhone companion shell.
struct PostcardPreviewView: View {
    let archetype: Archetype

    @AppStorage("companionName") private var companionName = ""

    @State private var frames: [CGImage] = []
    @State private var start = Date()

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
            TimelineView(.animation(minimumInterval: SpriteDirector.tickDuration)) { timeline in
                let idx = frames.isEmpty ? 0
                    : Int(timeline.date.timeIntervalSince(start) / SpriteDirector.tickDuration) % frames.count
                if !frames.isEmpty {
                    Image(decorative: frames[idx], scale: 1)
                        .interpolation(.none)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 60, height: 54)
            Text(PostcardComposer.caption(inputs))
                .font(.footnote)
                .multilineTextAlignment(.center)
            Text("A card of \(name), rendered from the same pixels as the stage.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
        .onAppear {
            // Compose the card once (deterministic), then play it.
            frames = PostcardComposer.frames(inputs)
                .compactMap { CompanionIcon.cgImage(for: archetype, grid: $0) }
            start = Date()
        }
    }
}

#if DEBUG
#Preview { PostcardPreviewView(archetype: .ember) }
#endif
