import Foundation
import Combine
import UIKit

@MainActor
final class AppState: ObservableObject {
    @Published var baseURL: String = ""      // active server's URL (persisted via ServerStore)
    @Published var token: String = ""        // active server's token (Keychain, never UserDefaults)
    @Published var servers: [HarnessServer] = []
    @Published var activeServerID: UUID?
    @Published var threads: [ThreadSummary] = []
    @Published var archivedThreads: [ThreadSummary] = []
    @Published var trashedThreads: [ThreadSummary] = []
    @Published var providers: [Provider] = []
    @Published var automations: [Automation] = []
    @Published var status: String = ""
    @Published var loading = false
    @Published var connected = false
    @Published var demoMode = false              // running on canned data, no Mac harness
    @Published var pushConfigured = false        // harness has APNs creds (from /health)
    @Published var pendingOpenThread: String?    // set to navigate into a thread (e.g. after create)
    @Published var pushEnabled: Bool {           // user's push intent (Settings toggle)
        didSet { UserDefaults.standard.set(pushEnabled, forKey: "pushEnabled") }
    }

    private var deviceToken: String?
    private var registeredToken: String?

    init() {
        pushEnabled = (UserDefaults.standard.object(forKey: "pushEnabled") as? Bool) ?? true
        servers = ServerStore.load()
        // Migrate the single-server era: URL + token used to live in UserDefaults.
        if servers.isEmpty, let legacy = UserDefaults.standard.string(forKey: "baseURL"), !legacy.isEmpty {
            servers = [HarnessServer(name: "My Mac", url: legacy,
                                     token: UserDefaults.standard.string(forKey: "token") ?? "")]
            ServerStore.save(servers)
        }
        UserDefaults.standard.removeObject(forKey: "baseURL")
        UserDefaults.standard.removeObject(forKey: "token")
        let savedID = UserDefaults.standard.string(forKey: "activeServerID")
        if let active = servers.first(where: { $0.id.uuidString == savedID }) ?? servers.first {
            baseURL = active.url
            token = active.token
            activeServerID = active.id
        }
        // Device token arrives from the AppDelegate; a notification tap deep-links a thread.
        NotificationCenter.default.addObserver(forName: .harnessPushToken, object: nil, queue: .main) { [weak self] note in
            guard let tok = note.object as? String else { return }
            Task { @MainActor in self?.onDeviceToken(tok) }
        }
        NotificationCenter.default.addObserver(forName: .harnessOpenThread, object: nil, queue: .main) { [weak self] note in
            guard let tid = note.object as? String else { return }
            Task { @MainActor in self?.pendingOpenThread = tid }
        }
    }

    /// Ask iOS for notification permission and register with APNs (only if the user wants push).
    func enablePush() {
        guard isConfigured, pushEnabled else { return }
        PushManager.requestAndRegister()
    }

    /// Settings toggle: turn push on (prompt + register) or off (stop server pushes to this device).
    func setPushEnabled(_ on: Bool) {
        pushEnabled = on
        if on {
            PushManager.requestAndRegister()          // shows the iOS prompt the first time
        } else {
            if let tok = registeredToken {
                let a = api
                Task { try? await a.unregisterPush(token: tok) }
                registeredToken = nil
            }
            UIApplication.shared.unregisterForRemoteNotifications()
        }
    }

    private func onDeviceToken(_ tok: String) {
        deviceToken = tok
        Task { await registerDeviceTokenIfNeeded() }
    }

    private func registerDeviceTokenIfNeeded() async {
        guard isConfigured, pushEnabled, let tok = deviceToken, tok != registeredToken else { return }
        do {
            try await api.registerPush(token: tok)
            registeredToken = tok
        } catch { /* will retry on next connect */ }
    }

    var isConfigured: Bool { !baseURL.isEmpty }
    var api: HarnessAPI { HarnessAPI(baseURL: baseURL, token: token) }
    var activeServer: HarnessServer? { servers.first { $0.id == activeServerID } }

    // ---- multi-server
    func switchTo(_ id: UUID) {
        guard let s = servers.first(where: { $0.id == id }) else { return }
        activeServerID = s.id
        UserDefaults.standard.set(s.id.uuidString, forKey: "activeServerID")
        baseURL = s.url
        token = s.token
        threads = []
        connected = false
        Task { await refresh() }
    }

    @discardableResult
    func addServer(name: String, url: String, token tok: String) -> UUID {
        let s = HarnessServer(name: name.isEmpty ? url : name, url: url, token: tok)
        servers.append(s)
        ServerStore.save(servers)
        return s.id
    }

    func removeServer(_ id: UUID) {
        servers.removeAll { $0.id == id }
        ServerStore.save(servers)
        if activeServerID == id {
            if let first = servers.first {
                switchTo(first.id)
            } else {
                activeServerID = nil
                baseURL = ""
                token = ""
                threads = []
                connected = false
            }
        }
    }

    /// Settings' inline URL/token fields edit the ACTIVE server (creating one if none).
    func updateActiveServer(url: String, token tok: String) {
        baseURL = url
        token = tok
        if let idx = servers.firstIndex(where: { $0.id == activeServerID }) {
            servers[idx].url = url
            servers[idx].token = tok
            ServerStore.save(servers)
        } else {
            let id = addServer(name: "My Mac", url: url, token: tok)
            activeServerID = id
            UserDefaults.standard.set(id.uuidString, forKey: "activeServerID")
        }
    }

    /// harness://pair?url=…&token=…&name=… — from the server's /pair QR (scanned or tapped).
    /// harness://thread/<id> — Live Activity / widget tap deep-links into that thread.
    func handlePair(_ u: URL) {
        guard u.scheme == "harness" else { return }
        if u.host == "thread" {
            let tid = u.lastPathComponent
            if !tid.isEmpty, tid != "/" { pendingOpenThread = tid }
            return
        }
        guard u.host == "pair",
              let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return }
        func q(_ n: String) -> String? { comps.queryItems?.first(where: { $0.name == n })?.value }
        guard let url = q("url"), !url.isEmpty else { return }
        // Same URL again = re-pair: update the existing entry instead of duplicating.
        if let idx = servers.firstIndex(where: { $0.url == url }) {
            servers[idx].token = q("token") ?? servers[idx].token
            ServerStore.save(servers)
            switchTo(servers[idx].id)
        } else {
            let id = addServer(name: q("name") ?? url, url: url, token: q("token") ?? "")
            switchTo(id)
        }
    }
    var enabledProviders: [Provider] { providers.filter { $0.enabled } }

    // Remembered defaults for new threads.
    var defaultProvider: String {
        get { UserDefaults.standard.string(forKey: "defaultProvider") ?? "claude" }
        set { UserDefaults.standard.set(newValue, forKey: "defaultProvider") }
    }
    var defaultPermission: String {
        get { UserDefaults.standard.string(forKey: "defaultPermission") ?? "bypass" }
        set { UserDefaults.standard.set(newValue, forKey: "defaultPermission") }
    }
    var defaultEffort: String {
        get { UserDefaults.standard.string(forKey: "defaultEffort") ?? "default" }
        set { UserDefaults.standard.set(newValue, forKey: "defaultEffort") }
    }

    func enterDemo() {
        Demo.active = true
        demoMode = true
        providers = Demo.providers
        threads = Demo.threads
        connected = true
        status = ""
    }

    func exitDemo() {
        Demo.active = false
        demoMode = false
        connected = false
        threads = []
        providers = []
    }

    func refresh() async {
        if demoMode {                            // canned data; never touch the network
            providers = Demo.providers
            threads = Demo.threads
            connected = true
            return
        }
        guard isConfigured else { return }
        loading = true
        defer { loading = false }
        do {
            let p = try await api.providers()
            let t = try await api.threads()
            providers = p
            threads = t
            status = ""
            connected = true
            LiveActivityManager.reconcile(running: Set(t.filter { $0.running == true }.map(\.id)))
            pushConfigured = (try? await api.pushConfigured()) ?? pushConfigured
            await registerDeviceTokenIfNeeded()       // (re)send token after a reconnect
        } catch {
            status = error.localizedDescription
            connected = false
        }
    }

    func rename(_ id: String, title: String) async {
        try? await api.rename(id, title: title)
        await refresh()
    }

    func setProvider(_ id: String, apiKey: String?, enabled: Bool?) async {
        try? await api.setProvider(id, apiKey: apiKey, enabled: enabled)
        await refresh()
    }

    func loadAutomations() async {
        automations = (try? await api.automations()) ?? []
    }

    // "New reply" dot: compare message counts (same source on both sides → no phone/Mac
    // clock skew). A thread is unseen if it now has more messages than when you last looked.
    func markSeen(_ id: String, count: Int) {
        UserDefaults.standard.set(count, forKey: "seen_\(id)")
    }
    func isUnseen(_ t: ThreadSummary) -> Bool {
        guard let seen = UserDefaults.standard.object(forKey: "seen_\(t.id)") as? Int else { return false }
        return (t.message_count ?? 0) > seen       // never-opened threads aren't flagged
    }

    func testConnection() async -> Bool {
        (try? await api.health()) ?? false
    }

    func createThread(provider: String, cwd: String?, title: String?, permissionMode: String?, effort: String?, model: String?) async throws -> ThreadDetail {
        let t = try await api.createThread(provider: provider, cwd: cwd, title: title, permissionMode: permissionMode, effort: effort, model: model)
        await refresh()
        return t
    }

    func delete(_ id: String) async {       // soft delete -> moves to Recently Deleted on the server
        try? await api.delete(id)
        await refresh()
    }

    func loadArchived() async { archivedThreads = (try? await api.threads(view: "archived")) ?? [] }
    func loadTrash() async { trashedThreads = (try? await api.trash()) ?? [] }

    func archive(_ id: String, _ archived: Bool) async {
        try? await api.archive(id, archived: archived)
        await refresh()
    }
    func restore(_ id: String) async {
        try? await api.restore(id)
        await refresh()
    }
    func deletePermanent(_ id: String) async {
        try? await api.deletePermanent(id)
    }
}
