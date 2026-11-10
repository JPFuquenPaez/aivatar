import Foundation

/// The presented animal identity copy, localized (v30). The five
/// companions' name / element / temperament live in the strings tables —
/// mirrored in BOTH the app bundle and the widget extension bundle (this
/// folder compiles into both), so the picker page, the accessibility labels,
/// and the watch-face rectangular line all speak the user's language.
/// Keys: `animal.<archetypeRaw>.name|element|temperament`, `identity.full`.
/// The archetype codename ("Ember") stays untranslated — it is the storage
/// key and the seed anchor, not presented prose.
nonisolated enum LocalizedAnimalCopy {
    // NOTE: the keys are RUNTIME-built ("animal.<raw>.name"), and
    // String(localized:) only performs a table lookup for string LITERALS —
    // with a dynamic key it would return the key itself. NSLocalizedString
    // looks up dynamic keys (and resolves against the process's main bundle,
    // so the widget extension reads its own mirrored table).
    //
    // v31: NSLocalizedString returns the KEY on a miss — in DEBUG we assert
    // so a typo'd or missing key fails loudly instead of echoing into the UI.
    private static func lookup(_ key: String, comment: String) -> String {
        let value = NSLocalizedString(key, comment: comment)
        #if DEBUG
        assert(value != key, "missing localization for key \(key)")
        #endif
        return value
    }

    /// True when the raw value is one of the five known archetypes — callers
    /// guard with this before building dynamic keys.
    static func isKnown(_ archetypeRaw: String) -> Bool {
        CompanionStateDerivation.knownArchetypeRaws.contains(archetypeRaw)
    }

    static func name(_ archetypeRaw: String) -> String {
        lookup("animal.\(archetypeRaw).name", comment: "animal species name")
    }

    static func element(_ archetypeRaw: String) -> String {
        lookup("animal.\(archetypeRaw).element", comment: "animal element")
    }

    static func temperament(_ archetypeRaw: String) -> String {
        lookup("animal.\(archetypeRaw).temperament", comment: "animal temperament line")
    }

    /// Lowercase animal name for prose ("your fox companion").
    static func animalName(_ archetypeRaw: String) -> String {
        name(archetypeRaw).lowercased()
    }

    /// "Ember the fox" — positional so translators control word order.
    static func fullName(displayName: String, archetypeRaw: String) -> String {
        String(format: String(localized: "identity.full"), displayName, animalName(archetypeRaw))
    }
}
