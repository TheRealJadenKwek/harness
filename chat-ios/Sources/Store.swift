import Foundation
import SwiftUI
import UIKit

@MainActor
final class Store: ObservableObject {
    @Published var chats: [Chat] = []
    @Published var models: [ORModel] = []
    @Published var favorites: Set<String> = []
    @Published var authed = Backend.session != nil
    @Published var live: Set<String> = []          // chat ids currently streaming (parallel)
    @Published var profile: Profile? = nil
    @Published var errors: [String: String] = [:]  // chat id → last error
    @Published var toolStatus: [String: String] = [:]  // chat id → live tool line
    @AppStorage("defaultModel") var defaultModel = "minimax/minimax-m3"

    private var tasks: [String: Task<Void, Never>] = [:]
    private var pushTimers: [String: Task<Void, Never>] = [:]

    private var chatsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chats.json")
    }

    init() {
        if let d = try? Data(contentsOf: chatsURL),
           let saved = try? JSONDecoder().decode([Chat].self, from: d) { chats = saved }
        if let favs = UserDefaults.standard.array(forKey: "favModels") as? [String] { favorites = Set(favs) }
        if authed { Task { await bootSync() } }
    }

    func bootSync() async {
        await loadProfile()
        await loadModels()
        await syncPull()
    }

    func signedIn() { authed = true; Task { await bootSync() } }
    func signOut() {
        for (_, t) in tasks { t.cancel() }
        tasks = [:]; live = []
        Backend.signOut()
        authed = false
        chats = []; persist()
        profile = nil
    }

    func persist() { if let d = try? JSONEncoder().encode(chats) { try? d.write(to: chatsURL) } }

    func loadProfile() async {
        if let (d, code) = try? await Backend.request("/profile"), code == 200 {
            profile = try? JSONDecoder().decode(Profile.self, from: d)
        }
    }

    func loadModels() async {
        struct R: Codable { var models: [ORModel] }
        if let (d, code) = try? await Backend.request("/models"), code == 200,
           let r = try? JSONDecoder().decode(R.self, from: d) {
            models = r.models.sorted { $0.id < $1.id }
        }
    }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favModels")
    }

    // ---------------------------------------------------------------- sync
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func parseDate(_ s: String?) -> Date {
        guard let s else { return .distantPast }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? .distantPast
    }

    func syncPull() async {
        guard let (d, code) = try? await Backend.request("/sync"), code == 200,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let remote = obj["chats"] as? [[String: Any]] else { return }
        for rc in remote {
            guard let id = rc["id"] as? String else { continue }
            if live.contains(id) { continue }   // never clobber a streaming chat
            let updated = Store.parseDate(rc["updated"] as? String)
            let localIdx = chats.firstIndex { $0.id == id }
            if let i = localIdx, chats[i].updated >= updated { continue }
            var c = Chat(model: (rc["model"] as? String) ?? defaultModel)
            c.id = id
            c.title = (rc["title"] as? String) ?? "New chat"
            c.updated = updated
            if let msgs = rc["messages"], let md = try? JSONSerialization.data(withJSONObject: msgs),
               let parsed = try? JSONDecoder().decode([Msg].self, from: md) { c.messages = parsed }
            if let i = localIdx { chats[i] = c } else { chats.append(c) }
        }
        chats.sort { $0.updated > $1.updated }
        persist()
    }

    func syncPush(_ chat: Chat) {
        pushTimers[chat.id]?.cancel()
        pushTimers[chat.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            let msgs: [[String: Any]] = chat.messages.map { m in
                var d: [String: Any] = ["role": m.role, "content": m.content]
                if let ts = m.ts { d["ts"] = ts }
                if let im = m.images, !im.isEmpty { d["images"] = im }
                if let fs = m.files, !fs.isEmpty, let fd = try? JSONEncoder().encode(fs),
                   let arr = try? JSONSerialization.jsonObject(with: fd) { d["files"] = arr }
                if let tn = m.toolNotes, !tn.isEmpty { d["toolNotes"] = tn }
                return d
            }
            _ = try? await Backend.request("/sync", method: "POST", body: ["chat": [
                "id": chat.id, "title": chat.title, "model": chat.model, "messages": msgs,
            ] as [String: Any]])
            _ = self
        }
    }

    // ---------------------------------------------------------------- chats
    func newChat() -> Chat {
        let c = Chat(model: defaultModel)
        chats.insert(c, at: 0)
        persist()
        return c
    }

    func delete(_ chat: Chat) {
        stop(chat.id)
        chats.removeAll { $0.id == chat.id }
        persist()
        Task { _ = try? await Backend.request("/sync", method: "DELETE", body: ["id": chat.id]) }
    }

    func update(_ chat: Chat) {
        if let i = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[i] = chat
            chats.sort { $0.updated > $1.updated }
            persist()
        }
    }

    func chat(_ id: String) -> Chat? { chats.first { $0.id == id } }
    private func idx(_ id: String) -> Int? { chats.firstIndex { $0.id == id } }

    // ---------------------------------------------------------------- send (parallel per chat)
    func stop(_ chatID: String) {
        tasks[chatID]?.cancel()
        tasks[chatID] = nil
        live.remove(chatID)
    }

    func send(chatID: String, text: String, images: [String]) {
        guard let i = idx(chatID), !live.contains(chatID) else { return }
        let ts = ISO8601DateFormatter().string(from: .now)
        chats[i].messages.append(Msg(role: "user", content: text.isEmpty ? "What's in this image?" : text,
                                     images: images.isEmpty ? nil : images, ts: ts))
        if chats[i].title == "New chat" { chats[i].title = String((text.isEmpty ? "Photo" : text).prefix(42)) }
        chats[i].updated = .now
        errors[chatID] = nil
        persist()
        live.insert(chatID)
        let model = chats[i].model
        let effort = chats[i].effort
        tasks[chatID] = Task { [weak self] in
            await self?.runTurn(chatID: chatID, model: model, effort: effort)
        }
    }

    private func runTurn(chatID: String, model: String, effort: String?) async {
        defer { live.remove(chatID); tasks[chatID] = nil; if let c = chat(chatID) { syncPush(c) }; persist() }
        // context heavy → compact first (server model summarizes)
        if let c = chat(chatID), let ctx = c.ctxTokens,
           let limit = models.first(where: { $0.id == model })?.context, limit > 0,
           Double(ctx) > 0.7 * Double(limit) {
            await compact(chatID: chatID)
        }
        var acc = ""
        var appended = false
        do {
            if LocalModels.isLocal(model) {
                guard let c = chat(chatID) else { return }
                let think = UserDefaults.standard.object(forKey: "ondeviceThink") as? Bool ?? true
                for try await delta in LocalLLM.shared.stream(modelId: model, messages: c.messages, think: think) {
                    if Task.isCancelled { break }
                    acc += delta
                    appendDelta(chatID: chatID, acc: acc, appended: &appended)
                }
            } else {
                guard let c = chat(chatID) else { return }
                let msgs: [[String: Any]] = c.messages.map { m in
                    var d: [String: Any] = ["role": m.role, "content": m.content]
                    if let im = m.images, !im.isEmpty { d["images"] = im }
                    return d
                }
                for try await ev in try await Backend.chatStream(model: model, messages: msgs, effort: effort) {
                    if Task.isCancelled { break }
                    if let e = ev.serverError { throw NSError(domain: "api", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
                    if let q = ev.toolRun { toolStatus[chatID] = "searching: " + q }
                    if ev.toolDone != nil {
                        toolStatus[chatID] = nil
                        if !appended { appendDelta(chatID: chatID, acc: "", appended: &appended) }
                        if let i = idx(chatID), let last = chats[i].messages.indices.last {
                            var notes = chats[i].messages[last].toolNotes ?? []
                            notes.append("searched the web")
                            chats[i].messages[last].toolNotes = notes
                        }
                    }
                    if let f = ev.file {
                        if !appended { appendDelta(chatID: chatID, acc: acc, appended: &appended) }
                        if let i = idx(chatID), let last = chats[i].messages.indices.last {
                            var fs = chats[i].messages[last].files ?? []
                            fs.append(f)
                            chats[i].messages[last].files = fs
                        }
                    }
                    if let t = ev.text { acc += t; appendDelta(chatID: chatID, acc: acc, appended: &appended) }
                    if let i = idx(chatID) {
                        if let cost = ev.cost { chats[i].spend = (chats[i].spend ?? 0) + cost }
                        if let pt = ev.promptTokens { chats[i].ctxTokens = pt }
                    }
                }
            }
        } catch {
            if !(error is CancellationError) { errors[chatID] = error.localizedDescription }
        }
        toolStatus[chatID] = nil
        if let i = idx(chatID) {
            chats[i].updated = .now
            if appended, acc.isEmpty,
               let last = chats[i].messages.last, (last.files ?? []).isEmpty {
                chats[i].messages.removeLast()
            }
        }
        if !acc.isEmpty, let c = chat(chatID),
           let lastUser = c.messages.last(where: { $0.role == "user" }) {
            _ = try? await Backend.request("/memorize", method: "POST",
                                           body: ["user": lastUser.content, "assistant": String(acc.prefix(2000))])
        }
    }

    private func appendDelta(chatID: String, acc: String, appended: inout Bool) {
        guard let i = idx(chatID) else { return }
        if !appended {
            chats[i].messages.append(Msg(role: "assistant", content: acc, ts: ISO8601DateFormatter().string(from: .now)))
            appended = true
        } else {
            chats[i].messages[chats[i].messages.count - 1].content = acc
        }
    }

    private func compact(chatID: String) async {
        guard let c = chat(chatID) else { return }
        let msgs: [[String: Any]] = c.messages.map { ["role": $0.role, "content": $0.content] }
            + [["role": "user", "content": "Summarize our entire conversation so far for your own future reference: topics, key facts, decisions, drafts we worked on, and where we left off. Be complete but concise. Reply with ONLY the summary."]]
        var acc = ""
        if let stream = try? await Backend.chatStream(model: "deepseek/deepseek-v4-flash", messages: msgs, effort: nil) {
            do { for try await ev in stream { if let t = ev.text { acc += t } } } catch {}
        }
        guard !acc.isEmpty, let i = idx(chatID) else { return }
        let ts = ISO8601DateFormatter().string(from: .now)
        chats[i].messages = [
            Msg(role: "user", content: "✦ [The conversation above was automatically compacted. Summary:]\n\n" + acc, ts: ts),
            Msg(role: "assistant", content: "Got it — I have the full context from that summary and we can continue right where we left off.", ts: ts),
        ]
        chats[i].ctxTokens = 0
    }

    // ---------------------------------------------------------------- message actions
    func rewind(chatID: String, msgIndex: Int) -> String? {
        guard !live.contains(chatID), let i = idx(chatID), chats[i].messages.indices.contains(msgIndex) else { return nil }
        let text = chats[i].messages[msgIndex].content
        chats[i].messages = Array(chats[i].messages.prefix(msgIndex))
        chats[i].updated = .now
        persist()
        syncPush(chats[i])
        return text
    }

    func fork(chatID: String, msgIndex: Int?) -> Chat? {
        guard let src = chat(chatID) else { return nil }
        var f = src
        f.id = UUID().uuidString.lowercased()
        f.title = String((src.title + " (fork)").prefix(48))
        f.spend = nil; f.ctxTokens = nil
        if let m = msgIndex { f.messages = Array(src.messages.prefix(m)) }
        f.updated = .now
        chats.insert(f, at: 0)
        persist()
        syncPush(f)
        return f
    }

    // ---------------------------------------------------------------- memory + key
    func memories() async -> [MemoryFact] {
        struct R: Codable { var memories: [MemoryFact] }
        guard let (d, code) = try? await Backend.request("/memorize"), code == 200,
              let r = try? JSONDecoder().decode(R.self, from: d) else { return [] }
        return r.memories
    }
    func deleteMemory(_ id: Int) async { _ = try? await Backend.request("/memorize", method: "DELETE", body: ["id": id]) }
    func saveKey(_ key: String) async -> String? {
        guard let (d, code) = try? await Backend.request("/profile", method: "POST", body: ["key": key]) else { return "network error" }
        if code == 200 { await loadProfile(); await loadModels(); return nil }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String ?? "could not save"
    }
}
