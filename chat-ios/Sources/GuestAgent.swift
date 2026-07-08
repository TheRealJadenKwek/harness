import Foundation

// Phone-side agentic tool loop for guest mode (direct-to-OpenRouter, no account).
// Ports api/chat.js: stream a round, assemble tool_call fragments, execute the
// tools ON THIS DEVICE, feed results back, repeat. run_code returns its output
// inline (no stop-and-resume like the server path needs).
enum GuestAgent {
    static let maxRounds = 6

    static let system = """
    You are Harness, the user's personal assistant — warm, sharp, and quick. Be direct and genuinely useful.

    You have tools. Use web_search for current information, then fetch_page to actually read a promising result (search snippets alone are shallow — read before you summarize or cite). Use generate_image when asked to draw or create a picture (billed to the user's key). Use run_code for calculations or data analysis — it executes on the user's device and returns the output directly. Use create_file whenever the user wants a document, spreadsheet, presentation, web page, game, or any file: deliver a real artifact instead of pasting long content into the chat, then briefly say what you made.
    """

    static func toolsJSON(imageModel: String) -> [[String: Any]] {
        func fn(_ name: String, _ desc: String, _ props: [String: Any], _ req: [String]) -> [String: Any] {
            ["type": "function", "function": ["name": name, "description": desc,
                "parameters": ["type": "object", "properties": props, "required": req]]]
        }
        return [
            fn("web_search",
               "Search the web (DuckDuckGo). Returns top results as {title, url, snippet}. Use for anything current: news, prices, facts you are unsure of, links.",
               ["query": ["type": "string"]], ["query"]),
            fn("fetch_page",
               "Fetch a web page and return its readable text (title + ~12k chars). Use after web_search to actually READ a promising result, or when the user gives you a URL.",
               ["url": ["type": "string"]], ["url"]),
            fn("generate_image",
               "Generate an image from a text prompt using " + imageModel + " (billed to the user's key). The image is shown to the user as a card.",
               ["prompt": ["type": "string"]], ["prompt"]),
            fn("run_code",
               "Execute code on the user's device and return the output directly. language \"python\" (scientific stack available) or \"javascript\".",
               ["language": ["type": "string", "enum": ["python", "javascript"]], "code": ["type": "string"]], ["language", "code"]),
            fn("create_file",
               "Create a downloadable file for the user. kind \"text\" (any single plain-text file: .txt/.md/.csv/code) needs {filename, content}. kind \"html\" (a web page, game, or interactive app — the user gets a live in-app preview; make it fully self-contained, inline CSS/JS) needs {filename, content}. kind \"zip\" (multi-file projects) needs {filename, files:[{path, content}]}. kind \"pdf\" needs {filename, title, body}. kind \"xlsx\" needs {filename, sheets:[{name, rows:[[cell,…],…]}]} — first row is the header. kind \"pptx\" needs {filename, slides:[{title, bullets:[…], notes?}]}. Prefer this over pasting long content into chat.",
               ["kind": ["type": "string", "enum": ["text", "html", "zip", "pdf", "xlsx", "pptx"]],
                "filename": ["type": "string"], "content": ["type": "string"],
                "title": ["type": "string"], "body": ["type": "string"],
                "files": ["type": "array", "items": ["type": "object", "properties": ["path": ["type": "string"], "content": ["type": "string"]], "required": ["path", "content"]]],
                "sheets": ["type": "array", "items": ["type": "object", "properties": ["name": ["type": "string"], "rows": ["type": "array", "items": ["type": "array"]]]]],
                "slides": ["type": "array", "items": ["type": "object", "properties": ["title": ["type": "string"], "bullets": ["type": "array", "items": ["type": "string"]], "notes": ["type": "string"]]]]],
               ["kind", "filename"]),
        ]
    }

    static func stream(model: String, messages: [[String: Any]], effort: String?, key: String) -> AsyncThrowingStream<Backend.StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let imageModel = UserDefaults.standard.string(forKey: "imageModel").flatMap { $0.isEmpty ? nil : $0 } ?? "google/gemini-3.1-flash-image"
                    var convo: [[String: Any]] = [["role": "system", "content": system]] + messages
                    let tools = toolsJSON(imageModel: imageModel)

                    for _ in 0..<maxRounds {
                        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
                        req.httpMethod = "POST"
                        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        var body: [String: Any] = ["model": model, "messages": convo, "stream": true,
                                                   "max_tokens": 8000, "usage": ["include": true], "tools": tools]
                        if let e = effort { body["reasoning"] = ["effort": e] }
                        req.httpBody = try JSONSerialization.data(withJSONObject: body)

                        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        if code >= 300 {
                            var err = ""
                            for try await line in bytes.lines { err += line; if err.count > 400 { break } }
                            throw NSError(domain: "or", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(err.prefix(200))"])
                        }

                        var content = ""
                        // tool_call fragments accumulate by index across SSE deltas
                        var calls: [Int: (id: String, name: String, args: String)] = [:]
                        for try await line in bytes.lines {
                            if Task.isCancelled { cont.finish(); return }
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { continue }
                            guard let d = payload.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                            var ev = Backend.StreamEvent()
                            if let u = obj["usage"] as? [String: Any] {
                                ev.cost = u["cost"] as? Double
                                ev.promptTokens = u["prompt_tokens"] as? Int
                            }
                            if let ch = (obj["choices"] as? [[String: Any]])?.first,
                               let delta = ch["delta"] as? [String: Any] {
                                if let text = delta["content"] as? String, !text.isEmpty { ev.text = text; content += text }
                                if let tcs = delta["tool_calls"] as? [[String: Any]] {
                                    for tc in tcs {
                                        let i = (tc["index"] as? Int) ?? 0
                                        var cur = calls[i] ?? (id: "", name: "", args: "")
                                        if let cid = tc["id"] as? String { cur.id += cid }
                                        if let f = tc["function"] as? [String: Any] {
                                            if let n = f["name"] as? String { cur.name += n }
                                            if let a = f["arguments"] as? String { cur.args += a }
                                        }
                                        calls[i] = cur
                                    }
                                }
                            }
                            if ev.text != nil || ev.cost != nil { cont.yield(ev) }
                        }

                        if calls.isEmpty { break }   // no tools requested — turn is done

                        let ordered = calls.sorted { $0.key < $1.key }.map { $0.value }
                        convo.append(["role": "assistant", "content": content,
                                      "tool_calls": ordered.map { ["id": $0.id, "type": "function",
                                                                   "function": ["name": $0.name, "arguments": $0.args]] }])
                        for call in ordered {
                            if Task.isCancelled { cont.finish(); return }
                            let args = (try? JSONSerialization.jsonObject(with: Data(call.args.utf8)) as? [String: Any]) ?? [:]
                            var run = Backend.StreamEvent(); run.toolRun = label(call.name, args); cont.yield(run)
                            let result = await execute(call.name, args: args, key: key, imageModel: imageModel, cont: cont)
                            var done = Backend.StreamEvent(); done.toolDone = label(call.name, args); cont.yield(done)
                            convo.append(["role": "tool", "tool_call_id": call.id, "content": String(result.prefix(30000))])
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private static func label(_ name: String, _ args: [String: Any]) -> String {
        switch name {
        case "web_search": return "searched: " + ((args["query"] as? String) ?? "")
        case "fetch_page": return "read " + ((args["url"] as? String) ?? "a page")
        case "generate_image": return "generated an image"
        case "run_code": return "ran " + ((args["language"] as? String) ?? "code")
        case "create_file": return "created " + ((args["filename"] as? String) ?? "a file")
        default: return name
        }
    }

    private static func execute(_ name: String, args: [String: Any], key: String, imageModel: String,
                                cont: AsyncThrowingStream<Backend.StreamEvent, Error>.Continuation) async -> String {
        switch name {
        case "web_search":
            return await webSearch((args["query"] as? String) ?? "")
        case "fetch_page":
            return await fetchPage((args["url"] as? String) ?? "")
        case "generate_image":
            do {
                let dataUrl = try await generateImage(prompt: (args["prompt"] as? String) ?? "", model: imageModel, key: key)
                var ev = Backend.StreamEvent()
                ev.file = FileSpec(kind: "image", filename: "image.png", content: nil, title: nil, body: nil,
                                   sheets: nil, slides: nil, files: nil, dataUrl: dataUrl)
                cont.yield(ev)
                return "image generated and shown to the user as a card"
            } catch { return "Error: " + error.localizedDescription }
        case "run_code":
            let lang = (args["language"] as? String) ?? "python"
            let code = (args["code"] as? String) ?? ""
            let out = await WebArtifactBuilder.shared.runCode(language: lang, code: code)
            var ev = Backend.StreamEvent()
            ev.exec = ExecSpec(language: lang, code: code, output: out)
            cont.yield(ev)
            return out
        case "create_file":
            guard let d = try? JSONSerialization.data(withJSONObject: args),
                  let spec = try? JSONDecoder().decode(FileSpec.self, from: d) else { return "Error: bad file spec" }
            var ev = Backend.StreamEvent(); ev.file = spec; cont.yield(ev)
            return "file \"" + spec.filename + "\" created and shown to the user"
        default:
            return "Error: unknown tool " + name
        }
    }

    // ---- tool implementations ----

    private static func strip(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func webSearch(_ q: String) async -> String {
        var req = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (iPhone) HarnessChat", forHTTPHeaderField: "User-Agent")
        req.httpBody = ("q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)).data(using: .utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let body = String(data: data, encoding: .utf8) else { return "{\"error\":\"search failed\"}" }
        var results: [[String: String]] = []
        let re = try! NSRegularExpression(
            pattern: "<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>[\\s\\S]*?class=\"result__snippet\"[^>]*>([\\s\\S]*?)</a>")
        let ns = body as NSString
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)).prefix(8) {
            var url = ns.substring(with: m.range(at: 1))
            if let r = url.range(of: "uddg=") {
                var enc = String(url[r.upperBound...])
                if let amp = enc.firstIndex(of: "&") { enc = String(enc[..<amp]) }
                url = enc.removingPercentEncoding ?? url
            }
            results.append(["title": strip(ns.substring(with: m.range(at: 2))),
                            "url": url,
                            "snippet": String(strip(ns.substring(with: m.range(at: 3))).prefix(300))])
        }
        guard !results.isEmpty else { return "{\"error\":\"no results\"}" }
        let out = try? JSONSerialization.data(withJSONObject: ["query": q, "results": results])
        return out.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\":\"encode failed\"}"
    }

    static func fetchPage(_ urlStr: String) async -> String {
        guard let url = URL(string: urlStr), ["http", "https"].contains(url.scheme ?? "") else { return "Error: bad url" }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Mozilla/5.0 (iPhone) HarnessChat", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return "Error: fetch failed"
        }
        let title = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: .regularExpression)
            .map { strip(String(html[$0])) } ?? ""
        let cleaned = html
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: [.regularExpression, .caseInsensitive])
        return (title.isEmpty ? "" : title + "\n\n") + String(strip(cleaned).prefix(12000))
    }

    static func generateImage(prompt: String, model: String, key: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": [["role": "user", "content": String(prompt.prefix(2000))]],
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ch = (obj["choices"] as? [[String: Any]])?.first,
              let msg = ch["message"] as? [String: Any],
              let imgs = msg["images"] as? [[String: Any]],
              let first = imgs.first?["image_url"] as? [String: Any],
              let dataUrl = first["url"] as? String, dataUrl.hasPrefix("data:image/") else {
            throw NSError(domain: "img", code: 1, userInfo: [NSLocalizedDescriptionKey: "no image in response"])
        }
        return dataUrl
    }
}
