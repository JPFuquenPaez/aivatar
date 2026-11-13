import Foundation

/// Archetype (shared core, v36): the companion identity enum. Lives in
/// AivatarShared so the watch app, widget, and iPhone shell all compile the
/// same sprite core against it. GestureClip-coupled members (farewell/quirk)
/// live in the watch target's ArchetypeGestures.swift extension.
nonisolated enum Archetype: String, Sendable, CaseIterable, Codable {
    case ember, willow, compass, prism, nimbus, lumen

    nonisolated var displayName: String {
        switch self {
        case .ember: return "Ember"
        case .willow: return "Willow"
        case .compass: return "Compass"
        case .prism: return "Prism"
        case .nimbus: return "Nimbus"
        case .lumen: return "Lumen"
        }
    }

    /// v10: the animal identity (Tools/PIXEL_DESIGN.md v3) — the personality
    /// IS the animal. The codename above stays the persisted key (storage,
    /// seed anchor, profile id); the animal is the presented identity in the
    /// companion picker, the naming ceremony, and the accessibility label.
    /// v30: the presented copy is LOCALIZED (`animal.<raw>.*` keys, resolved
    /// via the shared LocalizedAnimalCopy so the widget bundle mirrors them);
    /// engine behavior never keys on these strings.
    nonisolated var animal: CompanionAnimal {
        CompanionAnimal(
            name: LocalizedAnimalCopy.name(rawValue),
            element: LocalizedAnimalCopy.element(rawValue),
            temperament: LocalizedAnimalCopy.temperament(rawValue))
    }

    /// Lowercase animal name for prose ("your fox companion").
    nonisolated var animalName: String { animal.name.lowercased() }

    /// "Ember the fox" — the presented full identity (localized word order).
    nonisolated var fullName: String { LocalizedAnimalCopy.fullName(displayName: displayName, archetypeRaw: rawValue) }

    /// One-line likable-pole blurb for the companion picker (§5: every
    /// archetype anchors a likable pole — sensitivity reads as responsive,
    /// never as anxious). v10: the copy is the animal's temperament.
    nonisolated var tagline: String { animal.temperament }
}

/// The animal a companion archetype presents as (v10, Tools/PIXEL_DESIGN.md
/// v3): one reduced animal per category — fox (land/fire), frog (amphibian),
/// fish (water), bird (air), chameleon (reptile). `temperament` is the
/// likable-pole copy shown in the companion picker (§5 guardrail: no
/// companion reads as a negative trait).
nonisolated struct CompanionAnimal: Sendable, Equatable, Codable {
    /// "Fox" — the headline in the picker.
    var name: String
    /// The animal's category/element ("land & fire").
    var element: String
    /// One-line likable-pole temperament.
    var temperament: String
}
