import Foundation
import AuthenticationServices

// Google sign-in via Supabase + the harness-chat-web backend. The phone and the
// web app share one account: same chats, same memory, same OpenRouter key.
enum Backend {
    static let api = "https://harness-chat-web.vercel.app/api"
    static let supa = "https://kwcjxhjcsitgalinikal.supabase.co"
    static let anon = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt3Y2p4aGpjc2l0Z2FsaW5pa2FsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM0OTA1ODYsImV4cCI6MjA5OTA2NjU4Nn0.EVZvDD5LzQsEcQy6XjLvHXEYVmA0JIn7FVfP8H1tRLU"

    struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    static var session: Session? {
        get {
            guard let d = UserDefaults.standard.data(forKey: "supaSession") else { return nil }
            return try? JSONDecoder().decode(Session.self, from: d)
        }
        set {
            if let s = newValue, let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "supaSession") }
            else { UserDefaults.standard.removeObject(forKey: "supaSession") }
        }
    }

    static func handleCallback(_ url: URL) -> Bool {
        // harnesschat://auth#access_token=…&refresh_token=…&expires_in=…
        guard let frag = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else { return false }
        var p: [String: String] = [:]
        for pair in frag.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { p[String(kv[0])] = String(kv[1]).removingPercentEncoding }
        }
        guard let at = p["access_token"], let rt = p["refresh_token"] else { return false }
        session = Session(accessToken: at, refreshToken: rt,
                          expiresAt: Date().addingTimeInterval(Double(p["expires_in"] ?? "3600")! - 60))
        return true
    }

    static func signOut() { session = nil }

    static func token() async -> String? {
        guard var s = session else { return nil }
        if Date() > s.expiresAt {
            var req = URLRequest(url: URL(string: supa + "/auth/v1/token?grant_type=refresh_token")!)
            req.httpMethod = "POST"
            req.setValue(anon, forHTTPHeaderField: "apikey")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": s.refreshToken])
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let at = j["access_token"] as? String, let rt = j["refresh_token"] as? String
            else { session = nil; return nil }
            s = Session(accessToken: at, refreshToken: rt,
                        expiresAt: Date().addingTimeInterval(((j["expires_in"] as? Double) ?? 3600) - 60))
            session = s
        }
        return s.accessToken
    }

    static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (Data, Int) {
        guard let t = await token() else { throw NSError(domain: "auth", code: 401, userInfo: [NSLocalizedDescriptionKey: "signed out"]) }
        var req = URLRequest(url: URL(string: api + path)!)
        req.httpMethod = method
        req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let b = body { req.httpBody = try JSONSerialization.data(withJSONObject: b) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // Guest mode: no account — call OpenRouter directly with a locally-stored key.
    // guest-mode vision bridge: a vision model describes images for a text-only model
    static func describeImages(_ urls: [String], key: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var parts: [[String: Any]] = [["type": "text", "text": "Describe the attached image(s) exhaustively for a text-only AI that must answer questions about them. Transcribe ALL visible text verbatim, describe layout, charts with their values, people, objects, and colors. Organized, no preamble."]]
        parts += urls.map { ["type": "image_url", "image_url": ["url": $0]] }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "google/gemini-3.1-flash-lite", "max_tokens": 2000,
            "messages": [["role": "user", "content": parts]],
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ch = (obj["choices"] as? [[String: Any]])?.first,
              let msg = ch["message"] as? [String: Any],
              let desc = msg["content"] as? String, !desc.isEmpty else {
            throw NSError(domain: "bridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "no description"])
        }
        return "\n\n[Attached image(s), auto-described by a vision model because this model cannot see images:]\n" + desc
    }

    static func directStream(model: String, messages: [[String: Any]], effort: String?, key: String) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "messages": messages, "stream": true,
                                   "max_tokens": 8000, "usage": ["include": true]]
        if let e = effort { body["reasoning"] = ["effort": e] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 300 {
            var err = ""
            for try await line in bytes.lines { err += line; if err.count > 400 { break } }
            throw NSError(domain: "or", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(err.prefix(200))"])
        }
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { continue }
                        guard let d = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                        var ev = StreamEvent()
                        if let u = obj["usage"] as? [String: Any] {
                            ev.cost = u["cost"] as? Double
                            ev.promptTokens = u["prompt_tokens"] as? Int
                        }
                        if let ch = (obj["choices"] as? [[String: Any]])?.first,
                           let delta = ch["delta"] as? [String: Any],
                           let text = delta["content"] as? String, !text.isEmpty { ev.text = text }
                        if ev.text != nil || ev.cost != nil { cont.yield(ev) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // the OpenRouter catalog is public — guests get the model list keylessly
    static func publicModels() async -> [ORModel] {
        guard let (data, _) = try? await URLSession.shared.data(from: URL(string: "https://openrouter.ai/api/v1/models")!) else { return [] }
        struct Raw: Codable {
            struct M: Codable {
                let id: String; let name: String?; let context_length: Int?
                struct P: Codable { let prompt: String?; let completion: String? }
                let pricing: P?
                struct A: Codable { let input_modalities: [String]? }
                let architecture: A?
                let supported_parameters: [String]?
            }
            let data: [M]
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return [] }
        return raw.data.map {
            ORModel(id: $0.id, name: $0.name ?? $0.id, context: $0.context_length ?? 0,
                    promptPrice: Double($0.pricing?.prompt ?? "0") ?? 0,
                    completionPrice: Double($0.pricing?.completion ?? "0") ?? 0,
                    vision: $0.architecture?.input_modalities?.contains("image") ?? false,
                    reasoning: $0.supported_parameters?.contains("reasoning") ?? false,
                    tools: $0.supported_parameters?.contains("tools") ?? false)
        }.sorted { $0.id < $1.id }
    }

    struct MediaModel: Identifiable, Hashable { let id: String; let name: String }
    // image/video generators are EXCLUDED from the default /models list — fetch by output modality
    static func mediaModels(kind: String) async -> [MediaModel] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=" + kind),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return MediaModel(id: id, name: (m["name"] as? String) ?? id)
        }.sorted { $0.name < $1.name }
    }

    struct StreamEvent {
        var text: String?; var cost: Double?; var promptTokens: Int?
        var toolRun: String?; var toolDone: String?
        var file: FileSpec?; var serverError: String?
        var exec: ExecSpec?
        var bridged: [(Int, String)]?
    }

    // App Store 5.1.1(v): full in-app account deletion (wipes chats, memories, profile, auth user)
    static func deleteAccount() async throws {
        guard let t = await token() else { throw NSError(domain: "auth", code: 401, userInfo: [NSLocalizedDescriptionKey: "signed out"]) }
        var req = URLRequest(url: URL(string: api + "/delete-account")!)
        req.httpMethod = "POST"
        req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NSError(domain: "del", code: 1, userInfo: [NSLocalizedDescriptionKey: msg ?? "deletion failed — try again"])
        }
    }

    static func chatStream(model: String, messages: [[String: Any]], effort: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let t = await token() else { throw NSError(domain: "auth", code: 401, userInfo: [NSLocalizedDescriptionKey: "signed out"]) }
        var req = URLRequest(url: URL(string: api + "/chat")!)
        req.httpMethod = "POST"
        req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "messages": messages]
        if let e = effort { body["effort"] = e }
        if let im = UserDefaults.standard.string(forKey: "imageModel"), !im.isEmpty { body["imageModel"] = im }
        if let vm = UserDefaults.standard.string(forKey: "videoModel"), !vm.isEmpty { body["videoModel"] = vm }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 402 { throw NSError(domain: "key", code: 402, userInfo: [NSLocalizedDescriptionKey: "add your OpenRouter key in Settings first"]) }
        if code >= 300 {
            var err = ""
            for try await line in bytes.lines { err += line; if err.count > 400 { break } }
            throw NSError(domain: "api", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(err.prefix(200))"])
        }
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { continue }
                        guard let d = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                        var ev = StreamEvent()
                        if let h = obj["harness"] as? [String: Any] {
                            if let err = h["error"] as? String { ev.serverError = err }
                            if let tool = h["tool"] as? String, tool == "web_search" {
                                let detail = (h["detail"] as? String) ?? ""
                                if (h["status"] as? String) == "run" { ev.toolRun = detail } else { ev.toolDone = detail }
                            }
                            if let f = h["file"], let fd = try? JSONSerialization.data(withJSONObject: f),
                               let spec = try? JSONDecoder().decode(FileSpec.self, from: fd) { ev.file = spec }
                            if let x = h["exec"] as? [String: Any], let code = x["code"] as? String {
                                ev.exec = ExecSpec(language: (x["language"] as? String) ?? "python", code: code)
                            }
                            if let bs = h["bridged"] as? [[String: Any]] {
                                ev.bridged = bs.compactMap { b in
                                    guard let i = b["i"] as? Int, let d = b["desc"] as? String else { return nil }
                                    return (i, d)
                                }
                            }
                            cont.yield(ev)
                            continue
                        }
                        if let u = obj["usage"] as? [String: Any] {
                            ev.cost = u["cost"] as? Double
                            ev.promptTokens = u["prompt_tokens"] as? Int
                        }
                        if let ch = (obj["choices"] as? [[String: Any]])?.first,
                           let delta = ch["delta"] as? [String: Any],
                           let text = delta["content"] as? String, !text.isEmpty { ev.text = text }
                        if ev.text != nil || ev.cost != nil { cont.yield(ev) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

// ASWebAuthenticationSession wrapper for the Google flow. Supabase redirects to
// the allow-listed web origin's /mobile-auth.html, which bounces the tokens back
// into the app via the harnesschat:// scheme.
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleSignIn()
    private var session: ASWebAuthenticationSession?

    func start(completion: @escaping (Bool) -> Void) {
        let redirect = "https://harness-chat-web.vercel.app/mobile-auth.html"
        let url = URL(string: Backend.supa + "/auth/v1/authorize?provider=google&redirect_to=" +
                      redirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "harnesschat") { cb, _ in
            completion(cb.flatMap { Backend.handleCallback($0) } ?? false)
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        s.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
