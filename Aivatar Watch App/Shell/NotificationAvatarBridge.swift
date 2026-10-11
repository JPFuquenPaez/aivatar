import Foundation
import UserNotifications
import WatchKit

/// NotificationAvatarBridge (§1 Phase B "notifications"; §13 ports):
/// translates UserNotifications into AvatarEvents on the engine's L3 port.
/// The engine knows nothing about UserNotifications — this bridge is the
/// app-side adapter the port rule requires.
///
/// Verified against the watchOS SDK: UNUserNotificationCenterDelegate
/// (watchOS 3+), .banner presentation (watchOS 7+), openSettingsFor is
/// unavailable on watchOS (not implemented). Authorization is plumbed but
/// only requested when a real notification source lands — a permission
/// prompt with nothing behind it is worse than no prompt (watchOS HIG).
///
/// Statelesness: all mapping is pure and static (unit-tested); the delegate
/// methods hop to the main actor only to deliver the event.
final class NotificationAvatarBridge: NSObject, UNUserNotificationCenterDelegate {
    /// Retained by the static (the center's delegate is weak).
    static let shared = NotificationAvatarBridge()

    private override init() {
        super.init()
    }

    /// Payload key a notification may carry to direct the avatar's reaction
    /// (e.g. remote/companion-app payloads: ["aivatar.gesture": "wave"]).
    nonisolated static let gestureUserInfoKey = "aivatar.gesture"

    /// The attention gesture each archetype performs when a notification
    /// arrives without an explicit gesture payload — §5-style design
    /// proposal. All defaults write an expression channel so notification
    /// reactions still read on the face in Reduce Motion L2 (explicit
    /// gesture events bypass the L2 pool filter by design).
    nonisolated static func defaultAttentionGesture(for archetype: Archetype) -> GestureClip {
        switch archetype {
        case .ember: return .wave        // greets you, warm
        case .willow: return .wave       // gentle acknowledgment
        case .compass: return .lookAround // scans the room, focused
        case .prism: return .doubleTake  // curious double-take
        case .nimbus: return .puff       // alert swell
        }
    }

    /// Pure mapping (tests): notification userInfo -> reaction clip.
    /// An explicit, valid gesture name wins; anything else falls back to
    /// the archetype's default attention gesture.
    nonisolated static func attentionGesture(userInfo: [AnyHashable: Any], archetype: Archetype) -> GestureClip {
        attentionGesture(named: userInfo[gestureUserInfoKey] as? String, archetype: archetype)
    }

    /// Pure mapping; the payload name is extracted off the main actor (a
    /// userInfo dictionary is not Sendable; a String is).
    nonisolated static func attentionGesture(named: String?, archetype: Archetype) -> GestureClip {
        if let name = named, let clip = GestureClip(rawValue: name) {
            return clip
        }
        return defaultAttentionGesture(for: archetype)
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Foreground delivery: keep the system banner (the user asked for this
    /// notification — the avatar's reaction is additive, never a
    /// replacement) and answer in character with the archetype haptic.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let requested = notification.request.content.userInfo[Self.gestureUserInfoKey] as? String
        Task { @MainActor in
            let archetype = AvatarSession.shared.archetype
            let gesture = Self.attentionGesture(named: requested, archetype: archetype)
            AvatarSession.shared.handle(.gesture(name: gesture.rawValue))
            HapticsChannel.shared.notify()
        }
        completionHandler([.banner])
    }

    /// The user opened the app from the notification: the wake crossfade
    /// and warm greeting already run on foreground (§8); add the
    /// archetype's attention gesture and the greeting haptic.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let requested = response.notification.request.content.userInfo[Self.gestureUserInfoKey] as? String
        Task { @MainActor in
            let archetype = AvatarSession.shared.archetype
            let gesture = Self.attentionGesture(named: requested, archetype: archetype)
            AvatarSession.shared.handle(.gesture(name: gesture.rawValue))
            HapticsChannel.shared.greet()
        }
        completionHandler()
    }

    // MARK: Authorization

    /// Requests notification authorization (alert + sound; badges do not
    /// exist on watchOS). Called only from a real notification feature —
    /// never at launch (watchOS HIG: ask in context, once).
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }
}
