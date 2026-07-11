import Foundation

enum HarnessError: LocalizedError {
    case badURL
    case http(Int)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid server URL"
        case .http(let c): return "Server returned HTTP \(c)"
        case .message(let m): return m
        }
    }
}

struct HarnessAPI {
    var baseURL: String
    var token: String

    private func makeRequest(_ path: String, method: String = "GET", json: [String: Any]? = nil) throws -> URLRequest {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmed + path) else { throw HarnessError.badURL }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 60
        if !token.isEmpty {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    private func decode<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HarnessError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func health() async throws -> Bool {
        let (data, resp) = try await URLSession.shared.data(for: try makeRequest("/health"))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["ok"] as? Bool) ?? false
    }

    func pushConfigured() async throws -> Bool {
        let (data, resp) = try await URLSession.shared.data(for: try makeRequest("/health"))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["push_configured"] as? Bool) ?? false
    }

    func registerPush(token: String) async throws {
        let (_, resp) = try await URLSession.shared.data(for: try makeRequest("/push/register", method: "POST", json: ["token": token]))
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HarnessError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)   // throw -> caller retries on next connect
        }
    }

    func unregisterPush(token: String) async throws {
        _ = try await URLSession.shared.data(for: try makeRequest("/push/unregister", method: "POST", json: ["token": token]))
    }

    func providers() async throws -> [Provider] {
        try await decode(try makeRequest("/providers"), as: [Provider].self)
    }

    /// Live, searchable model catalog for a provider (all of OpenRouter, etc.); falls back
    /// to the provider's static list server-side.
    func providerModels(_ id: String) async throws -> [ModelOption] {
        try await decode(try makeRequest("/providers/\(id)/models"), as: [ModelOption].self)
    }

    func threads(view: String? = nil) async throws -> [ThreadSummary] {
        let path = (view == nil) ? "/threads" : "/threads?view=\(view!)"
        return try await decode(try makeRequest(path), as: [ThreadSummary].self)
    }

    func trash() async throws -> [ThreadSummary] {
        try await decode(try makeRequest("/trash"), as: [ThreadSummary].self)
    }

    func archive(_ id: String, archived: Bool) async throws {
        _ = try await URLSession.shared.data(for: try makeRequest("/threads/\(id)/archive", method: "POST", json: ["archived": archived]))
    }

    func restore(_ id: String) async throws {
        _ = try await URLSession.shared.data(for: try makeRequest("/threads/\(id)/restore", method: "POST"))
    }

    func deletePermanent(_ id: String) async throws {
        _ = try await URLSession.shared.data(for: try makeRequest("/trash/\(id)", method: "DELETE"))
    }

    func automations() async throws -> AutomationsList {
        try await decode(try makeRequest("/automations"), as: AutomationsList.self)
    }

    func createAutomation(_ body: [String: Any]) async throws -> ManagedAutomation {
        try await decode(try makeRequest("/automations", method: "POST", json: body),
                         as: ManagedAutomation.self)
    }

    func updateAutomation(_ id: String, _ body: [String: Any]) async throws -> ManagedAutomation {
        try await decode(try makeRequest("/automations/\(id)", method: "POST", json: body),
                         as: ManagedAutomation.self)
    }

    func deleteAutomation(_ id: String) async throws {
        _ = try await URLSession.shared.data(for: try makeRequest("/automations/\(id)", method: "DELETE"))
    }

    private struct AutoRunResult: Decodable { let thread_id: String }
    /// Fire an automation immediately; returns the thread id the run landed in.
    func runAutomation(_ id: String) async throws -> String {
        try await decode(try makeRequest("/automations/\(id)/run", method: "POST"),
                         as: AutoRunResult.self).thread_id
    }

    func usage() async throws -> UsageInfo {
        try await decode(try makeRequest("/usage"), as: UsageInfo.self)
    }

    func artifacts(_ id: String) async throws -> ArtifactList {
        try await decode(try makeRequest("/threads/\(id)/artifacts"), as: ArtifactList.self)
    }

    func devServers(_ id: String) async throws -> [DevServer] {
        try await decode(try makeRequest("/threads/\(id)/devservers"), as: [DevServer].self)
    }

    /// Token'd download of a thread file to a temp URL (for QuickLook / share).
    func downloadFile(_ id: String, rel: String) async throws -> URL {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        var comps = URLComponents(string: trimmed + "/threads/\(id)/file")
        comps?.queryItems = [URLQueryItem(name: "path", value: rel)]
        guard let url = comps?.url else { throw HarnessError.badURL }
        var req = URLRequest(url: url)
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HarnessError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // give it the real filename + extension so QuickLook/Share pick the right type
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let named = dest.appendingPathComponent((rel as NSString).lastPathComponent)
        try? FileManager.default.removeItem(at: named)
        try FileManager.default.moveItem(at: tmp, to: named)
        return named
    }

    func thread(_ id: String) async throws -> ThreadDetail {
        try await decode(try makeRequest("/threads/\(id)"), as: ThreadDetail.self)
    }

    func createThread(provider: String, cwd: String?, title: String?, permissionMode: String?, effort: String?, model: String?) async throws -> ThreadDetail {
        var body: [String: Any] = ["provider": provider]
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        if let title, !title.isEmpty { body["title"] = title }
        if let permissionMode { body["permission_mode"] = permissionMode }
        if let effort { body["effort"] = effort }
        if let model, !model.isEmpty { body["model"] = model }
        return try await decode(try makeRequest("/threads", method: "POST", json: body), as: ThreadDetail.self)
    }

    /// Branch a conversation — the fork resumes from the same point, then diverges.
    func fork(_ id: String, title: String? = nil) async throws -> ThreadDetail {
        var body: [String: Any] = [:]
        if let title, !title.isEmpty { body["title"] = title }
        return try await decode(try makeRequest("/threads/\(id)/fork", method: "POST", json: body),
                                as: ThreadDetail.self)
    }

    func rename(_ id: String, title: String) async throws {
        _ = try await URLSession.shared.data(for: try makeRequest("/threads/\(id)/rename", method: "POST", json: ["title": title]))
    }

    func delete(_ id: String) async throws {
        _ = try await URLSession.shared.data(for: try makeRequest("/threads/\(id)", method: "DELETE"))
    }

    func stop(_ id: String) async throws {
        _ = try await URLSession.shared.data(for: try makeRequest("/threads/\(id)/stop", method: "POST"))
    }

    func desktopSessions(query: String = "") async throws -> [DesktopSession] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return try await decode(try makeRequest(q.isEmpty ? "/desktop/sessions" : "/desktop/sessions?q=\(q)"), as: [DesktopSession].self)
    }

    /// Bind a desktop CLI session to a new harness thread; the next message resumes it.
    func importDesktopSession(_ id: String, engine: String) async throws -> ThreadSummary {
        try await decode(try makeRequest("/desktop/import", method: "POST",
                                         json: ["id": id, "engine": engine]),
                         as: ThreadSummary.self)
    }

    struct HandoffResult: Decodable {
        let thread: ThreadSummary
        let draft: String
    }
    /// Continue a desktop session on the OTHER engine: new thread + a staged draft that
    /// feeds the source transcript in as context (nothing is sent until the user taps send).
    func handoffDesktopSession(_ id: String, engine: String) async throws -> HandoffResult {
        try await decode(try makeRequest("/desktop/handoff", method: "POST",
                                         json: ["id": id, "engine": engine]),
                         as: HandoffResult.self)
    }

    func registerActivity(_ id: String, token: String) async throws {
        _ = try await URLSession.shared.data(for: try makeRequest(
            "/threads/\(id)/activity", method: "POST", json: ["token": token]))
    }

    func pendingApprovals(_ id: String) async throws -> [PendingApproval] {
        try await decode(try makeRequest("/threads/\(id)/approvals"), as: [PendingApproval].self)
    }

    func decideApproval(_ id: String, approvalID: String, allow: Bool) async throws {
        _ = try await URLSession.shared.data(for: try makeRequest(
            "/threads/\(id)/approvals/\(approvalID)", method: "POST",
            json: ["decision": allow ? "allow" : "deny"]))
    }

    func setProvider(_ id: String, apiKey: String?, enabled: Bool?) async throws {
        var body: [String: Any] = [:]
        if let apiKey { body["api_key"] = apiKey }
        if let enabled { body["enabled"] = enabled }
        _ = try await URLSession.shared.data(for: try makeRequest("/providers/\(id)", method: "POST", json: body))
    }

    /// Streams SSE events from the harness for one message.
    func stream(threadID: String, text: String, provider: String?, cwd: String?, permissionMode: String?, effort: String?, model: String?, images: [String]?) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: Any] = ["text": text]
                    if let provider, !provider.isEmpty { body["provider"] = provider }
                    if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
                    if let permissionMode { body["permission_mode"] = permissionMode }
                    if let effort { body["effort"] = effort }
                    if let model { body["model"] = model }
                    if let images, !images.isEmpty { body["images"] = images }
                    var req = try makeRequest("/threads/\(threadID)/messages", method: "POST", json: body)
                    req.timeoutInterval = 300   // idle gaps happen mid-turn; server pings every 15s
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                        throw HarnessError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if let d = payload.data(using: .utf8),
                           let ev = try? JSONDecoder().decode(StreamEvent.self, from: d) {
                            continuation.yield(ev)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 1_860 * 1_000_000_000)   // overall cap (~31m)
                task.cancel()
            }
            continuation.onTermination = { _ in task.cancel(); watchdog.cancel() }
        }
    }

    /// Re-attach to a turn already running on the server (e.g. after reopening the app).
    /// Replays the buffered events then tails live. Yields nothing if no job is running.
    func reconnect(threadID: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try makeRequest("/threads/\(threadID)/stream")
                    req.timeoutInterval = 300   // idle gaps happen mid-turn; server pings every 15s
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                        throw HarnessError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }   // {"running":false} JSON => no data: lines
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if let d = payload.data(using: .utf8),
                           let ev = try? JSONDecoder().decode(StreamEvent.self, from: d) {
                            continuation.yield(ev)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 1_860 * 1_000_000_000)   // overall cap (~31m)
                task.cancel()
            }
            continuation.onTermination = { _ in task.cancel(); watchdog.cancel() }
        }
    }
}
