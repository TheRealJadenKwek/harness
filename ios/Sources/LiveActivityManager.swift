import ActivityKit
import Foundation

/// Starts/updates/ends the per-turn Live Activity. The app drives updates while
/// it's alive; the SERVER also pushes the same content-state via APNs
/// (apns-push-type: liveactivity) so the island keeps moving after the app is
/// closed — that's why the activity registers its push token with the harness.
@MainActor
enum LiveActivityManager {
    static func start(threadID: String, title: String, engine: String, api: HarnessAPI) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("LiveActivity: activities DISABLED (authorization)")
            return
        }
        if let existing = activity(for: threadID) {
            // Reuse a leftover activity (e.g. reconnect) — snap it back to working state.
            Task { await existing.update(content(phase: "thinking", detail: "")) }
            return
        }
        let attrs = HarnessActivityAttributes(threadID: threadID, title: title,
                                              engine: engine, startedAt: Date())
        let act: Activity<HarnessActivityAttributes>
        do {
            act = try Activity.request(attributes: attrs,
                                       content: content(phase: "thinking", detail: ""),
                                       pushType: .token)
            NSLog("LiveActivity: started (push) for %@", threadID)
        } catch {
            // No push entitlement (e.g. unsigned simulator builds) -> app-driven only.
            do {
                act = try Activity.request(attributes: attrs,
                                           content: content(phase: "thinking", detail: ""))
                NSLog("LiveActivity: started (local, no push: %@)", String(describing: error))
                return
            } catch {
                NSLog("LiveActivity: request FAILED: %@", String(describing: error))
                return
            }
        }
        Task {
            for await tokenData in act.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                try? await api.registerActivity(threadID, token: hex)
            }
        }
    }

    static func update(threadID: String, phase: String, detail: String) {
        guard let act = activity(for: threadID) else { return }
        Task { await act.update(content(phase: phase, detail: detail)) }
    }

    static func end(threadID: String, phase: String, detail: String) {
        guard let act = activity(for: threadID) else { return }
        Task {
            await act.end(content(phase: phase, detail: detail),
                          dismissalPolicy: .after(.now + 10))
        }
    }

    /// End activities whose turns are no longer running (the app may have been suspended
    /// before `done` arrived; on devices the server's push also closes them — this is the
    /// fallback that runs on every thread-list refresh).
    static func reconcile(running: Set<String>) {
        for act in Activity<HarnessActivityAttributes>.activities
        where !running.contains(act.attributes.threadID) {
            Task { await act.end(content(phase: "done", detail: ""), dismissalPolicy: .immediate) }
        }
    }

    private static func activity(for threadID: String) -> Activity<HarnessActivityAttributes>? {
        Activity<HarnessActivityAttributes>.activities.first { $0.attributes.threadID == threadID }
    }

    private static func content(phase: String, detail: String) -> ActivityContent<HarnessActivityAttributes.ContentState> {
        .init(state: .init(phase: phase, detail: detail), staleDate: nil)
    }
}
