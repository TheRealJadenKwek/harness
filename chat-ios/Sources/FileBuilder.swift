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
    var files: [Entry]?
    var dataUrl: String?          // inline media (generated images/videos)

    struct Entry: Codable, Hashable {
        var path: String
        var content: String
    }

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
        case "html": if !name.hasSuffix(".html") { name += ".html" }
        case "zip":  if !name.hasSuffix(".zip") { name += ".zip" }
        default: break
        }
        let url = dir.appendingPathComponent(name)
        let data: Data
        switch spec.kind {
        case "pdf":  data = try buildPDF(spec)
        case "xlsx", "pptx", "zip": data = try await WebArtifactBuilder.shared.build(spec)
        default:     data = Data((spec.content ?? spec.body ?? "").utf8)   // text + html
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
        <script src="https://cdnjs.cloudflare.com/ajax/libs/jszip/3.10.1/jszip.min.js"></script>
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

    // run model-requested code: JS in-page, Python via Pyodide (lazy CDN)
    func runCode(language: String, code: String) async -> String {
        do {
            try await ensureWebView()
            guard let wv = webView else { return "Error: no runtime" }
            let js = """
            const lang = \(String(data: try JSONEncoder().encode(language), encoding: .utf8)!);
            const src = \(String(data: try JSONEncoder().encode(code), encoding: .utf8)!);
            if (lang === 'javascript') {
              const out = [];
              const console = { log: (...a) => out.push(a.map(x => typeof x === 'object' ? JSON.stringify(x) : String(x)).join(' ')),
                                error: (...a) => out.push(a.join(' ')) };
              try { const r = await eval(src); if (r !== undefined) out.push(String(typeof r === 'object' ? JSON.stringify(r) : r)); }
              catch (e) { out.push('Error: ' + e.message); }
              return out.join('\\n') || '(no output)';
            }
            if (!window.loadPyodide) {
              await new Promise((ok, bad) => { const sc = document.createElement('script');
                sc.src = 'https://cdn.jsdelivr.net/pyodide/v0.26.2/full/pyodide.js';
                sc.onload = ok; sc.onerror = () => bad(new Error('pyodide load failed')); document.head.appendChild(sc); });
            }
            if (!window.__py) window.__py = await loadPyodide({ indexURL: 'https://cdn.jsdelivr.net/pyodide/v0.26.2/full/' });
            const py = window.__py;
            await py.runPythonAsync('import sys, io as _io\\nsys.stdout = _io.StringIO()\\nsys.stderr = sys.stdout');
            let repr = '';
            try { const r = await py.runPythonAsync(src); if (r !== undefined && r !== null) repr = String(r); }
            catch (e) { return 'Error: ' + String(e.message || e).split('\\n').slice(-3).join('\\n'); }
            const out = await py.runPythonAsync('sys.stdout.getvalue()');
            return ((out || '') + (repr ? '\\n' + repr : '')).trim() || '(no output)';
            """
            let r = try await wv.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
            return (r as? String) ?? "(no output)"
        } catch { return "Error: " + error.localizedDescription }
    }

    // extract readable text from office docs (xlsx via SheetJS, docx/pptx via JSZip)
    func extractOffice(base64: String, ext: String) async -> String {
        do {
            try await ensureWebView()
            guard let wv = webView else { return "" }
            let js = """
            const b64 = \(String(data: try JSONEncoder().encode(base64), encoding: .utf8)!);
            const ext = \(String(data: try JSONEncoder().encode(ext), encoding: .utf8)!);
            const bin = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
            if (ext === 'xlsx' || ext === 'xls') {
              const wb = XLSX.read(bin, { type: 'array' });
              let text = '';
              for (const name of wb.SheetNames.slice(0, 10)) {
                text += '=== sheet: ' + name + ' ===\\n' + XLSX.utils.sheet_to_csv(wb.Sheets[name]).slice(0, 30000) + '\\n\\n';
                if (text.length > 60000) break;
              }
              return text.trim();
            }
            const zip = await JSZip.loadAsync(bin);
            const paths = ext === 'docx' ? ['word/document.xml']
              : Object.keys(zip.files).filter((q) => /^ppt\\/slides\\/slide\\d+\\.xml$/.test(q))
                  .sort((a, b) => parseInt(a.match(/\\d+/)[0]) - parseInt(b.match(/\\d+/)[0]));
            let text = '';
            for (const q of paths) {
              const file = zip.file(q);
              if (!file) continue;
              const xml = await file.async('string');
              text += (ext === 'pptx' ? '=== ' + q.replace('ppt/slides/', '').replace('.xml', '') + ' ===\\n' : '')
                + xml.replace(/<\\/(w:p|a:p)>/g, '\\n').replace(/<[^>]+>/g, '')
                     .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '\"')
                     .replace(/&#(\\d+);/g, (_, n) => String.fromCharCode(n)).replace(/\\n{3,}/g, '\\n\\n') + '\\n';
              if (text.length > 60000) break;
            }
            return text.trim();
            """
            let r = try await wv.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
            return (r as? String) ?? ""
        } catch { return "" }
    }

    func build(_ spec: FileSpec) async throws -> Data {
        try await ensureWebView()
        guard let wv = webView else { throw NSError(domain: "wb", code: 1) }
        let specJSON = String(data: try JSONEncoder().encode(spec), encoding: .utf8)!
        let js = """
        const spec = \(specJSON);
        if (spec.kind === 'zip') {
          const z = new JSZip();
          for (const f of spec.files || []) z.file(f.path, f.content || '');
          return await z.generateAsync({ type: 'base64' });
        } else if (spec.kind === 'xlsx') {
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
