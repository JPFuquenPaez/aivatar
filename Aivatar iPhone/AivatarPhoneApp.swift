import SwiftUI

/// AivatarPhoneApp (Aivatar 2.0 Phase 3): the iPhone companion shell. A quiet
/// reader of the shared app-group snapshot — it never polls, never writes;
/// the watch app is the single writer (CompanionWidgetPublisher). It shows the
/// companion's card and lands the postcard share-sheet export.
@main
struct AivatarPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            CompanionCardView()
        }
    }
}
