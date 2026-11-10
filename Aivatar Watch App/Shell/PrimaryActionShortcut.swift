import SwiftUI

/// PrimaryActionShortcutModifier (Aivatar 2.0, E6): double-tap wiring that
/// compiles on the watchOS 10 deployment target — `handGestureShortcut` is
/// watchOS 11+, so the modifier applies it only where available and is a
/// no-op below.
struct PrimaryActionShortcutModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 11, *) {
            content.handGestureShortcut(.primaryAction)
        } else {
            content
        }
    }
}

extension View {
    /// E6: expose this view's primary accessibility action to the double-tap
    /// gesture (watchOS 11+; no-op below).
    func primaryActionShortcut() -> some View {
        modifier(PrimaryActionShortcutModifier())
    }
}
