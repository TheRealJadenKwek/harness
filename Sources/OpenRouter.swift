import Foundation

enum OpenRouter {
    static let base = "https://openrouter.ai/api/v1"

    static func fetchModels(key: String) async throws -> [ORModel] {
        var req = URLRequest(url: URL(string: base + "/models")!)
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Raw: Codable {
            struct M: Codable {
                let id: String
                let name: String?
                let context_length: Int?
                struct P: Codable { let prompt: String?; let completion: String? }
                let pricing: P?
            }
            let data: [M]
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return raw.data.map {
            ORModel(id: $0.id, name: $0.name ?? $0.id, context: $0.context_length ?? 0,
                    promptPrice: Double($0.pricing?.prompt ?? "0") ?? 0,
                    completionPrice: Double($0.pricing?.completion ?? "0") ?? 0)
        }.sorted { $0.id < $1.id }
    }

    static func stream(model: String, messages: [Msg], key: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: URL(string: base + "/chat/completions")!)
                    req.httpMethod = "POST"
                    req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line; if errBody.count > 500 { break } }
                        throw NSError(domain: "openrouter", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errBody.prefix(300))"])
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let text = delta["content"] as? String, !text.isEmpty else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
