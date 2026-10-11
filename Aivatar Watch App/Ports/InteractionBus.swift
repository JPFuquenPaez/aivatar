import Foundation
import os

/// Phase B plug-in port (§13): UI events translated to avatar events.
enum AvatarEvent: Sendable {
    case tap, wake, sleep, crownTick(delta: Float), gesture(name: String)
}

protocol InteractionBus: AnyObject {
    func subscribe(_ handler: @Sendable @escaping (AvatarEvent) -> Void)
}

/// No-op Phase B stub. Phase B supplies a real bus; the engine's reaction layer
/// (L3) subscribes without any engine-side changes.
final class NullInteractionBus: InteractionBus {
    private let lock = NSLock()
    private var handlers: [@Sendable (AvatarEvent) -> Void] = []

    func subscribe(_ handler: @Sendable @escaping (AvatarEvent) -> Void) {
        lock.lock()
        handlers.append(handler)
        lock.unlock()
    }

    func emit(_ event: AvatarEvent) {
        lock.lock()
        let snapshot = handlers
        lock.unlock()
        for handler in snapshot { handler(event) }
    }
}

/// Telemetry sink (§3 ports): performance/behavior counters for A4 budget
/// assertions and future Phase B/C instrumentation. No-op until wired.
nonisolated protocol TelemetrySink: Sendable {
    func record(counter: String, value: Float)
}

nonisolated struct NullTelemetrySink: TelemetrySink {
    func record(counter: String, value: Float) {}
}

/// os_log-backed telemetry sink (§3 ports): event counters visible in
/// Console.app and Instruments for the on-device validation pass (§11).
/// Records are fire-and-forget logs; nothing is buffered or shipped.
nonisolated struct OsLogTelemetrySink: TelemetrySink {
    private let logger = Logger(subsystem: "com.aivatar.telemetry", category: "counters")

    func record(counter: String, value: Float) {
        logger.log("\(counter, privacy: .public) = \(value, privacy: .public)")
    }
}
