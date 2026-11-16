import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// PetImageRender (v43, AMS v2 §5.6): the PORTRAIT compositor for the HD pet
/// cuts (imagesets `pet-<name>` from the avatars/ sheet). The portraits are
/// static identity art — "a photo of your companion" — shown on the picker
/// disc, the naming hero, the iPhone card and the postcard front. They are
/// NEVER animated (the v42 stage path, its transforms and the crop-rotation
/// puppet redraw are deleted — the sticker problem must not come back
/// through any door; the live companion is the authored grid).
nonisolated enum PetImageRender {

    /// The pet's HD portrait, if the sprite carries one and the asset
    /// resolves in this process. Callers render it static (aspect-fit in a
    /// disc/card), never as the stage.
    static func portraitImage(_ sprite: CompanionSprite) -> UIImage? {
        guard let name = sprite.portraitAssetName else { return nil }
        return UIImage(named: name)
    }

    /// UI accent hex for portrait surfaces (the family accent).
    static func color(_ hex: String) -> Color {
        let rgb = CompanionSprite.hexToRGB(hex)
        return Color(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}
