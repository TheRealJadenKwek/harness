import Foundation
import Security

struct HarnessServer: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var token: String
}

// Keychain-backed store: the whole server list (tokens included) lives in one
// generic-password item, so credentials never sit in UserDefaults.
enum ServerStore {
    private static let service = "com.jadenkwek.harness"
    private static let account = "servers"

    static func load() -> [HarnessServer] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let servers = try? JSONDecoder().decode([HarnessServer].self, from: data) else { return [] }
        return servers
    }

    static func save(_ servers: [HarnessServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        let status = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
