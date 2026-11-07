import WatchKit

/// Haptics as an avatar output channel (§9). CoreHaptics does not exist on
/// watchOS; the WKInterfaceDevice haptic set is the supported surface.
/// Calls happen only on state transitions (never per frame).
@MainActor
final class HapticsChannel {
    static let shared = HapticsChannel()

    private init() {}

    /// Greeting / attention (app open, Phase B hello).
    func greet() {
        WKInterfaceDevice.current().play(.start)
    }

    /// Wake-up acknowledgment (wrist raise, §8).
    func wake() {
        WKInterfaceDevice.current().play(.success)
    }

    /// Generic reaction tick (Phase B tap responses).
    func react() {
        WKInterfaceDevice.current().play(.click)
    }

    /// Per-archetype reaction haptic (§9 haptics as an avatar output
    /// channel): each archetype's tap answer has its own haptic flavor,
    /// mapped from its §5 motion signature. Like the §5 palettes, this
    /// mapping is a design proposal pending A4-style validation. Only
    /// WKHapticType cases verified in the watchOS SDK are used.
    func react(to archetype: Archetype) {
        let type: WKHapticType
        switch archetype {
        case .ember:   type = .directionUp    // high-tempo, springy: rising
        case .willow:  type = .success        // gentle, agreeable: warm
        case .compass: type = .click          // precise, deliberate: tick
        case .prism:   type = .notification   // quirky, unpredictable
        case .nimbus:  type = .directionDown   // reactive dart, startle edge
        }
        WKInterfaceDevice.current().play(type)
    }

    /// Notification-level nudge (Phase B).
    func notify() {
        WKInterfaceDevice.current().play(.notification)
    }

    /// v16 F1/F7 bond moment (ritual completed or level-up): a two-step
    /// rising pair. Haptics fire only on this state transition — never
    /// ambient patter (platform guideline; ≤ 1 per interaction).
    func bond() {
        WKInterfaceDevice.current().play(.directionUp)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            WKInterfaceDevice.current().play(.success)
        }
    }

    /// v16 F1 farewell (wrist drop): one soft stop — the pet saying goodnight.
    func farewell() {
        WKInterfaceDevice.current().play(.stop)
    }

    /// v21 F6 split cheer: one success-class beat per split.
    func split() {
        WKInterfaceDevice.current().play(.success)
    }
}
