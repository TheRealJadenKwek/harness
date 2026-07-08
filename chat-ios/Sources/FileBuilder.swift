import Foundation
import UIKit
import WebKit

// A file the model created: same spec shape as the web app (syncs both ways).
struct FileSpec: Codable, Hashable {
    var kind: String            // text | pdf | xlsx | pptx
    var filename: String
    var content: String?
    var title: String?
    var body: String?
    var sheets: [Sheet]?
    var slides: [Slide]?

    struct Sheet: Codable, Hashable {
        var name: String?
        var rows: [[Cell]]?
    }
    struct Slide: Codable, Hashable {
        var title: String?
        var bullets: [String]?
        var notes: String?
    }
    // spreadsheet cells arrive as strings or numbers
    enum Cell: Codable, Hashable {
        case s(String), n(Double)
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let v = try? c.decode(Double.self) { self = .n(v) }
            else { self = .s((try? c.decode(String.self)) ?? "") }
        }
        func encode(to e: Encoder) throws {
            var c = e.singleValueContainer()
            switch self { case .s(let v): try c.encode(v); case .n(let v): try c.encode(v) }
        }
        var text: String {
            switch self {
            case .s(let v): return v
            case .n(let v): return v == v.rounded() ? String(Int(v)) : String(v)
            }
        }
    }
}

enum FileBuilder {
    static func build(_ spec: FileSpec) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("harness-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = spec.filename
        switch spec.kind {
        case "pdf":  if !name.hasSuffix(".pdf") { name += ".pdf" }
        case "xlsx": if !name.hasSuffix(".xlsx") { name += ".xlsx" }
        case "pptx": if !name.hasSuffix(".pptx") { name += ".pptx" }
        default: break
        }
        let url = dir.appendingPathComponent(name)
        let data: Data
        switch spec.kind {
        case "pdf":  data = try buildPDF(spec)
        case "xlsx": data = try await WebArtifactBuilder.shared.build(spec)
        case "pptx": data = try await WebArtifactBuilder.shared.build(spec)
        default:     data = Data((spec.content ?? spec.body ?? "").utf8)
        }
        try data.write(to: url)
        return url
    }

    // native PDF: title + paginated body text (US letter)
    static func buildPDF(_ spec: FileSpec) throws -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 64
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let bodyFont = UIFont.systemFont(ofSize: 11.5)
        let paras = (spec.body ?? spec.content ?? "").components(separatedBy: "\n\n")
        return renderer.pdfData { ctx in
            ctx.beginPage()
            var y: CGFloat = 70
            if let t = spec.title, !t.isEmpty {
                let a: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 19)]
                let rect = (t as NSString).boundingRect(with: CGSize(width: page.width - margin * 2, height: 200),
                                                        options: .usesLineFragmentOrigin, attributes: a, context: nil)
                (t as NSString).draw(in: CGRect(x: margin, y: y, width: page.width - margin * 2, height: rect.height), withAttributes: a)
                y += rect.height + 18
            }
            for para in paras {
                let text = para.replacingOccurrences(of: "\n", with: " ")
                if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let a: [NSAttributedString.Key: Any] = [.font: bodyFont]
                let rect = (text as NSString).boundingRect(with: CGSize(width: page.width - margin * 2, height: 10000),
                                                           options: .usesLineFragmentOrigin, attributes: a, context: nil)
                if y + rect.height > page.height - margin { ctx.beginPage(); y = margin }
                (text as NSString).draw(in: CGRect(x: margin, y: y, width: page.width - margin * 2, height: rect.height), withAttributes: a)
                y += rect.height + 12
            }
        }
    }
}

// xlsx/pptx are built in a hidden WKWebView with the SAME CDN libraries the web
// app uses — one implementation of the tricky formats, everywhere.
@MainActor
final class WebArtifactBuilder: NSObject, WKNavigationDelegate {
    static let shared = WebArtifactBuilder()
    private var webView: WKWebView?
    private var readyCont: CheckedContinuation<Void, Error>?

    private func ensureWebView() async throws {
        if webView != nil { return }
        let wv = WKWebView(frame: .zero)
        wv.navigationDelegate = self
        webView = wv
        let html = """
        <html><head>
        <script src="https://cdn.sheetjs.com/xlsx-0.20.2/package/dist/xlsx.full.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/pptxgenjs@3.12.0/dist/pptxgen.bundle.js"></script>
        </head><body></body></html>
        """
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            readyCont = c
            wv.loadHTMLString(html, baseURL: URL(string: "https://harness-chat-web.vercel.app"))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in readyCont?.resume(); readyCont = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in readyCont?.resume(throwing: error); readyCont = nil }
    }

    func build(_ spec: FileSpec) async throws -> Data {
        try await ensureWebView()
        guard let wv = webView else { throw NSError(domain: "wb", code: 1) }
        let specJSON = String(data: try JSONEncoder().encode(spec), encoding: .utf8)!
        let js = """
        const spec = \(specJSON);
        if (spec.kind === 'xlsx') {
          const wb = XLSX.utils.book_new();
          for (const sh of spec.sheets || [{name:'Sheet1', rows:[[spec.content || '']]}]) {
            XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(sh.rows || []), String(sh.name || 'Sheet').slice(0, 31));
          }
          return XLSX.write(wb, { type: 'base64' });
        } else {
          const p = new PptxGenJS();
          for (const sl of spec.slides || []) {
            const slide = p.addSlide();
            if (sl.title) slide.addText(sl.title, { x: 0.55, y: 0.45, w: 8.9, h: 0.9, fontSize: 28, bold: true, color: '1c1c1e' });
            if (Array.isArray(sl.bullets) && sl.bullets.length) {
              slide.addText(sl.bullets.map((b) => ({ text: String(b), options: { bullet: true, fontSize: 16, color: '333338', breakLine: true } })),
                            { x: 0.7, y: 1.5, w: 8.6, h: 3.8, valign: 'top' });
            }
            if (sl.notes) slide.addNotes(String(sl.notes));
          }
          return await p.write('base64');
        }
        """
        let result = try await wv.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
        guard let b64 = result as? String, let data = Data(base64Encoded: b64) else {
            throw NSError(domain: "wb", code: 2, userInfo: [NSLocalizedDescriptionKey: "artifact build failed"])
        }
        return data
    }
}
