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

    private var current: Artifact? { artifacts.indices.contains(index) ? artifacts[index] : nil }

    var body: some View {
        NavigationStack {
            Group {
                if artifacts.isEmpty {
                    ContentUnavailableView("Nothing to preview", systemImage: "doc.viewfinder",
                                           description: Text("No previewable files yet. Ask Claude/Codex to make an HTML, PDF, image, or chart."))
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
            .navigationTitle(current?.name ?? "Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if artifacts.count > 1 {
                            Text("\(index + 1)/\(artifacts.count)").font(.caption).foregroundStyle(Color.appSecondary)
                        }
                        Button { reload = UUID() } label: { Image(systemName: "arrow.clockwise") }
                        Button { Task { await share() } } label: { Image(systemName: "square.and.arrow.up") }
                            .disabled(current == nil)
                    }
                }
            }
            .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
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
