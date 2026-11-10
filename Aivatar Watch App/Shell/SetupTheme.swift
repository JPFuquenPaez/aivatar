import SwiftUI

/// SetupTheme (v30, "setup surfaces 2.0" — from the three-agent audit of the
/// setup surfaces): the shared visual system for the picker, naming
/// ceremony, settings, workout and postcard — one coherent language on the
/// OLED-black stage.
///
/// v30 changes over v27:
/// - The accent IS the sprite's body token (`paletteHex["B"]`), so disc,
///   ring, button and icon share one hue (v27 mixed the engine palette with
///   the sprite body — visibly mismatched on ember/compass/prism). Cached
///   once per archetype (v27 re-parsed the profile JSON on every call).
/// - The hero is a glow-disc: a soft radial accent halo behind a flat tinted
///   disc. Chrome only — the icon itself stays nearest-neighbor crisp.
/// - Containers are accent-tinted (`tint.opacity(0.08)`), not white-0.07
///   slabs that floated off the black stage.
/// - The primary button is a 44 pt-floor full-width control with a
///   luminance-aware ink (WCAG >= 4.5:1 on every archetype accent — pinned
///   in SetupThemeTests), a `selected` variant that reads selected (accent
///   15% bg + accent ink + ring) instead of v27's disabled-looking gray, and
///   a press animation that respects Reduce Motion.
///
/// watchOS HIG: black backgrounds, tint-driven hierarchy, full-width buttons
/// with 44 pt+ targets, text styles only (Dynamic Type).
nonisolated enum SetupTheme {
    /// The companion's body token ("B") from the authored sprite — the same
    /// hue the icon renders in. Single source of truth for all chrome.
    static func accentHex(for archetype: Archetype) -> String {
        accentHexes[archetype] ?? "FF9E4A"
    }

    private static let accentHexes: [Archetype: String] = {
        var dict: [Archetype: String] = [:]
        for archetype in Archetype.allCases {
            dict[archetype] = AuthoredSprites.sprite(for: archetype).paletteHex["B"]
        }
        return dict
    }()

    /// The companion's accent color as a SwiftUI Color.
    static func accent(for archetype: Archetype) -> Color {
        color(hex: accentHex(for: archetype))
    }

    static func color(hex: String) -> Color {
        let rgb = CompanionSprite.hexToRGB(hex)
        return Color(.sRGB,
                     red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }

    // MARK: WCAG helpers (pure, hex-based — pinned in SetupThemeTests)

    /// Relative luminance (WCAG 2.x) of a RRGGBB hex (no '#').
    static func relativeLuminance(_ hex: String) -> Double {
        let rgb = CompanionSprite.hexToRGB(hex)
        func lin(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(rgb.r) + 0.7152 * lin(rgb.g) + 0.0722 * lin(rgb.b)
    }

    /// WCAG contrast ratio between two RRGGBB hexes (1...21).
    static func contrastRatio(_ a: String, _ b: String) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The label ink on a solid accent button: black at 87% when it clears
    /// 4.5:1, white otherwise. All five body tokens pass with black; the
    /// branch is a pinned safety net for future palette changes.
    static func buttonForeground(on hex: String) -> Color {
        contrastRatio(hex, "000000") >= 4.5 ? Color.black.opacity(0.87) : .white
    }

    /// A soft accent-tinted card on OLED black — the v30 container idiom.
    static func card<Content: View>(tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The glow-disc hero: the companion's icon on a flat tinted disc with a
    /// soft radial halo, optionally ringed + badged when selected. Pixel-crisp
    /// (`interpolation(.none)`), `accessibilityHidden` — text carries the a11y.
    static func iconDisc(for archetype: Archetype, selected: Bool = false, size: CGFloat = 64) -> some View {
        SetupIconDisc(archetype: archetype, selected: selected, size: size)
    }
}

/// The glow-disc hero as a real view so it can read Reduce Motion (v30).
struct SetupIconDisc: View {
    let archetype: Archetype
    var selected: Bool
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let accent = SetupTheme.accent(for: archetype)
        ZStack {
            // Soft halo — chrome only; the brand's hard-edge rule governs
            // the sprite, not this. Confined to a ~1.6x-size circle, so the
            // lit area stays small (OLED discipline).
            Circle()
                .fill(RadialGradient(
                    colors: [accent.opacity(selected ? 0.34 : 0.24), accent.opacity(0.10), .clear],
                    center: .center, startRadius: size * 0.12, endRadius: size * 0.80))
                .frame(width: size * 1.6, height: size * 1.6)
            Circle()
                .fill(accent.opacity(0.12))
                .frame(width: size, height: size)
            if let image = CompanionIcon.image(for: archetype) {
                image
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: size * 0.78, height: size * 0.78)
            }
            if selected {
                Circle()
                    .stroke(accent, lineWidth: 2.5)
                    .frame(width: size, height: size)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.28))
                    .foregroundStyle(accent)
                    .background(Circle().fill(Color.black))
                    .offset(x: size * 0.36, y: -size * 0.36)
            }
        }
        .scaleEffect(selected ? 1.05 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: selected)
        .accessibilityHidden(true)
    }
}

/// Full-width primary setup button (v30): 44 pt floor, solid accent with a
/// luminance-aware ink, semibold body label, press feedback (Reduce Motion
/// keeps only the opacity change), and a `selected` variant — accent 15% bg
/// + accent ink + hairline ring — that reads selected, not disabled.
struct SetupPrimaryButtonStyle: ButtonStyle {
    /// RRGGBB accent — single source for both the tint and the ink contrast.
    var accentHex: String
    var selected: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let tint = SetupTheme.color(hex: accentHex)
        let ink = SetupTheme.buttonForeground(on: accentHex)
        return configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 12)
            .background(selected ? tint.opacity(0.15)
                        : configuration.isPressed ? tint.opacity(0.72) : tint)
            .foregroundStyle(selected ? tint : ink)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                selected
                    ? RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(tint.opacity(0.5), lineWidth: 1)
                    : nil)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SetupPrimaryButtonStyle {
    /// Full-width, accent-tinted, 44 pt primary button. `accentHex` is the
    /// companion's body token (SetupTheme.accentHex) or a system color hex
    /// (e.g. "FF3B30" for destructive).
    static func setupProminent(accentHex: String, selected: Bool = false) -> SetupPrimaryButtonStyle {
        SetupPrimaryButtonStyle(accentHex: accentHex, selected: selected)
    }
}
