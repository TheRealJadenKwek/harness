import SwiftUI
import WebKit
import QuickLook

// MARK: - Full-screen artifact previewer (swipe between artifacts)

struct PreviewView: View {
    let tid: String
    let artifacts: [Artifact]
    @State var index: Int
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var reload = UUID()
    @State private var shareURL: URL?
    @State private var devPort: Int?              // non-nil = browsing a live dev server
    @State private var devServers: [DevServer] = []
    @State private var showServerPicker = false
    @State private var askPort = false
    @State private var portText = ""

    private var current: Artifact? { artifacts.indices.contains(index) ? artifacts[index] : nil }

    var body: some View {
        NavigationStack {
            Group {
                if let port = devPort {
                    DevServerWebView(tid: tid, port: port, base: app.baseURL,
                                     token: app.token, reload: reload)
                        .ignoresSafeArea(edges: .bottom)
                } else if artifacts.isEmpty {
                    ContentUnavailableView("Nothing to preview", systemImage: "doc.viewfinder",
                                           description: Text("No previewable files yet. Ask Claude/Codex to make an HTML, PDF, image, or chart — or tap the globe to browse a running dev server."))
                } else {
                    TabView(selection: $index) {
                        ForEach(Array(artifacts.enumerated()), id: \.element.rel) { i, a in
                            ArtifactRenderer(tid: tid, artifact: a, base: app.baseURL, token: app.token, reload: reload)
                                .ignoresSafeArea(edges: .bottom)
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: artifacts.count > 1 ? .automatic : .never))
                }
            }
            .background(Color.appBG)
            .navigationTitle(devPort.map { "localhost:\($0)" } ?? (current?.name ?? "Preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if devPort == nil, artifacts.count > 1 {
                            Text("\(index + 1)/\(artifacts.count)").font(.caption).foregroundStyle(Color.appSecondary)
                        }
                        if !Demo.active {
                            Button { openServerPicker() } label: {
                                Image(systemName: devPort == nil ? "globe" : "doc.viewfinder")
                            }
                        }
                        Button { reload = UUID() } label: { Image(systemName: "arrow.clockwise") }
                        Button { Task { await share() } } label: { Image(systemName: "square.and.arrow.up") }
                            .disabled(current == nil || devPort != nil)
                    }
                }
            }
            .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
            .confirmationDialog("Live dev server", isPresented: $showServerPicker, titleVisibility: .visible) {
                ForEach(devServers) { s in
                    Button("localhost:\(s.port)\(s.process.map { " (\($0))" } ?? "")") { devPort = s.port }
                }
                Button("Enter port…") { portText = ""; askPort = true }
                if devPort != nil {
                    Button("Back to artifacts") { devPort = nil }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(devServers.isEmpty ? "No dev servers detected on the Mac — start one (vite, next dev, flask…) or enter a port."
                                        : "Browse a dev server running on the Mac — with live hot-reload.")
            }
            .alert("Dev server port", isPresented: $askPort) {
                TextField("5173", text: $portText)
                    .keyboardType(.numberPad)
                Button("Open") {
                    if let p = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(p) {
                        devPort = p
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func openServerPicker() {
        Task {
            devServers = (try? await app.api.devServers(tid)) ?? []
            showServerPicker = true
        }
    }

    private func share() async {
        guard let a = current else { return }
        if Demo.active {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(a.name)
            try? Demo.sampleHTML.write(to: url, atomically: true, encoding: .utf8)
            shareURL = url
            return
        }
        shareURL = try? await app.api.downloadFile(tid, rel: a.rel)
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

// MARK: - Renderer dispatch

struct ArtifactRenderer: View {
    let tid: String
    let artifact: Artifact
    let base: String
    let token: String
    let reload: UUID

    var body: some View {
        switch artifact.kind {
        case "html", "svg":
            WebPreview(tid: tid, rel: artifact.rel, base: base, token: token, reload: reload,
                       demoHTML: Demo.active ? Demo.sampleHTML : nil)
        default:                       // pdf, image, markdown, code, text -> QuickLook (native zoom/scroll)
            QuickLookPreview(tid: tid, rel: artifact.rel, reload: reload)
        }
    }
}

// MARK: - Web content (HTML / SVG) via WKWebView + token-injecting scheme handler

struct WebPreview: UIViewRepresentable {
    let tid: String
    let rel: String
    let base: String
    let token: String
    let reload: UUID
    var demoHTML: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(HarnessSchemeHandler(base: base, token: token), forURLScheme: "harness-file")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        context.coordinator.lastReload = reload
        loadContent(wv)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if context.coordinator.lastReload != reload {
            context.coordinator.lastReload = reload
            loadContent(wv)                            // re-fetch (picks up file changes)
        }
    }

    private func loadContent(_ wv: WKWebView) {
        if let demoHTML { wv.loadHTMLString(demoHTML, baseURL: nil) }   // demo: render in-app, no network
        else { wv.load(URLRequest(url: schemeURL())) }
    }

    private func schemeURL() -> URL {
        let encoded = rel.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "harness-file://\(tid)/\(encoded)") ?? URL(string: "harness-file://\(tid)/")!
    }

    final class Coordinator { var lastReload: UUID? }
}

// MARK: - Live dev-server browsing via the harness proxy

/// Browses http://localhost:{port} on the Mac through /threads/{tid}/proxy/{port}/…
/// Pages, assets, and fetch/XHR all route through the token'd scheme handler.
/// Websocket HMR does not (v1) — the reload button re-fetches.
struct DevServerWebView: UIViewRepresentable {
    let tid: String
    let port: Int
    let base: String
    let token: String
    let reload: UUID

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(ProxySchemeHandler(base: base, token: token), forURLScheme: "harness-proxy")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = false
        context.coordinator.lastReload = reload
        load(wv)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if context.coordinator.lastReload != reload {
            context.coordinator.lastReload = reload
            if wv.url != nil { wv.reload() } else { load(wv) }
        }
    }

    private func load(_ wv: WKWebView) {
        if let url = URL(string: "harness-proxy://\(tid):\(port)/") {
            wv.load(URLRequest(url: url))
        }
    }

    final class Coordinator { var lastReload: UUID? }
}

/// Maps harness-proxy://{tid}:{port}/path?q -> GET/POST {base}/threads/{tid}/proxy/{port}/path?q
/// with the bearer token, forwarding method + body so forms and fetch() work.
final class ProxySchemeHandler: NSObject, WKURLSchemeHandler {
    let base: String
    let token: String
    private var active = Set<ObjectIdentifier>()
    private let lock = NSLock()

    init(base: String, token: String) { self.base = base; self.token = token }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        lock.lock(); active.insert(key); lock.unlock()

        guard let url = task.request.url, let tid = url.host, let port = url.port else {
            let u = task.request.url ?? URL(string: "harness-proxy://x/")!
            finish(task, nil, nil, URLError(.badURL), schemeURL: u); return
        }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        var target = "\(trimmed)/threads/\(tid)/proxy/\(port)\(url.path.isEmpty ? "/" : url.path)"
        if let q = url.query, !q.isEmpty { target += "?\(q)" }
        guard let real = URL(string: target) else {
            finish(task, nil, nil, URLError(.badURL), schemeURL: url); return
        }

        var req = URLRequest(url: real)
        req.httpMethod = task.request.httpMethod ?? "GET"
        req.httpBody = task.request.httpBody
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for h in ["Content-Type", "Accept", "Range"] {
            if let v = task.request.value(forHTTPHeaderField: h) { req.setValue(v, forHTTPHeaderField: h) }
        }
        let schemeURL = url
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            self?.finish(task, resp, data, err, schemeURL: schemeURL)
        }.resume()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock(); active.remove(ObjectIdentifier(task)); lock.unlock()
    }

    private func isActive(_ task: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }; return active.contains(ObjectIdentifier(task))
    }

    /// Prepend a shim that rewrites any `new WebSocket(...)` targeting the dev server to the
    /// harness proxy's ws tunnel (real network URL, since custom schemes can't do WebSocket).
    private func injectWSShim(_ html: Data, tid: String, port: Int) -> Data? {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let wsBase = URL(string: trimmed)?
            .absoluteString.replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://") else { return nil }
        let tokEnc = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
        let prefix = "\(wsBase)/threads/\(tid)/proxy/\(port)"
        let shim = """
        <script>(function(){var OW=window.WebSocket;var P='\(prefix)',T='\(tokEnc)';
        function map(u){try{var x=new URL(u,location.href);if(x.protocol!=='ws:'&&x.protocol!=='wss:')return u;
        var q=x.search?x.search+'&':'?';return P+x.pathname+q+'_hbtok='+T;}catch(e){return u;}}
        window.WebSocket=function(u,p){return p===undefined?new OW(map(u)):new OW(map(u),p);};
        window.WebSocket.prototype=OW.prototype;window.WebSocket.CONNECTING=0;window.WebSocket.OPEN=1;
        window.WebSocket.CLOSING=2;window.WebSocket.CLOSED=3;})();</script>
        """
        guard var s = String(data: html, encoding: .utf8) else { return nil }
        if let r = s.range(of: "<head>", options: .caseInsensitive) {
            s.replaceSubrange(r, with: "<head>" + shim)
        } else {
            s = shim + s
        }
        return s.data(using: .utf8)
    }

    private func finish(_ task: WKURLSchemeTask, _ resp: URLResponse?, _ data: Data?,
                        _ err: Error?, schemeURL: URL) {
        DispatchQueue.main.async {
            guard self.isActive(task) else { return }
            self.lock.lock(); self.active.remove(ObjectIdentifier(task)); self.lock.unlock()
            if let err { task.didFailWithError(err); return }
            guard let resp, let data else { task.didFailWithError(URLError(.badServerResponse)); return }
            // Re-issue the response under the harness-proxy:// URL, not the real harness URL —
            // otherwise WKWebView sets the document origin to http://…:8787 and relative
            // resources (and the main document itself) fail to resolve through this handler.
            let http = resp as? HTTPURLResponse
            let ct = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            var body = data
            // HMR: WKWebView can't route the page's WebSocket (Vite/Next live-reload) through a
            // custom scheme, so inject a shim that repoints ws:// at the harness tunnel endpoint.
            if ct.lowercased().contains("text/html"),
               let tid = schemeURL.host, let port = schemeURL.port,
               let shimmed = self.injectWSShim(body, tid: tid, port: port) {
                body = shimmed
            }
            let out = HTTPURLResponse(url: schemeURL, statusCode: http?.statusCode ?? 200,
                                      httpVersion: "HTTP/1.1",
                                      headerFields: ["Content-Type": ct,
                                                     "Content-Length": String(body.count)])!
            task.didReceive(out)
            task.didReceive(body)
            task.didFinish()
        }
    }
}

/// Bridges custom-scheme sub-resource loads to token'd harness GETs, so a previewed page's
/// relative assets (css/js/img) authenticate — WKWebView can't set Authorization itself.
final class HarnessSchemeHandler: NSObject, WKURLSchemeHandler {
    let base: String
    let token: String
    private var active = Set<ObjectIdentifier>()
    private let lock = NSLock()

    init(base: String, token: String) { self.base = base; self.token = token }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        lock.lock(); active.insert(key); lock.unlock()

        guard let url = task.request.url, let tid = url.host else {
            finish(task, nil, nil, URLError(.badURL)); return
        }
        let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        var comps = URLComponents(string: "\(trimmed)/threads/\(tid)/file")
        comps?.queryItems = [URLQueryItem(name: "path", value: rel)]
        guard let real = comps?.url else { finish(task, nil, nil, URLError(.badURL)); return }

        var req = URLRequest(url: real)
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let r = task.request.value(forHTTPHeaderField: "Range") { req.setValue(r, forHTTPHeaderField: "Range") }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            self?.finish(task, resp, data, err)
        }.resume()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock(); active.remove(ObjectIdentifier(task)); lock.unlock()
    }

    private func isActive(_ task: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }; return active.contains(ObjectIdentifier(task))
    }

    private func finish(_ task: WKURLSchemeTask, _ resp: URLResponse?, _ data: Data?, _ err: Error?) {
        DispatchQueue.main.async {
            guard self.isActive(task) else { return }   // never message a stopped task (would crash)
            self.lock.lock(); self.active.remove(ObjectIdentifier(task)); self.lock.unlock()
            if let err { task.didFailWithError(err); return }
            guard let resp, let data else { task.didFailWithError(URLError(.badServerResponse)); return }
            if let http = resp as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode), http.statusCode != 206 {
                task.didFailWithError(URLError(.resourceUnavailable)); return   // don't render 404/403 bodies
            }
            task.didReceive(resp)
            task.didReceive(data)
            task.didFinish()
        }
    }
}

// MARK: - Everything else (PDF / image / markdown / code) via QuickLook

struct QuickLookPreview: UIViewControllerRepresentable {
    let tid: String
    let rel: String
    let reload: UUID
    @EnvironmentObject var app: AppState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        context.coordinator.fetch(app.api, tid: tid, rel: rel, controller: c)
        context.coordinator.lastReload = reload
        return c
    }

    func updateUIViewController(_ c: QLPreviewController, context: Context) {
        if context.coordinator.lastReload != reload {
            context.coordinator.lastReload = reload
            context.coordinator.fetch(app.api, tid: tid, rel: rel, controller: c)
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var fileURL: URL?
        var lastReload: UUID?

        func fetch(_ api: HarnessAPI, tid: String, rel: String, controller: QLPreviewController) {
            Task {
                let url = try? await api.downloadFile(tid, rel: rel)
                await MainActor.run {
                    self.fileURL = url
                    controller.reloadData()
                }
            }
        }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { fileURL == nil ? 0 : 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            (fileURL ?? URL(fileURLWithPath: "/dev/null")) as QLPreviewItem
        }
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
