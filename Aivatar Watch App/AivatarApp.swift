//
//  AivatarApp.swift
//  Aivatar Watch App
//

import SwiftUI
import UserNotifications

@main
struct Aivatar_Watch_AppApp: App {
    init() {
        // Phase B: notifications become avatar events (§13 port). The
        // delegate must be installed before the app finishes launching —
        // a cold launch from a notification tap delivers didReceive shortly
        // after launch. The bridge resolves the live engine lazily via
        // AvatarSession, so launch order does not matter.
        UNUserNotificationCenter.current().delegate = NotificationAvatarBridge.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
