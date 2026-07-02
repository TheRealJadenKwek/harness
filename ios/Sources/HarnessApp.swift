import SwiftUI
import UserNotifications

@main
struct HarnessApp: App {
    @StateObject private var app = AppState()
    @UIApplicationDelegateAdaptor(PushManager.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(app)
                .onAppear { UNUserNotificationCenter.current().setBadgeCount(0) }   // cold launch
        }
        // SwiftUI apps use the scene lifecycle, so applicationDidBecomeActive never fires —
        // clear the red badge here whenever the app becomes active (you've seen what's there).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { UNUserNotificationCenter.current().setBadgeCount(0) }
        }
    }
}
