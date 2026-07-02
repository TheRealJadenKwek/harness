import SwiftUI
import UIKit

/// Lightweight markdown renderer: fenced code blocks (with copy), inline bold/
/// italic/code, headings, and bullets — enough to make agent output read like
/// the desktop apps without a heavy dependency.
struct MarkdownText: View {
    let text: String

    /// Above this, skip markdown entirely: parsing + a per-line AttributedString for a 100k-char
    /// dump stalls the main thread the moment a big thread opens. Giant outputs render as
    /// collapsed plain text instead (full markdown isn't readable at that size anyway).
    static let markdownLimit = 12_000

    var body: some View {
        if text.count > Self.markdownLimit {
            CollapsibleText(text: text)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(MarkdownText.parse(text).enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .prose(let p): ProseView(text: p)
                    case .code(let c, let lang): CodeBlock(code: c, language: lang)
                    }
                }
            }
        }
    }

    enum Segment {
        case prose(String)
        case code(String, String?)
    }

    private static var cache: [String: [Segment]] = [:]

    static func parse(_ s: String) -> [Segment] {
        if let hit = cache[s] { return hit }           // never re-parse the same text twice
        var segs: [Segment] = []
        var inCode = false
        var lang: String?
        var buf: [String] = []
        func flush(asCode: Bool) {
            let joined = buf.joined(separator: "\n")
            if asCode {
                segs.append(.code(joined, lang))
            } else if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segs.append(.prose(joined))
            }
            buf.removeAll()
        }
        for line in s.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    flush(asCode: true); inCode = false; lang = nil
                } else {
                    flush(asCode: false); inCode = true
                    let l = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    lang = l.isEmpty ? nil : l
                }
            } else {
                buf.append(line)
            }
        }
        flush(asCode: inCode)
        if cache.count > 120 { cache.removeAll() }
        cache[s] = segs
        return segs
    }
}

private struct ProseView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                lineView(raw)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            Color.clear.frame(height: 3)
        } else if let h = header(line) {
            Text(attr(h.1)).font(h.0).fontWeight(.semibold)
        } else if let b = bullet(line) {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(attr(b))
            }
        } else {
            Text(attr(line))
        }
    }

    private func header(_ l: String) -> (Font, String)? {
        if l.hasPrefix("### ") { return (.headline, String(l.dropFirst(4))) }
        if l.hasPrefix("## ") { return (.title3, String(l.dropFirst(3))) }
        if l.hasPrefix("# ") { return (.title2, String(l.dropFirst(2))) }
        return nil
    }

    private func bullet(_ l: String) -> String? {
        let t = String(l.drop(while: { $0 == " " }))
        if t.hasPrefix("- ") || t.hasPrefix("* ") { return String(t.dropFirst(2)) }
        return nil
    }

    private func attr(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}

private struct CodeBlock: View {
    let code: String
    let language: String?
    @State private var copied = false
    @State private var expanded = false
    private static let maxLines = 150     // long code dumps collapse; Copy still grabs everything

    var body: some View {
        let lines = code.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                // Chunked: one Text hundreds of lines tall overflows the GPU texture cap and draws blank.
                ChunkedText(text: expanded || lines.count <= Self.maxLines
                            ? code
                            : lines.prefix(Self.maxLines).joined(separator: "\n"),
                            font: .system(.footnote, design: .monospaced))
                    .padding(10)
            }
            if lines.count > Self.maxLines {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "Show less" : "Show all \(lines.count) lines")
                        .font(.caption2).bold()
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.borderless)
            }
        }
        .background(Color.codeBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
