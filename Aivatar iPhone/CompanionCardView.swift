import SwiftUI

/// CompanionCardView: the iPhone companion shell's single surface — the
/// companion's card (real pixel icon from the shared container), its name,
/// identity, day count and presence line, plus the postcard share export.
/// Empty state when the watch app has not published yet.
struct CompanionCardView: View {
    @State private var snapshot: CompanionWidgetSnapshot? = CompanionWidgetState.readSnapshot()
    @State private var iconData: Data?
    @State private var cardURL: URL?

    private var name: String { snapshot?.name ?? "—" }
    private var presenceLine: String {
        guard let snapshot else { return "" }
        let kind = snapshot.lastEventKindRaw.flatMap { LifeKind(rawValue: $0) }
        return CompanionStateDerivation.line(for: snapshot.presence, lastEventKind: kind)
    }
    private var subtitle: String {
        guard let snapshot else { return "" }
        return String(format: String(localized: "phone.card.subtitle"),
                      snapshot.dayCount, presenceLine)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 20) {
                    Spacer()
                    if let iconData, let ui = UIImage(data: iconData) {
                        Image(uiImage: ui)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: 180, height: 162)
                    } else {
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: 72))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    VStack(spacing: 6) {
                        Text(name)
                            .font(.title.weight(.semibold))
                        if let snapshot {
                            Text(String(format: String(localized: "identity.full"),
                                        snapshot.name,
                                        LocalizedAnimalCopy.animalName(
                                            CompanionStateDerivation.sanitizedArchetypeRaw(snapshot.archetypeRaw))))
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    if let snapshot, let cardURL {
                        ShareLink(item: cardURL) {
                            Label(String(localized: "phone.share"), systemImage: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color.white.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                    } else {
                        Text(String(localized: "phone.empty"))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.bottom, 24)
                    }
                }
            }
            .foregroundStyle(.white)
            .navigationTitle(String(localized: "phone.title"))
            .onAppear { refresh() }
            .refreshable { refresh() }
        }
    }

    private func refresh() {
        snapshot = CompanionWidgetState.readSnapshot()
        guard let snapshot else { return }
        let url = CompanionWidgetState.iconURL(
            forArchetypeRaw: snapshot.archetypeRaw, presence: snapshot.presence)
            ?? CompanionWidgetState.iconURL(forArchetypeRaw: snapshot.archetypeRaw)
        iconData = url.flatMap { try? Data(contentsOf: $0) }
        // Compose the shareable postcard once per snapshot (deterministic).
        let kind = snapshot.lastEventKindRaw.flatMap { LifeKind(rawValue: $0) }
        let subtitle = String(format: String(localized: "phone.card.subtitle"),
                              snapshot.dayCount,
                              CompanionStateDerivation.line(for: snapshot.presence, lastEventKind: kind))
        if let png = PostcardCard.pngData(iconPNG: iconData, title: snapshot.name, subtitle: subtitle) {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("aivatar-postcard.png")
            try? png.write(to: dest)
            cardURL = dest
        }
    }
}
