import SwiftUI

/// CompanionCardView (v36): the iPhone companion shell's single surface. A quiet
/// reader of the shared app-group snapshot — it never polls the watch; the
/// watch app is the single writer (CompanionWidgetPublisher). What it shows is
/// the SAME living companion as the watch: the same authored pixel sprite on
/// the same 150 ms clock (PhoneCompanionView), the name, identity, day count
/// and presence line (re-derived locally once a minute from the snapshot's
/// timestamps — a local re-render, not a data poll). Empty state when the
/// watch app has not published yet.
struct CompanionCardView: View {
    @State private var snapshot: CompanionWidgetSnapshot? = CompanionWidgetState.readSnapshot()

    private var name: String { snapshot?.name ?? "—" }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                // Presence is re-derived once a minute from the snapshot
                // timestamps (a local re-render, not a data poll), so the
                // line reverts awake -> napping on its own — and the avatar's
                // mood follows it (.id recreates the animator on change).
                TimelineView(.everyMinute) { _ in
                    let presence = snapshot.map {
                        CompanionStateDerivation.presence(
                            now: Date(), lastSeen: $0.lastSeen, lastEventAt: $0.lastEventAt)
                    } ?? .asleep
                    VStack(spacing: 20) {
                        Spacer()
                        if let snapshot {
                            PhoneCompanionView(
                                archetype: Archetype(rawValue: CompanionStateDerivation.sanitizedArchetypeRaw(snapshot.archetypeRaw)) ?? .ember,
                                presence: presence,
                                size: 180
                            )
                            .id(presence)
                        } else {
                            Image(systemName: "pawprint.fill")
                                .font(.system(size: 72))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                        VStack(spacing: 6) {
                            Text(name)
                                .font(.title.weight(.semibold))
                            if let snapshot {
                                let kind = snapshot.lastEventKindRaw.flatMap { LifeKind(rawValue: $0) }
                                Text(String(format: String(localized: "identity.full"),
                                            snapshot.name,
                                            LocalizedAnimalCopy.animalName(
                                                CompanionStateDerivation.sanitizedArchetypeRaw(snapshot.archetypeRaw))))
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.6))
                                Text(String(format: String(localized: "phone.card.subtitle"),
                                            snapshot.dayCount,
                                            CompanionStateDerivation.line(for: presence, lastEventKind: kind)))
                                    .font(.footnote)
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                        }
                        Spacer()
                        if snapshot == nil {
                            Text(String(localized: "phone.empty"))
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.45))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                                .padding(.bottom, 24)
                        }
                    }
                }
            }
            .foregroundStyle(.white)
            .navigationTitle(String(localized: "phone.title"))
            .onAppear { snapshot = CompanionWidgetState.readSnapshot() }
            .refreshable { snapshot = CompanionWidgetState.readSnapshot() }
        }
    }
}
