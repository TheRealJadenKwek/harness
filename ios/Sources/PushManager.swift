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
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Approval pushes carry Allow/Deny directly on the banner (long-press / pull down).
        // Allow requires an unlocked device — approving a tool run shouldn't work from a locked lockscreen.
        let allow = UNNotificationAction(identifier: "HARNESS_ALLOW", title: "Allow",
                                         options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "HARNESS_DENY", title: "Deny",
                                        options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "HARNESS_APPROVAL", actions: [allow, deny],
                                   intentIdentifiers: [], options: [])
        ])
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

    // Tapping a notification deep-links into its thread; Allow/Deny actions answer
    // the approval straight from the banner without opening the app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let tid = info["threadId"] as? String, let aid = info["approvalId"] as? String,
           response.actionIdentifier == "HARNESS_ALLOW" || response.actionIdentifier == "HARNESS_DENY" {
            PushManager.decideRemotely(threadID: tid, approvalID: aid,
                                       allow: response.actionIdentifier == "HARNESS_ALLOW",
                                       done: completionHandler)
            return
        }
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

extension PushManager {
    /// POST the decision straight from the notification action — works on a cold background
    /// launch (no AppState). The push doesn't say which harness sent it, so try every stored
    /// server; the wrong ones 404 and only the owner of the approval id accepts.
    static func decideRemotely(threadID: String, approvalID: String, allow: Bool,
                               done: @escaping () -> Void) {
        let servers = ServerStore.load()
        guard !servers.isEmpty else { done(); return }
        let body = try? JSONSerialization.data(withJSONObject: ["decision": allow ? "allow" : "deny"])
        let group = DispatchGroup()
        for s in servers {
            let base = s.url.hasSuffix("/") ? String(s.url.dropLast()) : s.url
            guard let url = URL(string: base + "/threads/\(threadID)/approvals/\(approvalID)") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.timeoutInterval = 15
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !s.token.isEmpty { req.setValue("Bearer \(s.token)", forHTTPHeaderField: "Authorization") }
            group.enter()
            URLSession.shared.dataTask(with: req) { _, _, _ in group.leave() }.resume()
        }
        group.notify(queue: .main) { done() }
    }
}
