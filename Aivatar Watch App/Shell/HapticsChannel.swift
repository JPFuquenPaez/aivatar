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

    /// Notification-level nudge (Phase B).
    func notify() {
        WKInterfaceDevice.current().play(.notification)
    }
}
