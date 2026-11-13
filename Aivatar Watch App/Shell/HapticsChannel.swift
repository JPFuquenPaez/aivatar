import WatchKit

/// HapticMoment (v22, Ambient Life F7 — haptic language): the designed
/// vocabulary of wrist moments. Haptics mark STATE TRANSITIONS only — never
/// ambient patter, never loops (platform guideline). Every meaning is
/// redundant with visual + VoiceOver; haptic-only meaning is forbidden.
nonisolated enum HapticMoment: String, Sendable, CaseIterable {
    /// Any touch answered (tap, gesture).
    case ack
    /// Bond ritual completed / level-up — the two-step rising pair.
    case bond
    /// A life event was noticed (calendar, sleep, weather).
    case lifeEvent
    /// Wrist-drop farewell.
    case farewell
    /// App open greeting.
    case greet
    /// Wrist-raise wake.
    case wake
}

/// HapticGrammar (F7): the pure moment -> WKHapticType table, per archetype.
/// The SHAPE is identical across archetypes for every moment (one short
/// tick, a rising pair, one soft stop); only the FLAVOR differs — the same
/// moment is always the same kind of touch. No CoreHaptics on watchOS: the
/// WKInterfaceDevice vocabulary is the honest ceiling.
nonisolated enum HapticGrammar {
    static func type(for moment: HapticMoment, archetype: Archetype) -> WKHapticType {
        switch moment {
        case .ack:
            switch archetype {
            case .ember:   return .directionUp    // high-tempo, springy: rising
            case .willow:  return .success        // gentle, agreeable: warm
            case .compass: return .click          // precise, deliberate: tick
            case .prism:   return .notification   // quirky, unpredictable
            case .nimbus:  return .directionDown  // reactive dart, startle edge
            case .lumen:   return .success        // soft, luminous
            }
        case .bond:
            return .directionUp                   // pair: directionUp -> success
        case .lifeEvent:
            switch archetype {
            case .nimbus, .ember: return .directionUp   // noticed-first
            case .willow, .compass: return .click       // gentle tick
            case .prism: return .notification
            case .lumen: return .click
            }
        case .farewell: return .stop
        case .greet:   return .start
        case .wake:    return .success
        }
    }

    /// True when the moment is the two-step bond pair (plays two haptics,
    /// counts as one interaction).
    static func isPair(_ moment: HapticMoment) -> Bool { moment == .bond }
}

/// HapticRateLimiter (F7): the global caps — at most 6 haptics/hour and a
/// minimum interval between any two — pure and clock-injectable, so the
/// caps are proven under adversarial bursts in tests.
nonisolated struct HapticRateLimiter: Sendable {
    /// Max haptics per rolling hour (F7 spec: <= 6/hour).
    static let maxPerHour = 6
    /// Minimum seconds between any two haptics (<= 1 per interaction).
    static let minIntervalSec: TimeInterval = 1.5

    private var history: [Date]

    init(history: [Date] = []) { self.history = history }

    /// Whether a haptic at `now` is allowed, and the limiter state after.
    mutating func allowing(now: Date) -> Bool {
        history.removeAll { now.timeIntervalSince($0) >= 3_600 }
        guard history.count < Self.maxPerHour else { return false }
        if let last = history.last, now.timeIntervalSince(last) < Self.minIntervalSec {
            return false
        }
        history.append(now)
        return true
    }
}

/// Haptics as an avatar output channel (§9). CoreHaptics does not exist on
/// watchOS; the WKInterfaceDevice haptic set is the supported surface.
/// Calls happen only on state transitions (never per frame), and only when
/// the rate limiter allows (F7 caps).
@MainActor
final class HapticsChannel {
    static let shared = HapticsChannel()

    private var limiter = HapticRateLimiter()

    private init() {}

    /// The designed entry point (F7): one moment, archetype-flavored, capped.
    /// Returns true when a haptic actually played (tests/telemetry).
    @discardableResult
    func play(_ moment: HapticMoment, archetype: Archetype) -> Bool {
        let now = Date()
        guard limiter.allowing(now: now) else { return false }
        let type = HapticGrammar.type(for: moment, archetype: archetype)
        WKInterfaceDevice.current().play(type)
        if HapticGrammar.isPair(moment) {
            // The rising pair: directionUp now, success after 120 ms.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                WKInterfaceDevice.current().play(.success)
            }
        }
        return true
    }

    /// Greeting / attention (app open).
    func greet() { play(.greet, archetype: AvatarSession.shared.archetype) }

    /// Wake-up acknowledgment (wrist raise, §8).
    func wake() { play(.wake, archetype: AvatarSession.shared.archetype) }

    /// Generic reaction tick (tap responses).
    func react() { play(.ack, archetype: AvatarSession.shared.archetype) }

    /// Per-archetype reaction haptic (§9): tap answer flavor.
    func react(to archetype: Archetype) { play(.ack, archetype: archetype) }

    /// Notification-level nudge (Phase B).
    func notify() { play(.lifeEvent, archetype: AvatarSession.shared.archetype) }

    /// Bond ritual completed / level-up: the two-step rising pair (F1/F7).
    func bond() { play(.bond, archetype: AvatarSession.shared.archetype) }

    /// Farewell (wrist drop): one soft stop — the pet saying goodnight.
    func farewell() { play(.farewell, archetype: AvatarSession.shared.archetype) }

    /// Split cheer (F6): one success-class beat.

    /// Aivatar 2.0 E2: picker page-swipe tick — one `.click` per swipe, routed
    /// through the global limiter (>= 1.5 s spacing, <= 6/hour).
    func pageTick() {
        guard limiter.allowing(now: Date()) else { return }
        WKInterfaceDevice.current().play(.click)
    }

    /// Aivatar 2.0 E7: the boop ack — a soft confirmation (`.success` is the
    /// gentle double-tick; WKHapticType has no softer watchOS-native option).
    func boop() {
        guard limiter.allowing(now: Date()) else { return }
        WKInterfaceDevice.current().play(.success)
    }

    /// Aivatar 2.0 E8: breath-session markers — `.click` at tick 0, `.success`
    /// at tick 396. Exactly 2 haptics per session, through the global limiter.
    func sessionMarker(start: Bool) {
        guard limiter.allowing(now: Date()) else { return }
        WKInterfaceDevice.current().play(start ? .click : .success)
    }
}
