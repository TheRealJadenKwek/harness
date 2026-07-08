import Foundation

struct Msg: Codable, Identifiable, Hashable {
    var id = UUID()
    var role: String        // "user" | "assistant"
    var content: String
    var images: [String]? = nil   // data URLs (vision input)
    var ts: String? = nil         // ISO timestamp (web-compatible)
    var files: [FileSpec]? = nil  // downloads the model created
    var toolNotes: [String]? = nil
    var execs: [ExecSpec]? = nil  // code the model ran on this device
    var bridgeDesc: String? = nil // cached vision-bridge description for text-only models

    enum CodingKeys: String, CodingKey { case role, content, images, ts, files, toolNotes, execs, bridgeDesc }
    init(role: String, content: String, images: [String]? = nil, ts: String? = nil) {
        self.role = role; self.content = content; self.images = images; self.ts = ts
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? c.decode(String.self, forKey: .role)) ?? "user"
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        images = try? c.decodeIfPresent([String].self, forKey: .images)
        ts = try? c.decodeIfPresent(String.self, forKey: .ts)
        files = try? c.decodeIfPresent([FileSpec].self, forKey: .files)
        toolNotes = try? c.decodeIfPresent([String].self, forKey: .toolNotes)
        execs = try? c.decodeIfPresent([ExecSpec].self, forKey: .execs)
        bridgeDesc = try? c.decodeIfPresent(String.self, forKey: .bridgeDesc)
    }
}

// Chat ids are strings so chats created on the web (short ids) round-trip.
struct Chat: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString.lowercased()
    var title: String = "New chat"
    var model: String
    var messages: [Msg] = []
    var updated: Date = .now
    var effort: String? = nil
    var spend: Double? = nil
    var ctxTokens: Int? = nil
}

struct ORModel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let context: Int
    let promptPrice: Double
    let completionPrice: Double
    let vision: Bool
    var reasoning: Bool? = nil
    var tools: Bool? = nil
}

struct Profile: Codable {
    var email: String?
    var hasKey: Bool
    var keyTail: String?
    struct Spend: Codable { var usage: Double?; var limit: Double? }
    var spend: Spend?
}

struct MemoryFact: Codable, Identifiable {
    var id: Int
    var fact: String
    var created: String?
}

struct ExecSpec: Codable, Hashable {
    var language: String
    var code: String
    var output: String? = nil
}
