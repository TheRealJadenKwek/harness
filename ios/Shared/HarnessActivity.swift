import ActivityKit
import Foundation

/// Shared between the app (starts/updates the activity) and the widget extension
/// (renders it). The server's live-activity pushes carry the same content-state
/// JSON, so these property names ARE the wire format — don't rename casually.
struct HarnessActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var phase: String     // thinking | streaming | tool | approval | done | error
        var detail: String    // tool name, approval summary, or final snippet
    }

    var threadID: String
    var title: String
    var engine: String        // claude | codex — picks the icon
    var startedAt: Date       // fixed at start; drives the elapsed timer
}
