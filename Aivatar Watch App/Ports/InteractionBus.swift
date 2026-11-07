import Foundation
import os

/// Phase B plug-in port (§13): UI events translated to avatar events.
enum AvatarEvent: Sendable {
    case tap, wake, sleep, crownTick(delta: Float), gesture(name: String)
    /// v6 touch-gaze: the avatar's eyes dart toward the touched point
    /// (x/y normalized -1...1, screen orientation — rig space is y-down,
    /// so no flip). Engine-side poke with fast attack and slow decay;
    /// never starts a reaction clip.
    case gazeAt(x: Float, y: Float)
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
