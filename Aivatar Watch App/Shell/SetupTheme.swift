import SwiftUI

/// SetupTheme (v27): the shared visual system for Aivatar's setup surfaces
/// (picker, naming ceremony, settings, workout, postcard) — one coherent
/// language on the OLED-black stage: soft tinted cards, the companion's own
/// accent color, SF Symbols, text styles only (Dynamic Type), 44 pt+ targets.
/// watchOS HIG: black backgrounds, tint-driven hierarchy, platform chrome
/// (List rows, full-width buttons), Liquid Glass materials where chrome sits.
nonisolated enum SetupTheme {
    /// The companion's own accent color (its profile primary) as a SwiftUI
    /// Color — drives buttons, selection rings, and icon discs per animal.
    static func accent(for archetype: Archetype) -> Color {
        let hex = (try? PersonalityProfile.load(archetype))
            .map { ArchetypeVisualSet(profile: $0).primaryHex }
            ?? "#FF8A3D"
        let rgb = CompanionSprite.hexToRGB(hex)
        return Color(.sRGB,
                     red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }

    /// A soft card: rounded rect on a faint white fill — the watchOS "card"
    /// idiom without heavy materials.
    static func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The companion's icon inside a tinted disc (accent at 15%), optionally
    /// ringed when selected. Pixel-crisp, never interpolated.
    static func iconDisc(for archetype: Archetype, selected: Bool = false, size: CGFloat = 64) -> some View {
        let accent = accent(for: archetype)
        return ZStack {
            Circle()
                .fill(accent.opacity(0.16))
                .frame(width: size, height: size)
            if let image = CompanionIcon.image(for: archetype) {
                image
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: size * 0.72, height: size * 0.72)
            }
            if selected {
                Circle()
                    .stroke(accent, lineWidth: 2.5)
                    .frame(width: size, height: size)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(accent)
                    .background(Circle().fill(Color.black))
                    .offset(x: size * 0.38, y: -size * 0.38)
            }
        }
        .accessibilityHidden(true)
    }
}


/// Full-width primary setup button, tinted with the companion's accent.
struct SetupPrimaryButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(configuration.isPressed ? tint.opacity(0.75) : tint)
            .foregroundStyle(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SetupPrimaryButtonStyle {
    /// Full-width, accent-tinted, press-responsive primary button.
    static func setupProminent(tint: Color = .accentColor) -> SetupPrimaryButtonStyle {
        SetupPrimaryButtonStyle(tint: tint)
    }
}
