import Foundation
import CryptoKit

struct Provider: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let engine: String
    let model: String?
    let enabled: Bool
    var models: [ModelOption]?
    var default_model: String?
    var default_effort: String?
    var requires_key: Bool?
    var has_key: Bool?
}

struct ThreadSummary: Codable, Identifiable, Hashable {
    let id: String
    var title: String?
    var engine: String
    var provider: String
    var model: String?
    var cwd: String?
    var session_id: String?
    var permission_mode: String?
    var effort: String?
    var created: Double?
    var updated: Double?
    var total_cost: Double?
    var message_count: Int?
    var running: Bool?
    var last: String?
    var last_role: String?
    var awaiting: Bool?
    var archived: Bool?
    var deleted_at: Double?
}

struct Artifact: Codable, Hashable, Identifiable {
    let rel: String
    let name: String
    let ext: String
    let kind: String          // html, pdf, image, svg, markdown, text, code
    let size: Int?
    let mtime: Double?
    var id: String { rel }
}

struct ArtifactList: Codable {
    let cwd: String?
    let artifacts: [Artifact]
}

struct RateLimit: Codable, Hashable {
    let status: String?
    let resetsAt: Double?
    let isUsingOverage: Bool?
    let at: Double?
}

struct ClaudeUsage: Codable {
    let five_hour: RateLimit?
    let seven_day: RateLimit?
    let updated: Double?
}

struct UsageInfo: Codable {
    let claude: ClaudeUsage?
}

struct Automation: Codable, Identifiable, Hashable {
    let name: String
    let kind: String
    let schedule: String
    let status: String
    let detail: String
    var id: String { name + "|" + kind }
}

// A phone-managed scheduled agent job (the harness daemon is the scheduler).
struct AutoSchedule: Codable, Hashable {
    var type: String            // "daily" | "interval"
    var hour: Int?
    var minute: Int?
    var minutes: Int?
}

struct ManagedAutomation: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var prompt: String
    var provider: String?
    var model: String?
    var effort: String?
    var cwd: String?
    var enabled: Bool
    var thread_id: String?
    var last_run: Double?
    var schedule: AutoSchedule
    var schedule_text: String?
}

struct AutomationsList: Codable {
    var managed: [ManagedAutomation]
    var system: [Automation]
}

struct ToolInfo: Codable, Hashable {
    let name: String
    let summary: String?
    var detail: String?
}

// A structured multiple-choice question Claude asked via its AskUserQuestion tool.
struct AskOption: Codable, Hashable {
    let label: String
    let description: String?
}

struct AskQuestion: Codable, Hashable {
    let question: String
    let header: String?
    let multiSelect: Bool?
    let options: [AskOption]

    enum CodingKeys: String, CodingKey { case question, header, multiSelect, options }
    init(from decoder: Decoder) throws {     // resilient: a malformed field never drops the question
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = (try? c.decode(String.self, forKey: .question)) ?? ""
        header = try? c.decodeIfPresent(String.self, forKey: .header)
        multiSelect = try? c.decodeIfPresent(Bool.self, forKey: .multiSelect)
        options = (try? c.decodeIfPresent([AskOption].self, forKey: .options)) ?? []
    }
}

struct Usage: Codable, Hashable {
    let cost: Double?
    let input_tokens: Int?
    let output_tokens: Int?
    let duration_ms: Double?
}

struct Message: Codable, Identifiable, Hashable {
    var id = UUID()
    let role: String
    let text: String
    var ts: Double?
    var tools: [ToolInfo]?
    var usage: Usage?
    var images: Int?
    var thinking: String?
    var questions: [AskQuestion]?
    enum CodingKeys: String, CodingKey { case role, text, ts, tools, usage, images, thinking, questions }
}

extension Message {
    // The server doesn't send an id, so derive a STABLE one from content — otherwise
    // every reload mints a fresh UUID and SwiftUI's ForEach diffing/animation breaks.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let role = try c.decode(String.self, forKey: .role)
        let text = try c.decode(String.self, forKey: .text)
        let ts = try c.decodeIfPresent(Double.self, forKey: .ts)
        self.init(role: role, text: text, ts: ts)
        self.tools = try c.decodeIfPresent([ToolInfo].self, forKey: .tools)
        self.usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
        self.images = try c.decodeIfPresent(Int.self, forKey: .images)
        self.thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        self.questions = try c.decodeIfPresent([AskQuestion].self, forKey: .questions)
        self.id = Message.stableID(role: role, ts: ts, text: text)
    }

    static func stableID(role: String, ts: Double?, text: String) -> UUID {
        let key = "\(role)|\(ts ?? 0)|\(text)"
        let b = Array(Insecure.MD5.hash(data: Data(key.utf8)))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

struct ThreadDetail: Codable, Identifiable {
    let id: String
    var title: String?
    var engine: String
    var provider: String
    var model: String?
    var cwd: String?
    var permission_mode: String?
    var effort: String?
    var session_id: String?
    var created: Double?
    var updated: Double?
    var total_cost: Double?
    var running: Bool?
    var messages: [Message]
}

// A gated tool use waiting for the user's Allow/Deny (Ask mode).
struct PendingApproval: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String?
}

// One SSE event from POST /threads/{id}/messages
struct StreamEvent: Decodable {
    let type: String
    let delta: String?
    let text: String?
    let name: String?
    let summary: String?
    let detail: String?
    let id: String?
    let session_id: String?
    let message: String?
    let tools: [ToolInfo]?
    let usage: Usage?
    let thinking: String?
    let questions: [AskQuestion]?
}
