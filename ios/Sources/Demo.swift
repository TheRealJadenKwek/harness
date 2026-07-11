import Foundation

/// Offline Demo Mode: lets the app run with NO Mac harness (for App Review, external testers,
/// or a quick look) using canned threads, a simulated streaming reply, and a real artifact preview.
enum Demo {
    static var active = false

    private static func decode<T: Decodable>(_ json: String, _ type: T.Type) -> T {
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static let providers: [Provider] = decode("""
    [{"id":"claude","label":"Claude","engine":"claude","enabled":true,
      "default_model":"claude-opus-4-8",
      "models":[{"label":"Opus 4.8","value":"claude-opus-4-8"},{"label":"Sonnet 4.6","value":"claude-sonnet-4-6"}]},
     {"id":"codex","label":"Codex","engine":"codex","enabled":true,
      "default_model":"gpt-5.5",
      "models":[{"label":"GPT-5.5","value":"gpt-5.5"},{"label":"GPT-5.4","value":"gpt-5.4"}]}]
    """, [Provider].self)

    static let threads: [ThreadSummary] = decode("""
    [{"id":"demo-landing","engine":"claude","provider":"claude","title":"Build a landing page",
      "model":"Opus 4.8","updated":1781900000,"message_count":4,"last_role":"assistant",
      "last":"Done — landing.html is ready. Tap the preview icon to see it."},
     {"id":"demo-refactor","engine":"codex","provider":"codex","title":"Refactor the auth module",
      "model":"GPT-5.5","updated":1781890000,"message_count":3,"last_role":"assistant",
      "last":"Split AuthService into a token store + a session manager; tests pass."},
     {"id":"demo-async","engine":"claude","provider":"claude","title":"Explain Swift async/await",
      "model":"Opus 4.8","updated":1781880000,"message_count":2,"last_role":"assistant",
      "last":"async marks a function that can suspend; await is where it suspends."}]
    """, [ThreadSummary].self)

    private static let details: [String: ThreadDetail] = {
        let json = """
        {"demo-landing":{"id":"demo-landing","title":"Build a landing page","engine":"claude",
          "provider":"claude","model":"claude-opus-4-8","permission_mode":"bypass","effort":"high",
          "messages":[
            {"role":"user","text":"Build a clean landing page for a Q4 sales dashboard.","ts":1781900001},
            {"role":"assistant","text":"On it — I'll make a self-contained page with a stats row and a chart.","ts":1781900002,
             "thinking":"Single file, no build step. Dark theme, three KPI cards, an inline SVG sparkline so it needs no assets.",
             "tools":[{"name":"Write","summary":"landing.html","detail":"+ <!doctype html>\\n+ <h1>Q4 Dashboard</h1>\\n+ <div class=row>…three KPI cards…</div>\\n+ <svg class=chart>…</svg>"}]},
            {"role":"user","text":"Nice. Make the numbers blue.","ts":1781900003},
            {"role":"assistant","text":"Done — **landing.html** is ready, KPI numbers in blue.\\n\\nTap the preview icon (top-right) to see it rendered right here on your phone.","ts":1781900004,
             "usage":{"cost":0.031,"input_tokens":4200,"output_tokens":260,"duration_ms":5400}}
          ]},
         "demo-refactor":{"id":"demo-refactor","title":"Refactor the auth module","engine":"codex",
          "provider":"codex","model":"gpt-5.5","permission_mode":"bypass","effort":"xhigh",
          "messages":[
            {"role":"user","text":"AuthService.swift is doing too much. Split it up.","ts":1781890001},
            {"role":"assistant","text":"I split it into two focused types and kept the public API stable.","ts":1781890002,
             "thinking":"AuthService mixed token persistence with session lifecycle. Extract a TokenStore (keychain) and a SessionManager (refresh/expiry); AuthService becomes a thin facade.",
             "tools":[{"name":"Edit","summary":"AuthService.swift","detail":"- class AuthService { /* 320 lines */ }\\n+ final class TokenStore { … }\\n+ final class SessionManager { … }\\n+ final class AuthService { let tokens; let sessions }"}]},
            {"role":"assistant","text":"Split `AuthService` into a **TokenStore** (keychain I/O) and a **SessionManager** (refresh + expiry). Public API unchanged; the 9 existing tests pass.","ts":1781890003,
             "usage":{"cost":0.052,"input_tokens":11800,"output_tokens":410,"duration_ms":31200}}
          ]},
         "demo-async":{"id":"demo-async","title":"Explain Swift async/await","engine":"claude",
          "provider":"claude","model":"claude-opus-4-8","permission_mode":"plan","effort":"medium",
          "messages":[
            {"role":"user","text":"Explain Swift async/await simply.","ts":1781880001},
            {"role":"assistant","text":"**async** marks a function that can *pause*; **await** is the spot where it pauses to wait for a result, freeing the thread for other work.\\n\\n```swift\\nfunc load() async throws -> Data {\\n    let (data, _) = try await URLSession.shared.data(from: url)\\n    return data\\n}\\n```\\n\\nNo callbacks, no nesting — it reads top-to-bottom like normal code, but never blocks the thread while waiting.","ts":1781880002,
             "thinking":"Keep it to the two keywords + one tiny example; avoid actors/Task for a 'simply' ask.",
             "usage":{"cost":0.018,"input_tokens":2100,"output_tokens":190,"duration_ms":3100}}
          ]}}
        """
        return decode(json, [String: ThreadDetail].self)
    }()

    static func detail(_ id: String) -> ThreadDetail {
        details[id] ?? decode("{\"id\":\"\(id)\",\"engine\":\"claude\",\"provider\":\"claude\",\"messages\":[]}", ThreadDetail.self)
    }

    static func artifacts(_ id: String) -> [Artifact] {
        guard id == "demo-landing" else { return [] }
        return decode("""
        [{"rel":"landing.html","name":"landing.html","ext":".html","kind":"html","size":1180,"mtime":1781900004}]
        """, [Artifact].self)
    }

    /// The one previewable artifact, rendered in-app via loadHTMLString (no network).
    static let sampleHTML = """
    <!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
    <style>
    body{font-family:-apple-system,sans-serif;margin:0;background:#0f1115;color:#e8e8ea;padding:20px}
    .card{background:#171a21;border:1px solid #262a33;border-radius:18px;padding:24px;max-width:520px;margin:auto}
    h1{margin:0 0 4px;font-size:28px}.sub{color:#8b90a0;margin:0 0 20px}
    .row{display:flex;gap:14px;margin-bottom:20px}.stat{flex:1;background:#1f232c;border-radius:14px;padding:16px;text-align:center}
    .n{font-size:24px;font-weight:700;color:#4f8cff}.l{font-size:12px;color:#8b90a0;margin-top:4px}
    .chart{width:100%;height:90px;background:#1f232c;border-radius:14px;padding:10px;box-sizing:border-box}
    </style></head><body><div class=card>
    <h1>Q4 Dashboard</h1><p class=sub>Built by Claude — previewed on your phone</p>
    <div class=row><div class=stat><div class=n>$2.4M</div><div class=l>Revenue</div></div>
    <div class=stat><div class=n>+18%</div><div class=l>Growth</div></div>
    <div class=stat><div class=n>1,204</div><div class=l>Users</div></div></div>
    <svg viewBox="0 0 300 90" class=chart><polyline points="0,80 50,60 100,65 150,40 200,45 250,20 300,25" fill=none stroke="#4f8cff" stroke-width=3/></svg>
    </div></body></html>
    """

    // Simulated streaming reply when the user sends a message in demo mode.
    static let thinkingScript = "The user is in Demo Mode, so there's no Mac connected yet. I'll show what a live reply looks like and point them to Settings to connect for real."
    static let replyScript = """
    This is **Demo Mode** — the full Harness interface, with no Mac connected yet.

    In real use this streams live from the **Claude Code** or **Codex** CLI on your own Mac, so you get:

    - Live token streaming, with the reasoning shown above
    - A tool-activity timeline with red/green diffs of every change
    - On-phone preview of anything the agent builds — HTML, PDFs, images
    - A push when a long task finishes, even with the app closed

    ```bash
    # on your Mac, once:
    ./install.sh
    ```

    Open **Settings → ⚙️** and enter your Mac's address + token to go live.
    """

    static func chunks(_ s: String) -> [String] {
        // split into word-ish chunks (keep trailing spaces/newlines) for a natural stream
        var out: [String] = []
        var cur = ""
        for ch in s {
            cur.append(ch)
            if ch == " " || ch == "\n" { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
