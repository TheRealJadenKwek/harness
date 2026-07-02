import UIKit
import UserNotifications

/// App delegate that owns remote-notification registration and notification taps.
/// It stays decoupled from AppState by broadcasting over NotificationCenter:
///   • `.harnessPushToken`  — object is the hex device-token String
///   • `.harnessOpenThread` — object is the thread id String to navigate into
final class PushManager: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set true once RootView appears, so didReceive knows whether the SwiftUI tree (and
    /// AppState's observer) is alive to receive a live post, vs. a cold launch that must
    /// stash the target thread for RootView's .task to pick up.
    static var processAlive = false

    /// The thread the user is currently looking at (set by ChatView). A completion push for
    /// THIS thread is suppressed in-foreground — no point banner-ing what's already on screen.
    static var currentThreadID: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Opening the app clears the red badge (you've seen what's there).
    func applicationDidBecomeActive(_ application: UIApplication) {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    /// Ask for permission, then register with APNs. Safe to call repeatedly.
    static func requestAndRegister() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .harnessPushToken, object: hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("APNs registration failed: \(error.localizedDescription)")
    }

    // Show the banner in-foreground — UNLESS the user is already viewing that exact thread.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let tid = notification.request.content.userInfo["threadId"] as? String
        if let tid, tid == PushManager.currentThreadID {
            completionHandler([])                 // already on screen -> stay silent
        } else {
            completionHandler([.banner, .sound])
        }
    }

    // Tapping a notification deep-links into its thread.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let tid = response.notification.request.content.userInfo["threadId"] as? String, !tid.isEmpty {
            if PushManager.processAlive {
                NotificationCenter.default.post(name: .harnessOpenThread, object: tid)   // app alive -> navigate live
            } else {
                UserDefaults.standard.set(tid, forKey: "openThreadID")                   // cold launch -> RootView .task picks it up
            }
        }
        UNUserNotificationCenter.current().setBadgeCount(0)
        completionHandler()
    }
}

extension Notification.Name {
    static let harnessPushToken  = Notification.Name("harnessPushToken")
    static let harnessOpenThread = Notification.Name("harnessOpenThread")
}
