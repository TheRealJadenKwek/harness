import Foundation
import Security
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var chats: [Chat] = []
    @Published var models: [ORModel] = []
    @Published var apiKey: String = ""
    @Published var favorites: Set<String> = []
    @AppStorage("defaultModel") var defaultModel = "openai/gpt-3.5-turbo"

    private var chatsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chats.json")
    }
    private var keyFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("openrouter-key.txt")
    }

    init() {
        apiKey = Keychain.read() ?? ""
        // fallback: a key dropped into Documents (Files app / simulator container)
        if apiKey.isEmpty, let k = try? String(contentsOf: keyFileURL).trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            apiKey = k
            Keychain.write(k)
            try? FileManager.default.removeItem(at: keyFileURL)
        }
        if let d = try? Data(contentsOf: chatsURL),
           let saved = try? JSONDecoder().decode([Chat].self, from: d) {
            chats = saved
        }
        if let favs = UserDefaults.standard.array(forKey: "favModels") as? [String] {
            favorites = Set(favs)
        }
        Task { await loadModels() }
    }

    func saveKey(_ k: String) {
        apiKey = k.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.write(apiKey)
        Task { await loadModels() }
    }

    func persist() {
        if let d = try? JSONEncoder().encode(chats) { try? d.write(to: chatsURL) }
    }

    func loadModels() async {
        guard !apiKey.isEmpty else { return }
        if let m = try? await OpenRouter.fetchModels(key: apiKey) { models = m }
    }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favModels")
    }

    func newChat() -> Chat {
        let c = Chat(model: defaultModel)
        chats.insert(c, at: 0)
        persist()
        return c
    }

    func delete(_ chat: Chat) {
        chats.removeAll { $0.id == chat.id }
        persist()
    }

    func update(_ chat: Chat) {
        if let i = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[i] = chat
            chats.sort { $0.updated > $1.updated }
            persist()
        }
    }
}

enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "harness-chat",
        kSecAttrAccount as String: "openrouter",
    ]
    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func write(_ value: String) {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = value.data(using: .utf8)!
        SecItemAdd(q as CFDictionary, nil)
    }
}
