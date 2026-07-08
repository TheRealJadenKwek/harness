import Foundation

struct Msg: Codable, Identifiable, Hashable {
    var id = UUID()
    var role: String        // "user" | "assistant"
    var content: String
    var images: [String]? = nil   // data URLs (vision input)
}

struct Chat: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String = "New chat"
    var model: String
    var messages: [Msg] = []
    var updated: Date = .now
}

struct ORModel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let context: Int
    let promptPrice: Double
    let completionPrice: Double
    let vision: Bool
}
